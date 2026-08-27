"""Conversation history handling.

Worth its own tests because the failure mode is silent: `get_history()` is a coroutine,
and calling it without awaiting yields a coroutine object that the loop below simply
finds nothing in. The agent then behaves as if every turn were the first, and the
confirmation flow quietly stops working while everything still looks fine.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

os.environ.setdefault(
    "FOUNDRY_PROJECT_ENDPOINT", "https://example.services.ai.azure.com/api/projects/p"
)
os.environ.setdefault("SEARCH_ENDPOINT", "https://example.search.windows.net")
os.environ.setdefault("SEARCH_API_KEY", "not-a-key")
# Importing main starts the agent-server telemetry, which then floods the test output
# with export failures because there is no collector on a workstation.
os.environ.setdefault("OTEL_SDK_DISABLED", "true")
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import main  # noqa: E402


class _Content:
    def __init__(self, text: str) -> None:
        self.text = text


class _Item:
    def __init__(self, type_: str, role: str | None = None, texts=()) -> None:
        self.type = type_
        self.role = role
        self.content = [_Content(t) for t in texts]


class _Context:
    def __init__(self, items) -> None:
        self._items = items

    async def get_history(self):
        return self._items


@pytest.mark.asyncio
async def test_messages_come_back_in_order_with_roles():
    context = _Context(
        [
            _Item("message", "user", ["I'd like to order some widgets"]),
            _Item("message", "assistant", ["Which customer is this for?"]),
            _Item("message", "user", ["acme-industries"]),
        ]
    )

    assert await main._history_to_messages(context) == [
        ("user", "I'd like to order some widgets"),
        ("assistant", "Which customer is this for?"),
        ("user", "acme-industries"),
    ]


@pytest.mark.asyncio
async def test_non_message_items_and_empty_messages_are_skipped():
    context = _Context(
        [
            _Item("mcp_call", None, ["{}"]),
            _Item("reasoning", None, ["thinking"]),
            _Item("message", "assistant", []),
            _Item("message", "tool", ["tool chatter"]),
            _Item("message", "user", ["hello"]),
        ]
    )

    assert await main._history_to_messages(context) == [("user", "hello")]


@pytest.mark.asyncio
async def test_multi_part_content_is_joined():
    context = _Context([_Item("message", "user", ["two widgets", "for acme"])])

    assert await main._history_to_messages(context) == [("user", "two widgets\nfor acme")]


@pytest.mark.asyncio
async def test_empty_history_is_not_an_error():
    assert await main._history_to_messages(_Context([])) == []
