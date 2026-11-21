"""Chat over the user's documents: route by summary cards (cheap model) -> answer from full text (main model).

Callers pass only documents the user is authorized to read. Loading full text is
delegated to `load_texts`, so this module has no database dependency.
"""

import json
from collections.abc import Callable
from dataclasses import dataclass, field

from vault.ai import prompts
from vault.ai.schemas import ChatAnswer, Citation, RouteDecision, SummaryCard
from vault.ai.text import normalize_text
from vault.llm import LLMClient, ModelRole, UsageLog

MAX_ROUTED_DOCS = 3


@dataclass(frozen=True)
class DocCard:
    document_id: str
    doc_type: str
    expires_on: str | None
    summary: SummaryCard


@dataclass
class ChatResult:
    found: bool
    answer: str
    citations: list[Citation]
    routed_document_ids: list[str]
    dropped_citations: int = 0
    usage: UsageLog = field(default_factory=UsageLog)
    prompt_version: str = prompts.PROMPT_VERSION


NOT_FOUND = "I could not find this in your documents."


def answer_question(
    llm: LLMClient,
    question: str,
    cards: list[DocCard],
    load_texts: Callable[[list[str]], dict[str, str]],
) -> ChatResult:
    usage = UsageLog()
    allowed = {c.document_id for c in cards}

    routed = llm.generate_json(
        role=ModelRole.ROUTER,
        system=prompts.ROUTER_SYSTEM.format(max_docs=MAX_ROUTED_DOCS),
        prompt=_router_prompt(question, cards),
        schema=RouteDecision,
    )
    usage.add(routed.usage)
    # Never trust ids from the model: keep only known ones, dedupe, cap.
    doc_ids = list(dict.fromkeys(i for i in routed.value.document_ids if i in allowed))[:MAX_ROUTED_DOCS]
    if not doc_ids:
        return ChatResult(found=False, answer=NOT_FOUND, citations=[], routed_document_ids=[], usage=usage)

    texts = load_texts(doc_ids)
    if not texts:
        return ChatResult(found=False, answer=NOT_FOUND, citations=[], routed_document_ids=doc_ids, usage=usage)
    answered = llm.generate_json(
        role=ModelRole.MAIN,
        system=prompts.ANSWER_SYSTEM,
        prompt=_answer_prompt(question, texts),
        schema=ChatAnswer,
    )
    usage.add(answered.usage)
    answer = answered.value

    normalized = {doc_id: normalize_text(source) for doc_id, source in texts.items()}
    valid = [
        citation for citation in answer.citations
        if (quote := normalize_text(citation.quote)) and quote in normalized.get(citation.document_id, "")
    ]
    dropped = len(answer.citations) - len(valid)
    found = answer.found and bool(valid)
    return ChatResult(
        found=found,
        # An answer without a verifiable citation is treated as not found.
        answer=answer.answer if found else NOT_FOUND,
        citations=valid,
        routed_document_ids=doc_ids,
        dropped_citations=dropped,
        usage=usage,
    )


def _router_prompt(question: str, cards: list[DocCard]) -> str:
    payload = [
        {"id": c.document_id, "type": c.doc_type, "expires_on": c.expires_on, **c.summary.model_dump()} for c in cards
    ]
    return f"Question: {question}\n\nDocument cards (JSON):\n{json.dumps(payload, ensure_ascii=False)}"


def _answer_prompt(question: str, texts: dict[str, str]) -> str:
    docs = "\n\n".join(f'<document id="{doc_id}">\n{text}\n</document>' for doc_id, text in texts.items())
    return f"{docs}\n\nQuestion: {question}"
