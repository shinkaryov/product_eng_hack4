"""Chat over the user's documents: route by summary cards (cheap model) -> answer from full text (main model).

The router also rewrites follow-ups into a standalone question, using recent turns and the documents
cited in the previous answer. Citations are verified against document text and returned as numbered
sources that match [n] markers in the answer.

Callers pass only documents the user is authorized to read. Loading full text is
delegated to `load_texts`, so this module has no database dependency.

Both prompts get today's date, so questions like "is my passport still valid?" can be answered.
A document-bound session skips the router: there is only one document to read.
Large vaults are pre-filtered by keyword overlap before routing, so the router prompt stays bounded.
"""

import json
import re
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from datetime import date

from vault.ai import prompts
from vault.ai.schemas import ChatAnswer, RouteDecision, Source, SummaryCard
from vault.ai.text import normalize_text
from vault.llm import LLMClient, ModelRole, UsageLog

MAX_ROUTED_DOCS = 3
MAX_HISTORY_ANSWER_CHARS = 600
MAX_ROUTER_CARDS = 40  # above this, cards are pre-filtered by keyword overlap before the router call


@dataclass(frozen=True)
class DocCard:
    document_id: str
    doc_type: str
    expires_on: str | None
    summary: SummaryCard


@dataclass(frozen=True)
class Turn:
    question: str
    answer: str


@dataclass
class ChatResult:
    found: bool
    answer: str
    citations: list[Source]
    routed_document_ids: list[str]
    standalone_question: str = ""
    dropped_citations: int = 0
    usage: UsageLog = field(default_factory=UsageLog)
    prompt_version: str = prompts.PROMPT_VERSION


NOT_FOUND = "I could not find this in your documents."
NOT_FOUND_UK = "Я не знайшов цього у ваших документах."
_CYRILLIC = re.compile(r"[\u0400-\u04ff]")


def not_found_message(question: str) -> str:
    """Fixed (never model-written) not-found text in the language of the question."""
    return NOT_FOUND_UK if _CYRILLIC.search(question) else NOT_FOUND


def answer_question(
    llm: LLMClient,
    question: str,
    cards: list[DocCard],
    load_texts: Callable[[list[str]], dict[str, str]],
    history: Sequence[Turn] = (),
    previous_document_ids: Sequence[str] = (),
    document_bound: bool = False,
    today: date | None = None,
) -> ChatResult:
    usage = UsageLog()
    today_line = f"\nToday's date: {(today or date.today()).isoformat()}."
    not_found = not_found_message(question)
    by_id = {c.document_id: c for c in cards}
    previous = [i for i in previous_document_ids if i in by_id]

    if document_bound and len(cards) == 1:
        # One document in scope: nothing to route, the answer model sees the history itself.
        standalone, doc_ids = question, [cards[0].document_id]
    else:
        candidates = _prefilter(question, cards, history, previous)
        routed = llm.generate_json(
            role=ModelRole.ROUTER,
            system=prompts.ROUTER_SYSTEM.format(max_docs=MAX_ROUTED_DOCS) + today_line,
            prompt=_router_prompt(question, candidates, history, previous),
            schema=RouteDecision,
        )
        usage.add(routed.usage)
        standalone = routed.value.standalone_question.strip() or question
        # Never trust ids from the model: keep only known ones, dedupe, cap.
        doc_ids = list(dict.fromkeys(i for i in routed.value.document_ids if i in by_id))[:MAX_ROUTED_DOCS]
    if not doc_ids:
        return ChatResult(found=False, answer=not_found, citations=[], routed_document_ids=[],
                          standalone_question=standalone, usage=usage)

    texts = load_texts(doc_ids)
    if not texts:
        return ChatResult(found=False, answer=not_found, citations=[], routed_document_ids=doc_ids, usage=usage)
    answered = llm.generate_json(
        role=ModelRole.MAIN,
        system=prompts.ANSWER_SYSTEM + today_line,
        prompt=_answer_prompt(question, standalone, texts, history),
        schema=ChatAnswer,
    )
    usage.add(answered.usage)
    answer = answered.value

    sources, renumber = _verified_sources(answer, texts, by_id)
    found = answer.found and bool(sources)
    return ChatResult(
        found=found,
        # An answer without a verifiable citation is treated as not found.
        answer=_renumber_markers(answer.answer, renumber, sources) if found else not_found,
        citations=sources if found else [],
        routed_document_ids=doc_ids,
        standalone_question=standalone,
        dropped_citations=sum(1 for n in renumber.values() if n is None),
        usage=usage,
    )


def _verified_sources(answer: ChatAnswer, texts: dict[str, str], by_id: dict[str, DocCard]):
    """Keep citations whose quote is in the cited document; dedupe; map old 1-based positions to new ones."""
    sources: list[Source] = []
    seen: dict[tuple[str, str], int] = {}
    renumber: dict[int, int | None] = {}
    for old, c in enumerate(answer.citations, start=1):
        text = texts.get(c.document_id)
        quote = normalize_text(c.quote)
        if text is None or not quote or quote not in normalize_text(text):
            renumber[old] = None
            continue
        key = (c.document_id, quote)
        if key not in seen:
            card = by_id[c.document_id]
            seen[key] = len(sources) + 1
            sources.append(Source(n=seen[key], document_id=c.document_id, document_title=card.summary.title,
                                  category=card.doc_type, quote=c.quote.strip()))
        renumber[old] = seen[key]
    return sources, renumber


_MARKER_RUN = re.compile(r"(\s?)((?:\[[\w-]+\])+)")


def _renumber_markers(text: str, renumber: dict[int, int | None], sources: list[Source]) -> str:
    """Point [n] markers at verified sources; drop markers of unverified or unknown citations.

    Models sometimes write a document id instead of a number ([home_ins]); map it to that document's first source.
    """
    first_by_doc = {}
    for s in sources:
        first_by_doc.setdefault(s.document_id, s.n)

    def resolve(token: str) -> int | None:
        return renumber.get(int(token)) if token.isdigit() else first_by_doc.get(token)

    def sub(m: re.Match) -> str:
        tokens = re.findall(r"\[([\w-]+)\]", m.group(2))
        if not all(t.isdigit() or t in first_by_doc for t in tokens):
            return m.group(0)  # ordinary bracketed text, not a citation marker
        news = list(dict.fromkeys(n for n in map(resolve, tokens) if n))
        return m.group(1) + "".join(f"[{n}]" for n in news) if news else ""

    return _MARKER_RUN.sub(sub, text)


_HISTORY_MARKER = re.compile(r"\s?\[\d+\]")


def _history_block(history: Sequence[Turn]) -> str:
    lines = []
    for t in history:
        # [n] markers pointed at the sources of that turn; they would only confuse the next one.
        answer = _HISTORY_MARKER.sub("", t.answer)
        answer = answer if len(answer) <= MAX_HISTORY_ANSWER_CHARS else answer[:MAX_HISTORY_ANSWER_CHARS] + "…"
        lines.append(f"User: {t.question}\nAssistant: {answer}")
    return "\n".join(lines)


def _router_prompt(question: str, cards: list[DocCard], history: Sequence[Turn], previous: list[str]) -> str:
    payload = [
        {"id": c.document_id, "type": c.doc_type, "expires_on": c.expires_on, **c.summary.model_dump()} for c in cards
    ]
    # Stable, large part first (better prefix caching and long-context recall), the question last.
    parts = [f"Document cards (JSON):\n{json.dumps(payload, ensure_ascii=False)}"]
    if previous:
        parts.append(f"Documents used in the previous answer: {json.dumps(previous)}")
    if history:
        parts.append(f"Recent conversation:\n{_history_block(history)}")
    parts.append(f"Current question: {question}")
    return "\n\n".join(parts)


_WORD = re.compile(r"\w{3,}")


def _words(text: str) -> set[str]:
    return {w.casefold() for w in _WORD.findall(text)}


def _prefilter(question: str, cards: list[DocCard], history: Sequence[Turn], previous: list[str]) -> list[DocCard]:
    """Bound the router prompt for large vaults: keep previous documents, then the best keyword matches.

    Cards are English and questions may not be, so with no overlap this falls back to the newest cards;
    a multilingual embedding search would replace it at scale.
    """
    if len(cards) <= MAX_ROUTER_CARDS:
        return cards
    query = _words(" ".join([question, *(t.question for t in history[-1:])]))

    def score(c: DocCard) -> int:
        s = c.summary
        text = " ".join([c.doc_type.replace("_", " "), s.title, s.holder or "", s.issuer or "", *s.key_facts, *s.topics])
        return len(query & _words(text))

    newest_first = list(reversed(cards))  # callers pass cards oldest first
    ranked = sorted(newest_first, key=lambda c: (c.document_id not in previous, -score(c)))
    return ranked[:MAX_ROUTER_CARDS]


def _answer_prompt(question: str, standalone: str, texts: dict[str, str], history: Sequence[Turn]) -> str:
    docs = "\n\n".join(f'<document id="{doc_id}">\n{text}\n</document>' for doc_id, text in texts.items())
    parts = [docs]
    if history:
        parts.append(f"Recent conversation (context only):\n{_history_block(history)}")
    if standalone != question:
        parts.append(f"Question as asked: {question}\nQuestion: {standalone}")
    else:
        parts.append(f"Question: {question}")
    return "\n\n".join(parts)
