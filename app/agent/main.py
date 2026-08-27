"""LangGraph RAG agent hosted on Azure AI Foundry Agent Service (Responses protocol)."""
from __future__ import annotations

import asyncio
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
from langgraph.prebuilt import create_react_agent

from config import INSTRUCTIONS
from toolbox import current_conversation, load_tools
from tools import search_knowledge_base

_credential = DefaultAzureCredential()
_model = AzureAIOpenAIApiChatModel(
    project_endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
    credential=_credential,
    model=os.environ.get("AZURE_AI_MODEL_DEPLOYMENT_NAME", "apim-gateway/gpt-4o"),
)

# Load toolbox tools synchronously at startup so the agent is ready on the first request.
# asyncio.run() creates a new event loop; the agentserver framework replaces it later.
_toolbox_tools = asyncio.run(load_tools())
_agent = create_react_agent(
    _model, tools=[search_knowledge_base] + _toolbox_tools, prompt=INSTRUCTIONS
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
    history = await context.get_history()
    if not history:
        user_text = await context.get_input_text()
        history = [("user", user_text)]
    result = await _agent.ainvoke({"messages": history})
    # Read `.text`, not `.content`: over the Responses API the reply arrives as a
    # list of content blocks, and TextResponse only accepts str/callable/AsyncIterable.
    final_text = result["messages"][-1].text
    return TextResponse(context, request, text=final_text)


if __name__ == "__main__":
    server.run()
