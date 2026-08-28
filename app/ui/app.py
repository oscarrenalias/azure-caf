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


_STATUS_BADGE: dict[str, tuple[str, str, str]] = {
    "pending":    ("#fbbf24", "rgba(251,191,36,0.15)",  "rgba(251,191,36,0.35)"),
    "completed":  ("#4ade80", "rgba(74,222,128,0.15)",  "rgba(74,222,128,0.35)"),
    "cancelled":  ("#f87171", "rgba(248,113,113,0.15)", "rgba(248,113,113,0.35)"),
    "processing": ("#60a5fa", "rgba(96,165,250,0.15)",  "rgba(96,165,250,0.35)"),
}
_CARD_STYLE = (
    "border:1px solid rgba(255,255,255,0.1);border-radius:12px;overflow:hidden;"
    "margin:12px 0;font-family:inherit;font-size:0.9em;line-height:1.5;"
)
_HDR_STYLE = (
    "padding:12px 16px;display:flex;align-items:center;gap:12px;"
    "border-bottom:1px solid rgba(255,255,255,0.08);background:rgba(255,255,255,0.03);"
)
_META_STYLE = (
    "padding:8px 16px;display:flex;gap:20px;flex-wrap:wrap;"
    "font-size:0.85em;color:rgba(255,255,255,0.45);"
    "border-bottom:1px solid rgba(255,255,255,0.08);"
)
_TH_STYLE = (
    "text-align:{align};padding:7px 16px;font-weight:600;font-size:0.78em;"
    "text-transform:uppercase;letter-spacing:0.06em;color:rgba(255,255,255,0.4);"
    "border-bottom:1px solid rgba(255,255,255,0.08);background:rgba(255,255,255,0.02);"
)
_TD_STYLE = "text-align:{align};padding:9px 16px;border-bottom:1px solid rgba(255,255,255,0.05);"


def _badge(status: str) -> str:
    color, bg, border = _STATUS_BADGE.get(
        status.lower(), ("#94a3b8", "rgba(148,163,184,0.15)", "rgba(148,163,184,0.35)")
    )
    return (
        f'<span style="background:{bg};color:{color};border:1px solid {border};'
        f'border-radius:20px;padding:2px 10px;font-size:0.78em;font-weight:500;">'
        f"{status}</span>"
    )


def _meta_item(label: str, value: str) -> str:
    return f'<span><span style="color:rgba(255,255,255,0.75);font-weight:500;">{label}</span> {value}</span>'


def _items_table(items: list[dict]) -> str:
    ths = "".join(
        f'<th style="{_TH_STYLE.format(align=a)}">{h}</th>'
        for h, a in [("SKU", "left"), ("Product", "left"), ("Qty", "right")]
    )
    trs = ""
    for i in items:
        sku = i.get("sku", i.get("product", ""))
        name = i.get("name", sku)
        qty = i.get("quantity", "")
        trs += (
            f"<tr>"
            f'<td style="{_TD_STYLE.format(align="left")};font-family:monospace;font-size:0.88em;">{sku}</td>'
            f'<td style="{_TD_STYLE.format(align="left")}">{name}</td>'
            f'<td style="{_TD_STYLE.format(align="right")}">{qty}</td>'
            f"</tr>"
        )
    return f'<table style="width:100%;border-collapse:collapse;"><thead><tr>{ths}</tr></thead><tbody>{trs}</tbody></table>'


def _date_only(val: str) -> str:
    return val[:10] if val else ""


def _render_cards(text: str) -> str:
    """Replace ```json blocks that carry a known 'type' field with styled HTML cards."""
    pattern = re.compile(r"```json\s*\n(.*?)\n```", re.DOTALL)

    def _replace(m: re.Match) -> str:
        try:
            data = json.loads(m.group(1))
        except json.JSONDecodeError:
            return m.group(0)

        t = data.get("type")

        if t == "order":
            status = data.get("status", "")
            meta = [_meta_item("Customer", data.get("customer", ""))]
            if c := _date_only(data.get("createdAt", "")):
                meta.append(_meta_item("Created", c))
            if u := _date_only(data.get("updatedAt", "")):
                meta.append(_meta_item("Updated", u))
            return (
                f'<div style="{_CARD_STYLE}">'
                f'<div style="{_HDR_STYLE}">'
                f'<span style="font-weight:600;font-size:1.05em;">Order {data.get("id", "")}</span>'
                f"{_badge(status)}"
                f"</div>"
                f'<div style="{_META_STYLE}">{"".join(meta)}</div>'
                f"{_items_table(data.get('items', []))}"
                f"</div>"
            )

        if t == "purchase_order":
            meta = [_meta_item("Supplier", data.get("supplier", ""))]
            if r := _date_only(data.get("requestedAt", "")):
                meta.append(_meta_item("Requested", r))
            if d := data.get("estimatedDeliveryAt", ""):
                meta.append(_meta_item("Est. delivery", _date_only(d) or d))
            return (
                f'<div style="{_CARD_STYLE}">'
                f'<div style="{_HDR_STYLE}">'
                f'<span style="font-weight:600;font-size:1.05em;">Purchase Order {data.get("id", "")}</span>'
                f"</div>"
                f'<div style="{_META_STYLE}">{"".join(meta)}</div>'
                f"{_items_table(data.get('items', []))}"
                f"</div>"
            )

        if t == "stock":
            avail_color = "#4ade80" if data.get("available") else "#f87171"
            avail_text = "In stock" if data.get("available") else "Out of stock"
            return (
                f'<div style="{_CARD_STYLE}">'
                f'<div style="{_HDR_STYLE}">'
                f'<span style="font-weight:600;font-size:1.05em;">{data.get("product", "")}</span>'
                f'<span style="color:{avail_color};font-size:0.85em;font-weight:500;">{avail_text}</span>'
                f"</div>"
                f'<div style="{_META_STYLE}">'
                f'{_meta_item("Stock level", str(data.get("stockLevel", 0)))}'
                f"</div>"
                f"</div>"
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
