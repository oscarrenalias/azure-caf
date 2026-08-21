"""FastAPI chat UI that talks to the hosted LangGraph RAG agent via Responses API."""
from __future__ import annotations

import logging
import os
import sys

import httpx
from azure.identity import DefaultAzureCredential
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.templating import Jinja2Templates

logging.basicConfig(
    stream=sys.stdout,
    level=logging.DEBUG,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logger = logging.getLogger("rag-ui")

# Quieten noisy SDK loggers but keep them at WARNING so their errors still surface
for noisy in ("azure", "httpx", "httpcore", "urllib3"):
    logging.getLogger(noisy).setLevel(logging.WARNING)

app = FastAPI()
templates = Jinja2Templates(directory="templates")

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
    logger.debug("Acquiring token for cognitiveservices scope")
    tok = _credential.get_token("https://cognitiveservices.azure.com/.default")
    logger.debug("Token acquired, expires at %s", tok.expires_on)
    return tok.token


@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    return templates.TemplateResponse(request=request, name="chat.html")


@app.post("/chat")
async def chat(request: Request):
    body = await request.json()
    message: str = body.get("message", "").strip()
    previous_response_id: str | None = body.get("previous_response_id")

    if not message:
        return JSONResponse({"error": "empty message"}, status_code=400)

    payload: dict = {"input": message, "stream": False}
    if previous_response_id:
        payload["previous_response_id"] = previous_response_id

    logger.info("POST %s  previous_id=%s", _AGENT_URL, previous_response_id)

    try:
        async with httpx.AsyncClient(timeout=120) as client:
            resp = await client.post(
                _AGENT_URL,
                json=payload,
                headers={
                    "Authorization": f"Bearer {_token()}",
                    "Content-Type": "application/json",
                },
            )
            logger.info("Agent response: HTTP %s", resp.status_code)
            resp.raise_for_status()
            result = resp.json()
    except httpx.HTTPStatusError as exc:
        body_text = exc.response.text
        logger.error(
            "Agent HTTP error %s: %s", exc.response.status_code, body_text
        )
        return JSONResponse(
            {"error": f"Agent returned {exc.response.status_code}: {body_text}"},
            status_code=502,
        )
    except Exception:
        logger.exception("Unexpected error calling agent")
        raise

    text = _extract_text(result)
    logger.info("Agent reply: %d chars", len(text))
    return JSONResponse({"response": text, "response_id": result.get("id")})


def _extract_text(result: dict) -> str:
    parts: list[str] = []
    for item in result.get("output", []):
        if item.get("type") == "message":
            for content in item.get("content", []):
                if content.get("type") == "output_text":
                    parts.append(content.get("text", ""))
    return "".join(parts)
