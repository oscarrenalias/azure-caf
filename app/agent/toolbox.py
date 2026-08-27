"""Tools from the Foundry Toolbox, which reaches the orders backend through APIM.

The Toolbox is a project-level MCP endpoint. Everything the agent can do to the system
of record arrives through it at runtime — no tool is written into this container, and
adding or reconfiguring one does not need a redeploy. The credential for the APIM MCP
server lives in a project connection, so this process holds no subscription key; it
authenticates to the Toolbox as itself with DefaultAzureCredential and the Toolbox
injects each tool's own credential downstream.

Chain: this module -> Toolbox MCP endpoint -> APIM MCP server (orders-mcp) -> APIM REST
API (orders-api) -> Function App -> Table Storage.
"""

from __future__ import annotations

import contextlib
import contextvars
import json
import logging
import os
from collections.abc import AsyncGenerator
from typing import Any

import httpx2
from azure.identity import DefaultAzureCredential
from langchain_core.tools import StructuredTool
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

from approvals import ApprovalGate

logger = logging.getLogger("rag-agent.toolbox")

_SCOPE = "https://ai.azure.com/.default"

# Set by the response handler for the duration of one turn. The tool wrappers below are
# built from a remote schema, so threading a conversation id through their signatures
# would mean rewriting that schema; a context variable stays out of the way and is
# correct per async task.
current_conversation: contextvars.ContextVar[str] = contextvars.ContextVar(
    "current_conversation", default="default"
)

gate = ApprovalGate()

_credential = DefaultAzureCredential()


def toolbox_endpoint() -> str | None:
    """The MCP endpoint to connect to, or None if the Toolbox isn't configured.

    A missing endpoint is not an error: the agent still answers questions about the
    books, it just cannot see orders. That keeps the RAG path working while the orders
    stack is being built or torn down.
    """
    endpoint = os.environ.get("TOOLBOX_ENDPOINT", "").strip()
    if endpoint:
        return endpoint

    # Fall back to the unversioned consumer endpoint, which always serves the toolbox's
    # default version — so publishing a new version reaches the agent without a deploy.
    project = os.environ.get("FOUNDRY_PROJECT_ENDPOINT", "").strip().rstrip("/")
    name = os.environ.get("TOOLBOX_NAME", "").strip()
    if project and name:
        return f"{project}/toolboxes/{name}/mcp?api-version=v1"

    return None


@contextlib.asynccontextmanager
async def _session(endpoint: str) -> AsyncGenerator[ClientSession]:
    """An initialised MCP session against the Toolbox.

    One session per operation rather than one held open for the container's lifetime.
    Streamable HTTP allows either, and a short-lived session avoids the two failure
    modes of the long-lived one: a connection that has quietly died while the agent sat
    idle, and a bearer token that has expired since startup. Every session below takes a
    fresh token — DefaultAzureCredential caches it, so this is not a round trip each
    time.

    mcp 2.x takes headers on the HTTP client rather than the transport, and its
    transport yields two streams where 1.x yielded three; snippets written against 1.x
    will not work here.
    """
    headers = {"Authorization": f"Bearer {_credential.get_token(_SCOPE).token}"}

    async with httpx2.AsyncClient(headers=headers, timeout=60.0) as http_client:
        async with streamable_http_client(endpoint, http_client=http_client) as (
            read,
            write,
        ):
            async with ClientSession(read, write) as session:
                await session.initialize()
                yield session


def _safe_name(mcp_name: str) -> str:
    """`orders.createOrder` or `orders___createOrder` -> `orders_createOrder`.

    The Toolbox namespaces MCP tools as `{server_label}.{tool_name}` (documented) or
    `{server_label}___{tool_name}` (observed in beta). OpenAI-style function names permit
    letters, digits, underscore and hyphen — not dots. Left unconverted the model never
    gets to call the tool and the failure looks like the model ignoring it.
    """
    return mcp_name.replace("___", "_").replace(".", "_")


def _short_name(mcp_name: str) -> str:
    """Bare tool name without the server-label prefix."""
    for sep in ("___", "."):
        if sep in mcp_name:
            return mcp_name.split(sep)[-1]
    return mcp_name


async def _call(mcp_name: str, arguments: dict[str, Any]) -> str:
    """One tool call, on its own short-lived MCP session."""
    endpoint = toolbox_endpoint()
    if endpoint is None:
        return "Toolbox error: no toolbox endpoint is configured."

    async with _session(endpoint) as session:
        result = await session.call_tool(mcp_name, arguments)

    if getattr(result, "is_error", False):
        # Surfaced as text so the model can relay it, but logged too — a 404 from the
        # orders API and a broken connection to the Toolbox read identically otherwise.
        logger.warning("Tool %s returned an error: %s", mcp_name, result.content)

    parts = [
        c.text for c in getattr(result, "content", None) or []
        if getattr(c, "type", None) == "text"
    ]
    if parts:
        return "\n".join(parts)

    structured = getattr(result, "structured_content", None)
    if structured is not None:
        return json.dumps(structured)

    return "The tool returned no content."


def _wrap(tool: Any, requires_approval: bool) -> StructuredTool:
    mcp_name = tool.name
    name = _safe_name(mcp_name)

    async def invoke(**arguments: Any) -> str:
        if requires_approval:
            conversation = current_conversation.get()
            if not gate.take(conversation, name, arguments):
                return gate.hold(conversation, name, arguments)

        try:
            return await _call(mcp_name, arguments)
        except Exception as exc:
            logger.exception("Calling %s failed", mcp_name)
            return f"Tool error: {type(exc).__name__}: {exc}"

    schema = getattr(tool, "input_schema", None) or {"type": "object", "properties": {}}
    description = tool.description or ""
    if requires_approval:
        # Belt and braces alongside the gate: the model behaves better when it knows a
        # tool is gated than when it discovers it by being refused.
        description += (
            "\n\nThis tool requires the user's explicit confirmation. Calling it "
            "without it does not run it — it returns APPROVAL_REQUIRED."
        )

    return StructuredTool.from_function(
        coroutine=invoke,
        name=name,
        description=description,
        args_schema=schema,
    )


def _platform_says_approval(tool: Any) -> bool:
    """What the Toolbox reports in `_meta.tool_configuration.require_approval`."""
    meta = getattr(tool, "meta", None) or {}
    configuration = meta.get("tool_configuration") or {}
    return str(configuration.get("require_approval", "never")).lower() == "always"


def _gated_tool_names() -> set[str]:
    """Which tools this agent will not run without confirmation.

    `require_approval` is set per MCP *server*, not per tool, so one connection
    carrying both reads and writes can only say "always" or "never" for all four. This
    list is what gives per-tool granularity, and since enforcement is the runtime's job
    anyway, the runtime is an honest place to hold it.

    Set TOOLBOX_APPROVAL_TOOLS to an empty string to defer to the Toolbox instead.
    """
    raw = os.environ.get("TOOLBOX_APPROVAL_TOOLS", "createOrder,updateOrder")
    return {name.strip() for name in raw.split(",") if name.strip()}


async def load_tools() -> list[StructuredTool]:
    """Discover the Toolbox's tools. Returns [] if it isn't reachable."""
    endpoint = toolbox_endpoint()
    if endpoint is None:
        logger.warning(
            "No TOOLBOX_ENDPOINT and no TOOLBOX_NAME — continuing without order tools."
        )
        return []

    try:
        async with _session(endpoint) as session:
            listed = await session.list_tools()
    except Exception:
        # Deliberately not fatal. A Toolbox outage should degrade the agent to the
        # knowledge base rather than take the whole container down on startup.
        logger.exception("Could not list tools from the toolbox at %s", endpoint)
        return []

    configured = _gated_tool_names()

    tools = []
    for tool in listed.tools:
        platform = _platform_says_approval(tool)
        gated = _short_name(tool.name) in configured if configured else platform

        if configured and platform != gated:
            # Not an error — the Toolbox's setting is per-server and this is per-tool —
            # but worth seeing in the log, because it is exactly the sort of divergence
            # that is invisible until someone wonders why a write went through.
            logger.info(
                "Toolbox reports require_approval=%s for %s; this agent gates it: %s",
                "always" if platform else "never",
                tool.name,
                gated,
            )

        tools.append(_wrap(tool, gated))
        logger.info(
            "Loaded tool %s (approval %s)", tool.name, "required" if gated else "not required"
        )

    return tools
