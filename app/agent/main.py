"""LangGraph RAG agent hosted on Azure AI Foundry Agent Service (Responses protocol)."""

from __future__ import annotations

import os

from azure.identity import DefaultAzureCredential
from langchain.agents import create_agent
from langchain_azure_ai.agents.hosting import ResponsesHostServer
from langchain_azure_ai.chat_models import AzureAIOpenAIApiChatModel

from tools import search_knowledge_base


def main() -> None:
    model = AzureAIOpenAIApiChatModel(
        project_endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
        credential=DefaultAzureCredential(),
        model=os.environ.get("AZURE_AI_MODEL_DEPLOYMENT_NAME", "apim-gateway/gpt-4o"),
    )
    graph = create_agent(model, tools=[search_knowledge_base])
    port = int(os.environ.get("PORT", "8088"))
    ResponsesHostServer(graph).run(port=port)


if __name__ == "__main__":
    main()
