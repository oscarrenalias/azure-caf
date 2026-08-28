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

        def _date_only(val: str) -> str:
            return val[:10] if val else ""

        t = data.get("type")
        if t == "order":
            created = _date_only(data.get("createdAt", ""))
            updated = _date_only(data.get("updatedAt", ""))
            date_parts = []
            if created:
                date_parts.append(f"Created: {created}")
            if updated:
                date_parts.append(f"Updated: {updated}")
            date_str = " · ".join(date_parts)
            rows = "\n".join(
                f"| {i.get('sku', i.get('product', ''))} | {i.get('name', i.get('sku', i.get('product', '')))} | {i.get('quantity', '')} |"
                for i in data.get("items", [])
            )
            return (
                f"| **Order {data.get('id', '')}** · *{data.get('status', '')}* | Customer: {data.get('customer', '')} | {date_str} |\n"
                f"|---|---|---|\n"
                f"| **SKU** | **Product** | **Qty** |\n"
                f"{rows}"
            )
        if t == "purchase_order":
            requested = _date_only(data.get("requestedAt", ""))
            delivery = data.get("estimatedDeliveryAt", "")
            date_parts = []
            if requested:
                date_parts.append(f"Requested: {requested}")
            if delivery:
                date_parts.append(f"Est. delivery: {_date_only(delivery) or delivery}")
            date_str = " · ".join(date_parts)
            rows = "\n".join(
                f"| {i.get('sku', i.get('product', ''))} | {i.get('name', i.get('sku', i.get('product', '')))} | {i.get('quantity', '')} |"
                for i in data.get("items", [])
            )
            return (
                f"| **Purchase Order {data.get('id', '')}** | Supplier: {data.get('supplier', '')} | {date_str} |\n"
                f"|---|---|---|\n"
                f"| **SKU** | **Product** | **Qty** |\n"
                f"{rows}"
            )
        if t == "stock":
            available = "Yes" if data.get("available") else "No"
            return (
                f"| **{data.get('product', '')}** | Available | Stock level |\n"
                f"|---|---|---|\n"
                f"| | {available} | {data.get('stockLevel', 0)} |"
            )
        return m.group(0)

    return pattern.sub(_replace, text)


@cl.on_chat_start
async def on_start():
    cl.user_session.set("previous_response_id", None)


@cl.on_message
async def main(message: cl.Message):
    previous_response_id = cl.user_session.get("previous_response_id")

    payload: dict = {"input": message.content, "stream": True}
    if previous_response_id:
        payload["previous_response_id"] = previous_response_id

    msg = cl.Message(content="")
    await msg.send()

    accumulated = ""
    response_id: str | None = None

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
                    elif event_type == "response.completed":
                        response_id = event.get("response", {}).get("id")

    except httpx.HTTPStatusError as exc:
        # In a streaming context exc.response.text requires a prior read(); log only the code.
        logger.error("Agent HTTP error %s", exc.response.status_code)
        await msg.stream_token(f"\n\nError: agent returned {exc.response.status_code}")
    except Exception:
        logger.exception("Unexpected error calling agent")
        await msg.stream_token("\n\nSomething went wrong. Please try again.")

    if response_id:
        cl.user_session.set("previous_response_id", response_id)

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
