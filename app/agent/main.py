"""LangGraph RAG agent hosted on Azure AI Foundry Agent Service (Responses protocol).

Conversation state is managed server-side via previous_response_id — no
application-side session storage needed.
"""

from __future__ import annotations

import os
from functools import lru_cache

from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from dotenv import load_dotenv
from langchain.agents import create_agent
from langchain_openai import ChatOpenAI
from langchain_azure_ai.agents.hosting import ResponsesHostServer

from tools import search_knowledge_base

load_dotenv()

_AZURE_AI_SCOPE = "https://ai.azure.com/.default"


@lru_cache(maxsize=1)
def _project_client() -> AIProjectClient:
    return AIProjectClient(
        endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
        credential=DefaultAzureCredential(),
    )


def _build_chat_model() -> ChatOpenAI:
    credential = DefaultAzureCredential()
    openai_client = _project_client().get_openai_client()
    token_provider = get_bearer_token_provider(credential, _AZURE_AI_SCOPE)

    return ChatOpenAI(
        model=os.environ.get("AZURE_AI_MODEL_DEPLOYMENT_NAME", "apim-gateway/gpt-4o"),
        base_url=str(openai_client.base_url),
        api_key=token_provider,
        use_responses_api=True,
        output_version="responses/v1",
    )


def main() -> None:
    graph = create_agent(
        _build_chat_model(),
        tools=[search_knowledge_base],
    )
    port = int(os.environ.get("PORT", "8088"))
    ResponsesHostServer(graph).run(port=port)


if __name__ == "__main__":
    main()
