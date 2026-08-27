"""LangGraph RAG agent hosted on Azure AI Foundry Agent Service (Responses protocol)."""
from __future__ import annotations

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

from tools import search_knowledge_base

_credential = DefaultAzureCredential()
_model = AzureAIOpenAIApiChatModel(
    project_endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
    credential=_credential,
    model=os.environ.get("AZURE_AI_MODEL_DEPLOYMENT_NAME", "apim-gateway/gpt-4o"),
)
_INSTRUCTIONS = "You are a helpful assistant."
_agent = create_react_agent(_model, tools=[search_knowledge_base], prompt=_INSTRUCTIONS)

server = ResponsesAgentServerHost(
    options=ResponsesServerOptions(default_fetch_history_count=20)
)


@server.response_handler
async def handle_response(
    request: CreateResponse,
    context: ResponseContext,
    cancellation_signal,
) -> TextResponse:
    user_text = await context.get_input_text()
    result = await _agent.ainvoke({"messages": [("user", user_text)]})
    # Read `.text`, not `.content`: over the Responses API the reply arrives as a
    # list of content blocks, and TextResponse only accepts str/callable/AsyncIterable.
    final_text = result["messages"][-1].text
    return TextResponse(context, request, text=final_text)


if __name__ == "__main__":
    server.run()
