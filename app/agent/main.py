"""LangGraph RAG agent hosted on Azure AI Foundry Agent Service (Responses protocol)."""
from __future__ import annotations

import asyncio
import logging
import os
import traceback

from azure.ai.agentserver.responses import (
    CreateResponse,
    ResponseContext,
    ResponsesAgentServerHost,
    ResponsesServerOptions,
    TextResponse,
)
from azure.identity import DefaultAzureCredential
from langchain_azure_ai.chat_models import AzureAIOpenAIApiChatModel
from langchain_core.messages import AIMessage, ToolMessage
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

    The Foundry platform may reassign tool_call_ids when storing conversation
    history, which breaks the OpenAI API's requirement that tool_call_id in
    each ToolMessage matches an id in the preceding assistant tool_calls.  The
    model has enough context from the text messages (user prompts + assistant
    confirmations) to continue the conversation correctly without them.
    """
    result = []
    for msg in messages:
        if isinstance(msg, ToolMessage):
            continue
        if isinstance(msg, AIMessage) and msg.tool_calls:
            # Keep text content if any; drop the tool_calls themselves.
            text = msg.content if isinstance(msg.content, str) else ""
            if text:
                result.append(AIMessage(content=text))
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
            history = [("user", user_text)]
        else:
            history = _strip_tool_messages(history)
            if not history:
                history = [("user", user_text)]

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
    except Exception as exc:
        # Surface the full traceback as the response text so it's visible in the UI
        # during debugging.  Remove this broad handler once the root cause is confirmed.
        tb = traceback.format_exc()
        logger.exception("Agent invocation failed in conversation %s", context.conversation_id)
        final_text = f"[DEBUG] {type(exc).__name__}: {exc}\n\n{tb}"

    return TextResponse(context, request, text=final_text)


if __name__ == "__main__":
    server.run()
