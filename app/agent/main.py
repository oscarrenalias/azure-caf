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
from azure.ai.agentserver.responses.models._helpers import to_item
from azure.identity import DefaultAzureCredential
from langchain_azure_ai.agents.hosting._converters import build_messages_input
from langchain_azure_ai.chat_models import AzureAIOpenAIApiChatModel
from langchain_core.messages import AIMessage, HumanMessage
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
    try:
        current_conversation.set(context.conversation_id)

        # Read the user's input before fetching history so the approval gate can
        # release a pending write when the user confirms.  Without this call,
        # gate.take() always returns False, gate.hold() fires every time and
        # instructs the model to retry, the model does, and the loop hits
        # LangGraph's recursion limit → GraphRecursionError → HTTP 500.
        user_text = await context.get_input_text()
        gate.apply_user_reply(context.conversation_id, user_text)

        # get_history() returns OutputItem TypedDicts from previous turns (not
        # including the current turn's input). Convert each to an Item via
        # to_item() (which re-types "output_message" → "message"), then combine
        # with the current turn's input items so the agent sees the full context.
        # build_messages_input converts everything to LangChain messages and
        # filters out incomplete tool-call/result pairs caused by Foundry
        # reassigning call_ids across turns.
        current_items = list(await context.get_input_items())
        history_output_items = await context.get_history()
        history_items = [
            it
            for output_item in history_output_items
            if (it := to_item(output_item)) is not None
        ]
        graph_input = build_messages_input(history_items + current_items)
        if not graph_input.get("messages"):
            graph_input = {"messages": [HumanMessage(content=user_text)]}
    except Exception:
        logger.exception("Agent setup failed in conversation %s", context.conversation_id)
        return TextResponse(context, request, text="Something went wrong. Please try again.")

    def _text_from_content(content) -> str:
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            return "".join(
                block.get("text", "") if isinstance(block, dict) else str(block)
                for block in content
            )
        return str(content)

    async def _generate():
        try:
            async for chunk, _ in _agent.astream(
                graph_input, stream_mode="messages"
            ):
                if isinstance(chunk, AIMessage) and not chunk.tool_calls and chunk.content:
                    text = _text_from_content(chunk.content)
                    if text:
                        yield text
        except GraphRecursionError:
            logger.exception("Recursion limit hit in conversation %s", context.conversation_id)
            yield "I couldn't complete that in one step. Could you rephrase or try again?"
        except Exception:
            logger.exception("Agent streaming failed in conversation %s", context.conversation_id)
            yield "Something went wrong. Please try again."

    return TextResponse(context, request, text=_generate())


if __name__ == "__main__":
    server.run()
