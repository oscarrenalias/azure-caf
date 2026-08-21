"""RAG tool: hybrid (keyword + vector) search over the AI Search knowledge base."""

from __future__ import annotations

import os
from functools import lru_cache
from typing import Annotated

from azure.core.credentials import AzureKeyCredential
from azure.search.documents import SearchClient
from azure.search.documents.models import VectorizedQuery
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential
from langchain_core.tools import tool

_INDEX_NAME = "knowledge-base"
_EMBEDDING_MODEL = "apim-gateway/text-embedding-3-small"
_TOP_K = 5


@lru_cache(maxsize=1)
def _openai_client():
    project = AIProjectClient(
        endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
        credential=DefaultAzureCredential(),
    )
    return project.get_openai_client()


@lru_cache(maxsize=1)
def _search_client() -> SearchClient:
    return SearchClient(
        endpoint=os.environ["SEARCH_ENDPOINT"],
        index_name=os.environ.get("SEARCH_INDEX_NAME", _INDEX_NAME),
        credential=AzureKeyCredential(os.environ["SEARCH_API_KEY"]),
    )


def _embed(text: str) -> list[float]:
    resp = _openai_client().embeddings.create(input=text, model=_EMBEDDING_MODEL)
    return resp.data[0].embedding


@tool
def search_knowledge_base(
    query: Annotated[str, "The question or topic to look up in the knowledge base."],
) -> str:
    """Search the knowledge base for relevant information using hybrid search.

    Use this tool whenever the user asks about Azure AI Foundry, Azure AI Search,
    LangChain, LangGraph, or any topic that may be covered in the knowledge base.
    """
    try:
        vector_query = VectorizedQuery(
            vector=_embed(query),
            k_nearest_neighbors=_TOP_K,
            fields="embedding",
        )
        results = _search_client().search(
            search_text=query,
            vector_queries=[vector_query],
            select=["title", "content", "source"],
            top=_TOP_K,
        )
        chunks = [
            f"**{r['title']}** (source: {r['source']})\n{r['content']}"
            for r in results
        ]
        return "\n\n---\n\n".join(chunks) if chunks else "No relevant documents found."
    except Exception as exc:
        return f"Search error: {exc}"
