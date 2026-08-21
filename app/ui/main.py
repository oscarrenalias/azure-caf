"""FastAPI chat UI that talks to the hosted LangGraph RAG agent via Responses API."""
from __future__ import annotations

import os

import httpx
from azure.identity import DefaultAzureCredential
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.templating import Jinja2Templates

app = FastAPI()
templates = Jinja2Templates(directory="templates")

FOUNDRY_PROJECT_ENDPOINT = os.environ.get("FOUNDRY_PROJECT_ENDPOINT", "")
AGENT_NAME = os.environ.get("AGENT_NAME", "rag-agent")
_AGENT_URL = (
    f"{FOUNDRY_PROJECT_ENDPOINT}/agents/{AGENT_NAME}"
    "/endpoint/protocols/openai/responses?api-version=v1"
)

_credential = DefaultAzureCredential()


def _token() -> str:
    return _credential.get_token("https://cognitiveservices.azure.com/.default").token


@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    return templates.TemplateResponse("chat.html", {"request": request})


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
            resp.raise_for_status()
            result = resp.json()
    except httpx.HTTPStatusError as exc:
        return JSONResponse(
            {"error": f"Agent returned {exc.response.status_code}: {exc.response.text}"},
            status_code=502,
        )
    except Exception as exc:
        return JSONResponse({"error": str(exc)}, status_code=502)

    text = _extract_text(result)
    return JSONResponse({"response": text, "response_id": result.get("id")})


def _extract_text(result: dict) -> str:
    parts: list[str] = []
    for item in result.get("output", []):
        if item.get("type") == "message":
            for content in item.get("content", []):
                if content.get("type") == "output_text":
                    parts.append(content.get("text", ""))
    return "".join(parts)
