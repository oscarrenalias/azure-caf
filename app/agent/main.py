"""LangGraph RAG agent hosted on Azure AI Foundry Agent Service (Responses protocol)."""

from __future__ import annotations

import os

from azure.identity.aio import DefaultAzureCredential as AsyncDefaultAzureCredential
from azure.identity import DefaultAzureCredential
from langchain.agents import create_agent
from langchain_azure_ai.agents.hosting import ResponsesHostServer
from langchain_azure_ai.chat_models import AzureAIOpenAIApiChatModel

from tools import search_knowledge_base


def _build_store():
    """Build FoundryStorageProvider with the platform-injected instance identity.

    The library's default auto-detection calls DefaultAzureCredential() without
    managed_identity_client_id, which fails with "ambiguous managed identity" when
    the container has multiple user-assigned MIs. We provide the store explicitly.
    """
    from azure.ai.agentserver.core._config import AgentConfig
    from azure.ai.agentserver.responses.store._foundry_provider import FoundryStorageProvider
    from azure.ai.agentserver.responses.store._foundry_settings import FoundryStorageSettings

    config = AgentConfig.from_env()
    if not (config.is_hosted and config.project_endpoint):
        return None

    instance_client_id = os.environ.get("FOUNDRY_AGENT_INSTANCE_CLIENT_ID")
    credential = AsyncDefaultAzureCredential(managed_identity_client_id=instance_client_id)
    settings = FoundryStorageSettings.from_endpoint(config.project_endpoint)
    return FoundryStorageProvider(credential, settings)


def main() -> None:
    instance_client_id = os.environ.get("FOUNDRY_AGENT_INSTANCE_CLIENT_ID")
    credential = DefaultAzureCredential(managed_identity_client_id=instance_client_id)
    model = AzureAIOpenAIApiChatModel(
        project_endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
        credential=credential,
        model=os.environ.get("AZURE_AI_MODEL_DEPLOYMENT_NAME", "apim-gateway/gpt-4o"),
    )
    graph = create_agent(model, tools=[search_knowledge_base])
    ResponsesHostServer(graph, store=_build_store()).run()


if __name__ == "__main__":
    main()
