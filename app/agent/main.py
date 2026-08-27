"""LangGraph agent hosted on Azure AI Foundry Agent Service (Responses protocol).

Two sources of tools, and the difference between them is the point:

  * `search_knowledge_base` is written into this container and answers questions from a
    document corpus.
  * The orders tools arrive at runtime from a Foundry Toolbox, which fronts an APIM MCP
    server, which fronts a REST API that knows nothing about agents. They can be added,
    reconfigured or withdrawn without redeploying this code.
"""
from __future__ import annotations

import asyncio
import logging
import os
import uuid
from pathlib import Path

import yaml
from azure.ai.agentserver.responses import (
    CreateResponse,
    ResponseContext,
    ResponsesAgentServerHost,
    ResponsesServerOptions,
    TextResponse,
)
from azure.identity import DefaultAzureCredential
from langchain_azure_ai.chat_models import AzureAIOpenAIApiChatModel
from langgraph.prebuilt import create_react_agent

try:
    import toolbox
except ImportError:
    # mcp or httpx2 not installed in this build environment — the agent degrades
    # to knowledge-base-only. Orders tools will be missing, but RAG still works.
    toolbox = None  # type: ignore[assignment]

from tools import search_knowledge_base

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("rag-agent")

_credential = DefaultAzureCredential()
_model = AzureAIOpenAIApiChatModel(
    project_endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
    credential=_credential,
    model=os.environ.get("AZURE_AI_MODEL_DEPLOYMENT_NAME", "apim-gateway/gpt-4o"),
)

# agent.yaml is the single definition of how this agent should behave, so the container
# reads its instructions rather than keeping a second copy in Python that drifts.
_INSTRUCTIONS = yaml.safe_load((Path(__file__).parent / "agent.yaml").read_text())[
    "instructions"
]

_agent = None
_agent_lock = asyncio.Lock()


async def _get_agent():
    """Build the graph once, on the first request.

    Not at import time: discovering the Toolbox's tools is a network call, and a
    container that cannot start because the Toolbox is briefly unavailable is worse
    than one that starts and reports the tools are missing.
    """
    global _agent
    if _agent is not None:
        return _agent

    async with _agent_lock:
        if _agent is not None:
            return _agent

        order_tools = await toolbox.load_tools() if toolbox is not None else []
        tools = [search_knowledge_base, *order_tools]
        graph = create_react_agent(_model, tools=tools, prompt=_INSTRUCTIONS)
        logger.info("Agent built with %d tools", len(tools))

        if not order_tools and toolbox is not None and toolbox.toolbox_endpoint() is not None:
            # A toolbox is configured but gave us nothing, which is a transient
            # failure often enough to be worth retrying. Serve this request with what
            # we have, but don't cache a permanently order-blind agent.
            logger.warning("Toolbox returned no tools; will try again on the next request")
            return graph

        _agent = graph

    return _agent


async def _history_to_messages(context: ResponseContext) -> list[tuple[str, str]]:
    """Earlier turns, as LangChain (role, text) pairs.

    Without this the agent is single-turn, and the whole confirmation flow is
    impossible: the model cannot restate an order on one turn and act on the user's
    "yes" on the next if it never sees the first turn. Tool calls in the history are
    skipped — the conversation is what carries the state that matters here.
    """
    messages: list[tuple[str, str]] = []

    for item in await context.get_history():
        if getattr(item, "type", None) != "message":
            continue

        role = str(getattr(item, "role", "") or "")
        if role not in ("user", "assistant", "system"):
            continue

        parts = []
        for content in getattr(item, "content", None) or []:
            text = getattr(content, "text", None)
            if isinstance(text, str) and text:
                parts.append(text)

        if parts:
            messages.append((role, "\n".join(parts)))

    return messages


server = ResponsesAgentServerHost(
    options=ResponsesServerOptions(default_fetch_history_count=20)
)


@server.response_handler
async def handle_response(
    request: CreateResponse,
    context: ResponseContext,
    cancellation_signal,
) -> TextResponse:
    user_text = await context.get_input_text()

    # The documented key for handler-side conversation state: the shared partition id of
    # a chain of turns, derived from conversation_id, else previous_response_id, else
    # this response's id. It is what makes the approval gate span turns — the UI threads
    # previous_response_id, so consecutive turns land on the same key.
    #
    # The fallback is a fresh id rather than a shared constant, and that choice matters:
    # a constant would put every conversation in one bucket, where one user's "yes"
    # could release another user's held write. A unique key instead fails closed — the
    # write stays held — which is the right way round to be wrong.
    conversation = str(context.conversation_chain_id or uuid.uuid4())
    if toolbox is not None:
        toolbox.current_conversation.set(conversation)

    # Read this turn as a possible answer to a write the previous turn held back. Done
    # before the model runs, so that when it retries the held call the approval is
    # already there to consume.
    if toolbox is not None:
        verdict = toolbox.gate.apply_user_reply(conversation, user_text)
        if verdict == "declined":
            logger.info("User declined the pending write in conversation %s", conversation)

    agent = await _get_agent()

    try:
        messages = await _history_to_messages(context)
    except Exception:
        # History is a convenience, not a prerequisite for answering. Losing it costs
        # the confirmation flow, which is bad, but silence costs the whole reply.
        logger.exception("Could not read conversation history; answering single-turn")
        messages = []

    # Whether the current turn is already in the history depends on when the provider
    # persists it, so drop a trailing duplicate rather than assume either way — sending
    # the question twice makes the model treat it as repetition and re-ask.
    if messages and messages[-1] == ("user", user_text):
        messages.pop()

    messages.append(("user", user_text))
    logger.info("Turn in conversation %s with %d prior messages", conversation, len(messages) - 1)

    result = await agent.ainvoke({"messages": messages})
    # Read `.text`, not `.content`: over the Responses API the reply arrives as a
    # list of content blocks, and TextResponse only accepts str/callable/AsyncIterable.
    final_text = result["messages"][-1].text
    return TextResponse(context, request, text=final_text)


if __name__ == "__main__":
    server.run()
