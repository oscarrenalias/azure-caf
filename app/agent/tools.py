"""RAG tool: hybrid (keyword + vector) search over the indexed books."""

from __future__ import annotations

import logging
import os
from functools import lru_cache
from typing import Annotated

from azure.core.credentials import AzureKeyCredential
from azure.search.documents import SearchClient
from azure.search.documents.models import VectorizableTextQuery
from langchain_core.tools import tool

logger = logging.getLogger("rag-agent.tools")

_INDEX_NAME = "knowledge-base"
_TOP_K = 5


@lru_cache(maxsize=1)
def _search_client() -> SearchClient:
    return SearchClient(
        endpoint=os.environ["SEARCH_ENDPOINT"],
        index_name=os.environ.get("SEARCH_INDEX_NAME", _INDEX_NAME),
        credential=AzureKeyCredential(os.environ["SEARCH_API_KEY"]),
    )


@tool
def search_knowledge_base(
    query: Annotated[str, "The question or topic to look up in the books."],
) -> str:
    """Search the works of Homer — the Iliad and the Odyssey — for relevant passages.

    Use this whenever the user asks about the events, characters, places or language of
    either poem. Each result names the book it came from, so quote that when answering.
    """
    try:
        # Hybrid: BM25 over `search_text` fused with vector similarity. The vector is
        # produced by the index's own vectorizer — the agent sends text, Azure AI Search
        # embeds it with the same model used at indexing time. That is deliberate: it
        # keeps one embedding configuration rather than two that can silently diverge,
        # and it means this container needs no model credentials at all.
        vector_query = VectorizableTextQuery(
            text=query,
            k_nearest_neighbors=_TOP_K,
            fields="vector",
        )
        results = _search_client().search(
            search_text=query,
            vector_queries=[vector_query],
            select=["chunk", "chapter", "title", "author", "translator"],
            top=_TOP_K,
        )

        passages = []
        for r in results:
            citation = f"{r.get('title')}, {r.get('chapter')}"
            passages.append(f"**{citation}**\n{r.get('chunk', '').strip()}")

        return "\n\n---\n\n".join(passages) if passages else "No relevant passages found."
    except Exception as exc:
        # Returned as text so the agent can keep going, but log it too: a network
        # or auth failure here otherwise looks identical to "no documents found".
        logger.exception("Knowledge base search failed for query %r", query)
        return f"Search error: {type(exc).__name__}: {exc}"
