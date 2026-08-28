"""Chainlit chat UI for the RAG + Orders agent."""
from __future__ import annotations

import json
import logging
import os
import re
import sys

import chainlit as cl
import httpx
from azure.identity import DefaultAzureCredential

logging.basicConfig(
    stream=sys.stdout,
    level=logging.DEBUG,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logger = logging.getLogger("rag-ui")

for noisy in ("azure", "httpx", "httpcore", "urllib3"):
    logging.getLogger(noisy).setLevel(logging.WARNING)

FOUNDRY_PROJECT_ENDPOINT = os.environ.get("FOUNDRY_PROJECT_ENDPOINT", "")
AGENT_NAME = os.environ.get("AGENT_NAME", "rag-agent")
_AGENT_URL = (
    f"{FOUNDRY_PROJECT_ENDPOINT}/agents/{AGENT_NAME}"
    "/endpoint/protocols/openai/responses?api-version=v1"
)
_CONVERSATIONS_URL = f"{FOUNDRY_PROJECT_ENDPOINT}/openai/v1/conversations"

logger.info("Agent URL: %s", _AGENT_URL)
logger.info("AZURE_CLIENT_ID: %s", os.environ.get("AZURE_CLIENT_ID", "(not set)"))

_credential = DefaultAzureCredential()


def _token() -> str:
    tok = _credential.get_token("https://ai.azure.com/.default")
    return tok.token


def _render_cards(text: str) -> str:
    """Replace ```json blocks with known 'type' fields with formatted markdown cards."""
    pattern = re.compile(r"```json\s*\n(.*?)\n```", re.DOTALL)

    def _replace(m: re.Match) -> str:
        try:
            data = json.loads(m.group(1))
        except json.JSONDecodeError:
            return m.group(0)

        t = data.get("type")
        if t == "order":
            rows = "\n".join(
                f"| {i.get('product', '')} | {i.get('quantity', '')} |"
                for i in data.get("items", [])
            )
            return (
                f"**Order**: {data.get('id', '')}\n"
                f"**Customer**: {data.get('customer', '')}\n"
                f"**Status**: {data.get('status', '')}\n\n"
                f"| Product | Quantity |\n|---------|----------|\n{rows}"
            )
        if t == "purchase_order":
            rows = "\n".join(
                f"| {i.get('product', '')} | {i.get('quantity', '')} |"
                for i in data.get("items", [])
            )
            return (
                f"**Purchase Order**: {data.get('id', '')}\n"
                f"**Supplier**: {data.get('supplier', '')}\n"
                f"**Estimated Delivery**: {data.get('estimatedDeliveryAt', '')}\n\n"
                f"| Product | Quantity |\n|---------|----------|\n{rows}"
            )
        if t == "stock":
            available = "Yes" if data.get("available") else "No"
            return (
                f"**Product**: {data.get('product', '')}\n"
                f"**Available**: {available}\n"
                f"**Stock Level**: {data.get('stockLevel', 0)}"
            )
        return m.group(0)

    return pattern.sub(_replace, text)


@cl.on_chat_start
async def on_start():
    conversation_id: str | None = None
    try:
        async with httpx.AsyncClient(timeout=30) as client:
            resp = await client.post(
                _CONVERSATIONS_URL,
                json={},
                headers={
                    "Authorization": f"Bearer {_token()}",
                    "Content-Type": "application/json",
                },
            )
            resp.raise_for_status()
            conversation_id = resp.json().get("id")
            logger.info("Created conversation %s", conversation_id)
    except Exception:
        logger.exception("Failed to create conversation; will send without context")
    cl.user_session.set("conversation_id", conversation_id)


@cl.on_message
async def main(message: cl.Message):
    conversation_id = cl.user_session.get("conversation_id")

    payload: dict = {"input": message.content, "stream": True}
    if conversation_id:
        payload["conversation"] = conversation_id

    msg = cl.Message(content="")
    await msg.send()

    accumulated = ""

    try:
        async with httpx.AsyncClient(timeout=120) as client:
            async with client.stream(
                "POST",
                _AGENT_URL,
                json=payload,
                headers={
                    "Authorization": f"Bearer {_token()}",
                    "Content-Type": "application/json",
                },
            ) as resp:
                resp.raise_for_status()
                async for line in resp.aiter_lines():
                    if not line.startswith("data:"):
                        continue
                    raw = line[5:].strip()
                    if not raw or raw == "[DONE]":
                        continue
                    try:
                        event = json.loads(raw)
                    except json.JSONDecodeError:
                        continue

                    event_type = event.get("type", "")
                    if event_type == "response.output_text.delta":
                        delta = event.get("delta", "")
                        if delta:
                            accumulated += delta
                            await msg.stream_token(delta)

    except httpx.HTTPStatusError as exc:
        logger.error("Agent HTTP error %s: %s", exc.response.status_code, exc.response.text)
        await msg.stream_token(f"\n\nError: agent returned {exc.response.status_code}")
    except Exception:
        logger.exception("Unexpected error calling agent")
        await msg.stream_token("\n\nSomething went wrong. Please try again.")

    rendered = _render_cards(accumulated)
    awaiting = "AWAITING_CONFIRMATION" in rendered
    if awaiting:
        rendered = re.sub(r"\n?AWAITING_CONFIRMATION\s*$", "", rendered).rstrip()

    if rendered != accumulated or awaiting:
        msg.content = rendered
        if awaiting:
            msg.actions = [
                cl.Action(name="confirm", label="Confirm", value="yes"),
                cl.Action(name="cancel", label="Cancel", value="no"),
            ]
        await msg.update()


@cl.action_callback("confirm")
async def on_confirm(action: cl.Action):
    await action.remove()
    await main(cl.Message(content="yes"))


@cl.action_callback("cancel")
async def on_cancel(action: cl.Action):
    await action.remove()
    await main(cl.Message(content="no"))
