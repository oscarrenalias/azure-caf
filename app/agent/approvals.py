"""Confirmation gate for tools that write to the system of record.

The Foundry Toolbox advertises `require_approval` on every tool it returns from
`tools/list`, under `_meta.tool_configuration` — but it does not act on it. From the
Toolbox documentation:

    The MCP endpoint doesn't block `tools/call`. Enforcement is entirely the agent
    runtime's responsibility.

So this is that enforcement, and it is deliberately not a prompt instruction. Telling
the model to ask first works most of the time, which is the worst possible property for
something that creates orders. The gate here is mechanical: a write cannot happen on
the same turn it is requested, and it cannot happen at all without an affirmative user
message in between.

The sequence across three turns:

    user   "create an order for acme with two widgets"
    model  -> createOrder(...)          gate holds it, returns APPROVAL_REQUIRED
    model  "I'll create ... — shall I go ahead?"
    user   "yes"                        gate marks the held call approved
    model  -> createOrder(...)          identical arguments, so it proceeds

Arguments are compared exactly. A model that gets approval for one order and then calls
with different arguments is stopped and has to ask again, which is the point: the user
approved a specific action, not a category of action.
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass, field
from typing import Any

logger = logging.getLogger("rag-agent.approvals")

# Kept short on purpose: a long list of near-synonyms buys little and makes a false
# positive — an unintended write — more likely. Anything unrecognised means "not
# approved", and the model asks again.
#
# Single words are matched as whole words and phrases as substrings, which matters more
# than it looks: "no" as a substring is inside "now", "nothing" and "another", so
# "yes, do it now" would otherwise be read as a refusal.
_AFFIRMATIVE_WORDS = frozenset(
    {"yes", "yep", "yeah", "yup", "ok", "okay", "sure", "confirm", "confirmed",
     "proceed", "correct", "affirmative", "approved"}
)
_AFFIRMATIVE_PHRASES = ("go ahead", "do it", "please do", "that's right", "sounds right")

_NEGATIVE_WORDS = frozenset(
    {"no", "nope", "don't", "cancel", "stop", "abort", "wait", "nevermind",
     "incorrect", "wrong"}
)
_NEGATIVE_PHRASES = ("do not", "not yet", "hold on", "never mind", "forget it",
                     "that's wrong", "leave it")


def _canonical(arguments: dict[str, Any]) -> str:
    return json.dumps(arguments, sort_keys=True, separators=(",", ":"))


def _normalise(text: str) -> tuple[str, set[str]]:
    """Lowercased text with punctuation flattened, plus its word set."""
    kept = [c if (c.isalnum() or c == "'") else " " for c in text.lower()]
    flattened = " ".join("".join(kept).split())
    return flattened, set(flattened.split())


@dataclass
class _Pending:
    tool: str
    arguments: str
    granted: bool = False


@dataclass
class ApprovalGate:
    """One held call per conversation, which is all a single agent turn can produce."""

    _pending: dict[str, _Pending] = field(default_factory=dict)

    def hold(self, conversation: str, tool: str, arguments: dict[str, Any]) -> str:
        """Record a request for approval and return what the model should be told."""
        self._pending[conversation] = _Pending(tool=tool, arguments=_canonical(arguments))
        logger.info("Held %s pending approval in conversation %s", tool, conversation)

        readable = ", ".join(f"{k}={json.dumps(v)}" for k, v in sorted(arguments.items()))
        return (
            "APPROVAL_REQUIRED — this tool writes to the system of record and has not "
            "been run. Nothing has changed.\n"
            f"Requested: {tool} with {readable or 'no arguments'}\n"
            "Tell the user in plain language exactly what you are about to do, then ask "
            "them to confirm. Do not claim it is done. When they agree, call the tool "
            "again with these same arguments."
        )

    def apply_user_reply(self, conversation: str, text: str) -> str | None:
        """Read the user's turn as an answer to a held request.

        Returns "granted", "declined", or None when the reply settles nothing.
        """
        pending = self._pending.get(conversation)
        if pending is None:
            return None

        reply, words = _normalise(text)

        # Negatives are checked first so "yes, but no — cancel that" is a refusal. When
        # a reply carries both signals, declining is the recoverable mistake.
        if words & _NEGATIVE_WORDS or any(p in reply for p in _NEGATIVE_PHRASES):
            del self._pending[conversation]
            logger.info("Declined %s in conversation %s", pending.tool, conversation)
            return "declined"

        if words & _AFFIRMATIVE_WORDS or any(p in reply for p in _AFFIRMATIVE_PHRASES):
            pending.granted = True
            logger.info("Approved %s in conversation %s", pending.tool, conversation)
            return "granted"

        return None

    def take(self, conversation: str, tool: str, arguments: dict[str, Any]) -> bool:
        """Consume an approval matching this exact call. True means go ahead."""
        pending = self._pending.get(conversation)
        if pending is None or not pending.granted:
            return False
        if pending.tool != tool or pending.arguments != _canonical(arguments):
            logger.info(
                "Approval in conversation %s does not match %s with these arguments",
                conversation,
                tool,
            )
            return False

        # Single use. A second write needs a second confirmation.
        del self._pending[conversation]
        return True
