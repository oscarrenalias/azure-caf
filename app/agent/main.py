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
from langchain_core.messages import AIMessage, HumanMessage, ToolMessage
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


def _strip_tool_messages(messages: list) -> list:
    """Remove tool-call/result pairs from history before passing to ainvoke.

    Foundry may reassign tool_call_ids when storing conversation history,
    breaking the OpenAI API's requirement that each ToolMessage's tool_call_id
    matches the preceding assistant tool_calls. Dropping both sides is safe:
    the final text response after each tool round is preserved and gives the
    model enough context. Keeping the "thinking" text from a tool-call
    AIMessage (the model's preamble before calling) causes the model to
    mistake it for an open confirmation request on the next turn.
    """
    result = []
    for msg in messages:
        if isinstance(msg, ToolMessage):
            continue
        if isinstance(msg, AIMessage) and msg.tool_calls:
            continue
        result.append(msg)
    return result


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

        history = await context.get_history()
        if not history:
            history = [HumanMessage(content=user_text)]
        else:
            history = _strip_tool_messages(history)
            if not history:
                history = [HumanMessage(content=user_text)]
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
                {"messages": history}, stream_mode="messages"
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
