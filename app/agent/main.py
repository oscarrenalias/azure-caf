"""LangGraph RAG agent hosted on Azure AI Foundry Agent Service (Responses protocol)."""
from __future__ import annotations

import asyncio
import logging
import os

from azure.ai.agentserver.responses import (
    CreateResponse,
    ResponseContext,
    ResponsesAgentServerHost,
    ResponsesServerOptions,
    TextResponse,
)
from azure.identity import DefaultAzureCredential
from langchain_azure_ai.chat_models import AzureAIOpenAIApiChatModel
from langgraph.errors import GraphRecursionError
from langgraph.prebuilt import create_react_agent

from config import INSTRUCTIONS, INSTRUCTIONS_WITHOUT_ORDERS
from toolbox import current_conversation, gate, load_tools
from tools import search_knowledge_base

logger = logging.getLogger("rag-agent")

_credential = DefaultAzureCredential()
_model = AzureAIOpenAIApiChatModel(
    project_endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
    credential=_credential,
    model=os.environ.get("AZURE_AI_MODEL_DEPLOYMENT_NAME", "apim-gateway/gpt-4o"),
)

# Load toolbox tools synchronously at startup so the agent is ready on the first request.
# asyncio.run() creates a new event loop; the agentserver framework replaces it later.
_toolbox_tools = asyncio.run(load_tools())

# When the toolbox isn't available, drop the order instructions entirely so the model
# doesn't generate tool calls that aren't in the registry — LangGraph raises ValueError
# for unknown tool names, which propagates as HTTP 500.
_instructions = INSTRUCTIONS if _toolbox_tools else INSTRUCTIONS_WITHOUT_ORDERS
_agent = create_react_agent(
    _model, tools=[search_knowledge_base] + _toolbox_tools, prompt=_instructions
)

server = ResponsesAgentServerHost(
    options=ResponsesServerOptions(default_fetch_history_count=20)
)


@server.response_handler
async def handle_response(
    request: CreateResponse,
    context: ResponseContext,
    cancellation_signal,
) -> TextResponse:
    current_conversation.set(context.conversation_id)

    # Read the user's input first — needed for two reasons:
    # 1. If history is empty (first turn) it becomes the seed message.
    # 2. It is checked against the approval gate BEFORE ainvoke so that a pending
    #    write can be released. Without this, gate.take() always returns False,
    #    gate.hold() fires again on every call, and the model loops until
    #    GraphRecursionError → HTTP 500.
    user_text = await context.get_input_text()
    gate.apply_user_reply(context.conversation_id, user_text)

    history = await context.get_history()
    if not history:
        history = [("user", user_text)]

    try:
        result = await _agent.ainvoke({"messages": history})
        # Read `.text`, not `.content`: over the Responses API the reply arrives as a
        # list of content blocks, and TextResponse only accepts str/callable/AsyncIterable.
        last = result["messages"][-1]
        final_text = getattr(last, "text", None) or (
            last.content if isinstance(last.content, str) else str(last.content)
        )
    except GraphRecursionError:
        logger.exception("Recursion limit hit in conversation %s", context.conversation_id)
        final_text = (
            "I couldn't complete that in one step. Could you rephrase or try again?"
        )
    except Exception:
        logger.exception("Agent invocation failed in conversation %s", context.conversation_id)
        raise

    return TextResponse(context, request, text=final_text)


if __name__ == "__main__":
    server.run()
