"""Toolbox client and approval gate, against a real MCP server on localhost.

No Azure and no Foundry: an MCP server is started in-process over the same streamable
HTTP transport the Toolbox uses, so the wrapping, the tool-name conversion and — most
importantly — the confirmation gate are exercised end to end. What this cannot check is
whether the Foundry Toolbox behaves like the reference server; that is what
app/toolbox/probe_toolbox.py is for.

Run with:  uv run --with pytest --with pytest-asyncio pytest tests -q
"""

from __future__ import annotations

import asyncio
import contextlib
import socket
import sys
from pathlib import Path

import pytest
import pytest_asyncio
import uvicorn

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from mcp.server.mcpserver import MCPServer  # noqa: E402

import toolbox  # noqa: E402

# Records every call that actually reached the server, which is how the gate is checked:
# a held call must leave no trace here.
calls: list[tuple[str, dict]] = []


def _build_server() -> MCPServer:
    server = MCPServer(name="orders-test")

    @server.tool(name="orders.listOrders", description="List a customer's orders.")
    def list_orders(customerId: str) -> str:
        calls.append(("listOrders", {"customerId": customerId}))
        return f'{{"customerId": "{customerId}", "count": 0, "orders": []}}'

    @server.tool(name="orders.createOrder", description="Create an order.")
    def create_order(customerId: str, sku: str) -> str:
        calls.append(("createOrder", {"customerId": customerId, "sku": sku}))
        return '{"orderId": "ORD-TEST0001"}'

    return server


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class _FakeToken:
    token = "not-a-real-token"


class _FakeCredential:
    def get_token(self, *_scopes, **_kwargs):
        return _FakeToken()


@pytest_asyncio.fixture
async def endpoint(monkeypatch):
    calls.clear()
    toolbox.gate._pending.clear()

    port = _free_port()
    config = uvicorn.Config(
        _build_server().streamable_http_app(), host="127.0.0.1", port=port, log_level="error"
    )
    server = uvicorn.Server(config)
    task = asyncio.create_task(server.serve())

    for _ in range(100):
        if server.started:
            break
        await asyncio.sleep(0.05)
    else:  # pragma: no cover - only on a badly wedged machine
        raise RuntimeError("test MCP server did not start")

    url = f"http://127.0.0.1:{port}/mcp"
    toolbox.current_conversation.set("conv")
    monkeypatch.setattr(toolbox, "_credential", _FakeCredential())
    monkeypatch.setenv("TOOLBOX_ENDPOINT", url)
    monkeypatch.delenv("TOOLBOX_APPROVAL_TOOLS", raising=False)

    yield url

    server.should_exit = True
    with contextlib.suppress(asyncio.CancelledError, Exception):
        await asyncio.wait_for(task, timeout=10)


async def _tools() -> dict:
    return {t.name: t for t in await toolbox.load_tools()}


@pytest.mark.asyncio
async def test_tool_names_lose_the_dot_the_model_cannot_send(endpoint):
    tools = await _tools()
    assert set(tools) == {"orders_listOrders", "orders_createOrder"}


@pytest.mark.asyncio
async def test_read_tool_runs_straight_through(endpoint):
    tools = await _tools()

    result = await tools["orders_listOrders"].ainvoke({"customerId": "acme"})

    assert '"count": 0' in result
    assert calls == [("listOrders", {"customerId": "acme"})]


@pytest.mark.asyncio
async def test_write_tool_is_held_and_does_not_reach_the_backend(endpoint):
    tools = await _tools()

    result = await tools["orders_createOrder"].ainvoke(
        {"customerId": "acme", "sku": "WIDGET-001"}
    )

    assert result.startswith("APPROVAL_REQUIRED")
    assert "createOrder" in result
    assert calls == []


@pytest.mark.asyncio
async def test_write_runs_once_the_user_says_yes(endpoint):
    tools = await _tools()
    arguments = {"customerId": "acme", "sku": "WIDGET-001"}

    await tools["orders_createOrder"].ainvoke(arguments)
    assert toolbox.gate.apply_user_reply("conv", "yes, go ahead") == "granted"

    result = await tools["orders_createOrder"].ainvoke(arguments)

    assert "ORD-TEST0001" in result
    assert calls == [("createOrder", arguments)]


@pytest.mark.asyncio
async def test_declining_prevents_the_write(endpoint):
    tools = await _tools()
    arguments = {"customerId": "acme", "sku": "WIDGET-001"}

    await tools["orders_createOrder"].ainvoke(arguments)
    assert toolbox.gate.apply_user_reply("conv", "no, cancel that") == "declined"

    result = await tools["orders_createOrder"].ainvoke(arguments)

    assert result.startswith("APPROVAL_REQUIRED")
    assert calls == []


@pytest.mark.asyncio
async def test_approval_does_not_transfer_to_different_arguments(endpoint):
    tools = await _tools()

    await tools["orders_createOrder"].ainvoke({"customerId": "acme", "sku": "WIDGET-001"})
    toolbox.gate.apply_user_reply("conv", "yes")

    # The user agreed to one widget for acme, not to whatever the model asks for next.
    result = await tools["orders_createOrder"].ainvoke(
        {"customerId": "globex", "sku": "ANVIL-9"}
    )

    assert result.startswith("APPROVAL_REQUIRED")
    assert calls == []


@pytest.mark.asyncio
async def test_approval_is_single_use(endpoint):
    tools = await _tools()
    arguments = {"customerId": "acme", "sku": "WIDGET-001"}

    await tools["orders_createOrder"].ainvoke(arguments)
    toolbox.gate.apply_user_reply("conv", "yes")
    await tools["orders_createOrder"].ainvoke(arguments)

    result = await tools["orders_createOrder"].ainvoke(arguments)

    assert result.startswith("APPROVAL_REQUIRED")
    assert len(calls) == 1


@pytest.mark.asyncio
async def test_an_unclear_reply_does_not_approve(endpoint):
    tools = await _tools()
    arguments = {"customerId": "acme", "sku": "WIDGET-001"}

    await tools["orders_createOrder"].ainvoke(arguments)
    assert toolbox.gate.apply_user_reply("conv", "what's the delivery time?") is None

    result = await tools["orders_createOrder"].ainvoke(arguments)

    assert result.startswith("APPROVAL_REQUIRED")
    assert calls == []


@pytest.mark.asyncio
async def test_a_reply_carrying_both_signals_declines(endpoint):
    tools = await _tools()
    await tools["orders_createOrder"].ainvoke({"customerId": "acme", "sku": "X"})

    assert toolbox.gate.apply_user_reply("conv", "yes — no, cancel it") == "declined"


@pytest.mark.parametrize(
    "reply,expected",
    [
        # "no" hides inside "now", "nothing" and "another"; whole-word matching is what
        # keeps these from reading as refusals.
        ("yes, do it now", "granted"),
        ("sure, nothing else to add", "granted"),
        ("go ahead", "granted"),
        ("no", "declined"),
        ("please do not", "declined"),
        ("hold on a second", "declined"),
        ("how long will delivery take?", None),
        ("", None),
    ],
)
def test_replies_are_read_conservatively(reply, expected):
    gate = toolbox.ApprovalGate()
    gate.hold("c", "orders_createOrder", {"customerId": "acme"})

    assert gate.apply_user_reply("c", reply) == expected


@pytest.mark.asyncio
async def test_approvals_do_not_leak_between_conversations(endpoint):
    tools = await _tools()
    arguments = {"customerId": "acme", "sku": "WIDGET-001"}

    await tools["orders_createOrder"].ainvoke(arguments)
    toolbox.gate.apply_user_reply("conv", "yes")

    # A different chat says yes to nothing, so its call is still held.
    toolbox.current_conversation.set("other-conversation")
    result = await tools["orders_createOrder"].ainvoke(arguments)

    assert result.startswith("APPROVAL_REQUIRED")
    assert calls == []


@pytest.mark.asyncio
async def test_env_var_can_defer_gating_to_the_platform(endpoint, monkeypatch):
    # With no configured list and no _meta from this server, nothing is gated.
    monkeypatch.setenv("TOOLBOX_APPROVAL_TOOLS", "")
    tools = await _tools()

    result = await tools["orders_createOrder"].ainvoke(
        {"customerId": "acme", "sku": "WIDGET-001"}
    )

    assert "ORD-TEST0001" in result


@pytest.mark.asyncio
async def test_missing_toolbox_degrades_instead_of_failing(monkeypatch):
    monkeypatch.delenv("TOOLBOX_ENDPOINT", raising=False)
    monkeypatch.delenv("TOOLBOX_NAME", raising=False)
    monkeypatch.setenv("FOUNDRY_PROJECT_ENDPOINT", "https://example.invalid/api/projects/p")

    assert toolbox.toolbox_endpoint() is None
    assert await toolbox.load_tools() == []


@pytest.mark.asyncio
async def test_unreachable_toolbox_degrades_instead_of_failing(monkeypatch):
    monkeypatch.setattr(toolbox, "_credential", _FakeCredential())
    monkeypatch.setenv("TOOLBOX_ENDPOINT", f"http://127.0.0.1:{_free_port()}/mcp")

    assert await toolbox.load_tools() == []
