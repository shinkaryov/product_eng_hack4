"""Chat turns: route the question by summary cards, answer from the routed documents' text.

The model call runs outside any transaction. The turn is saved only if the session's
turn_version is unchanged (no concurrent turn) and the documents are still readable.
"""

import json
import logging
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field, ValidationError

from vault.ai.chat import DocCard, Turn, answer_question
from vault.ai.schemas import SummaryCard
from vault.documents import ACCESS, document
from vault.llm import LLMClient, LLMInvalidOutput, LLMUnavailable, get_llm_client
from vault.local_auth import DB, User, query, required
from vault.saved import Chat

log = logging.getLogger("vault.chat")
router = APIRouter(prefix="/v1")

HISTORY_TURNS = 3


def get_llm() -> LLMClient:
    return get_llm_client()


LLM = Annotated[LLMClient, Depends(get_llm)]


class Message(BaseModel):
    message: str = Field(min_length=1, max_length=4000, pattern=r"\S")


def _readable_documents(db, user, document_id: UUID | None) -> list:
    """Allowed, published documents the user can read (one document for a document-bound session)."""
    return query(
        db,
        """SELECT d.id, d.category, d.result_revision, s.card, e.facts
           FROM vault.documents d
           JOIN vault.document_summaries s ON s.document_id = d.id
           LEFT JOIN vault.document_extractions e ON e.document_id = d.id
           WHERE d.policy_outcome = 'ALLOWED' AND d.result_revision > 0 AND """ + ACCESS + """
             AND (CAST(:doc AS uuid) IS NULL OR d.id = :doc)
           ORDER BY d.created_at""",
        uid=user["id"],
        doc=document_id,
    ).all()


def _cards(rows) -> list[DocCard]:
    cards = []
    for r in rows:
        try:
            summary = SummaryCard.model_validate(r["card"])
        except ValidationError:
            continue  # card missing or from an older schema: not routable until reprocessed
        expires = (r["facts"] or {}).get("expires_on")
        cards.append(DocCard(str(r["id"]), (r["category"] or "other").lower(), expires, summary))
    return cards


@router.post("/chat", status_code=201)
def create_vault_chat(db: DB, user: User, body: Chat | None = None):
    """Chat session over all documents the user can read."""
    row = query(
        db,
        "INSERT INTO vault.chat_sessions(owner_id,document_id,title) VALUES (:uid,NULL,:title) RETURNING *",
        uid=user["id"],
        title=body.title if body else None,
    ).one()
    db.commit()
    return dict(row)


@router.get("/chat")
def list_vault_chats(db: DB, user: User):
    return query(
        db,
        "SELECT * FROM vault.chat_sessions WHERE owner_id=:uid AND document_id IS NULL ORDER BY updated_at DESC",
        uid=user["id"],
    ).all()


@router.post("/chat/{id}/messages", status_code=201)
def send_message(id: UUID, body: Message, db: DB, user: User, llm: LLM):
    session = required(
        query(db, "SELECT * FROM vault.chat_sessions WHERE id=:id AND owner_id=:uid", id=id, uid=user["id"]).first()
    )
    if session["document_id"] is not None:
        document(db, user, session["document_id"], published=True, lock_share=True)  # 404 / 409 if no longer readable
    rows = _readable_documents(db, user, session["document_id"])
    revisions = {str(r["id"]): r["result_revision"] for r in rows}
    cards = _cards(rows)
    history = list(
        reversed(
            query(
                db,
                """SELECT question, answer, answer_status, routed_document_ids FROM vault.chat_turns WHERE session_id=:id
                   ORDER BY turn_number DESC LIMIT :n""",
                id=id,
                n=HISTORY_TURNS,
            ).all()
        )
    )
    version = session["turn_version"]
    db.commit()  # no transaction is held during the model call
    if not cards:
        raise HTTPException(409, "No processed documents to chat about")

    def load_texts(ids: list[str]) -> dict[str, str]:
        found = query(
            db, "SELECT document_id, pages FROM vault.document_extractions WHERE document_id = ANY(CAST(:ids AS uuid[]))",
            ids=ids,
        ).all()
        db.commit()
        return {str(r["document_id"]): "\n\n".join(p.get("text", "") for p in r["pages"]) for r in found}

    try:
        result = answer_question(
            llm,
            body.message,
            cards,
            load_texts,
            history=[Turn(t["question"], t["answer"]) for t in history],
            # Follow-ups usually refer to what the last answer was based on.
            previous_document_ids=[str(i) for i in history[-1]["routed_document_ids"]] if history else [],
        )
    except LLMUnavailable:
        raise HTTPException(503, "AI provider unavailable, try again shortly")
    except LLMInvalidOutput:
        log.warning("chat session %s: invalid model output", id)
        raise HTTPException(503, "AI provider returned an invalid answer, try again")

    # Recheck access and result revisions before saving and releasing the answer.
    if session["document_id"] is not None:
        document(db, user, session["document_id"], published=True, lock_share=True)  # 404 if access was revoked
    still_readable = {str(r["id"]): r["result_revision"] for r in _readable_documents(db, user, session["document_id"])}
    if any(still_readable.get(doc_id) != revisions.get(doc_id) for doc_id in result.routed_document_ids):
        db.rollback()
        raise HTTPException(409, "Documents changed during the answer, ask again")
    bumped = query(
        db,
        """UPDATE vault.chat_sessions SET turn_version = turn_version + 1, updated_at = now()
           WHERE id = :id AND turn_version = :v RETURNING turn_version""",
        id=id,
        v=version,
    ).first()
    turn_number = bumped["turn_version"] if bumped else None
    if turn_number is None:
        db.rollback()
        raise HTTPException(409, "Another message is being answered in this session")
    turn = query(
        db,
        """INSERT INTO vault.chat_turns
               (session_id, turn_number, question, answer_status, answer, citations, source_revision, routed_document_ids)
           VALUES (:sid, :n, :q, :status, :answer, CAST(:citations AS jsonb), :rev, CAST(:routed AS uuid[]))
           RETURNING *""",
        sid=id,
        n=turn_number,
        q=body.message,
        status="ANSWERED" if result.found else "INSUFFICIENT_INFORMATION",
        answer=result.answer,
        citations=json.dumps([c.model_dump() for c in result.citations]),
        rev=still_readable.get(str(session["document_id"])) if session["document_id"] else None,
        routed=result.routed_document_ids,
    ).one()
    db.commit()
    return dict(
        turn,
        standalone_question=result.standalone_question,
        usage={"input_tokens": result.usage.input_tokens, "output_tokens": result.usage.output_tokens},
    )
