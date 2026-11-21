from datetime import UTC, date, datetime, time, timedelta
from typing import Literal
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from vault.documents import document
from vault.local_auth import DB, User, query, required

router = APIRouter(prefix="/v1")
Kind = Literal[
    "CONTRACT_EXPIRATION",
    "CANCELLATION",
    "INSURANCE_EXPIRATION",
    "WARRANTY_EXPIRATION",
    "PAYMENT_DUE",
    "DOCUMENT_EXPIRATION",
    "OTHER",
]
State = Literal["PROPOSED", "CONFIRMED", "REJECTED"]


class DeadlineCreate(BaseModel):
    type: Kind
    date: date
    label: str | None = None


class DeadlinePatch(BaseModel):
    due_on: date | None = Field(None, alias="date")
    label: str | None = None
    state: State | None = None


def schedule(db, user, deadline):
    query(
        db,
        "UPDATE vault.reminders SET cancelled_at=now() WHERE deadline_id=:id AND cancelled_at IS NULL",
        id=deadline["id"],
    )
    zone = ZoneInfo(user["timezone"])
    now = datetime.now(UTC)
    if (
        deadline["state"] != "CONFIRMED"
        or deadline["due_on"] < now.astimezone(zone).date()
    ):
        return
    times = []
    for days in (7, 1):
        dt = datetime.combine(deadline["due_on"] - timedelta(days=days), time(9), zone)
        if dt >= now:
            times.append((days, dt))
    for days, dt in times or [(0, now)]:
        query(
            db,
            """INSERT INTO vault.reminders(deadline_id,recipient_id,offset_days,scheduled_at)
                    VALUES (:id,:uid,:days,:dt) ON CONFLICT(deadline_id,offset_days,scheduled_at)
                    DO UPDATE SET cancelled_at=NULL""",
            id=deadline["id"],
            uid=user["id"],
            days=days,
            dt=dt,
        )


@router.get("/deadlines")
def deadline_timeline(db: DB, user: User):
    return query(
        db,
        """SELECT d.*, doc.title AS document_title
           FROM vault.document_deadlines d JOIN vault.documents doc ON doc.id=d.document_id
           WHERE doc.owner_id=:uid AND doc.policy_outcome='ALLOWED' AND doc.result_revision>0
             AND d.state='CONFIRMED' ORDER BY d.due_on,d.id""",
        uid=user["id"],
    ).all()


@router.get("/documents/{id}/deadlines")
def deadlines(id: UUID, db: DB, user: User, state: State | None = None):
    document(db, user, id, published=True)
    return query(
        db,
        "SELECT * FROM vault.document_deadlines WHERE document_id=:id AND state=coalesce(:state,state) ORDER BY due_on",
        id=id,
        state=state,
    ).all()


@router.post("/documents/{id}/deadlines", status_code=201)
def add(id: UUID, body: DeadlineCreate, db: DB, user: User):
    document(db, user, id, owner=True, published=True)
    row = query(
        db,
        """INSERT INTO vault.document_deadlines(document_id,kind,due_on,label,state)
                    VALUES (:id,:type,:date,:label,'CONFIRMED') RETURNING *""",
        id=id,
        **body.model_dump(),
    ).one()
    schedule(db, user, row)
    db.commit()
    return dict(row)


@router.patch("/documents/{id}/deadlines/{deadline_id}")
def update(id: UUID, deadline_id: UUID, body: DeadlinePatch, db: DB, user: User):
    document(db, user, id, owner=True, published=True)
    old = required(
        query(
            db,
            "SELECT * FROM vault.document_deadlines WHERE document_id=:id AND id=:did",
            id=id,
            did=deadline_id,
        ).first()
    )
    if (body.state or old["state"]) == "CONFIRMED" and not (
        body.due_on or old["due_on"]
    ):
        raise HTTPException(422, "A confirmed deadline needs a date")
    row = query(
        db,
        """UPDATE vault.document_deadlines SET due_on=coalesce(:due_on,due_on),label=coalesce(:label,label),
                    state=coalesce(:state,state) WHERE id=:did RETURNING *""",
        did=deadline_id,
        **body.model_dump(),
    ).one()
    if (row["due_on"], row["state"]) != (old["due_on"], old["state"]):
        schedule(db, user, row)
    db.commit()
    return dict(row)


REMINDERS = """SELECT r.*,d.document_id,CASE WHEN dismissed_at IS NOT NULL THEN 'DISMISSED'
    WHEN scheduled_at<=now() THEN 'DUE' ELSE 'SCHEDULED' END AS status FROM vault.reminders r
    JOIN vault.document_deadlines d ON d.id=r.deadline_id JOIN vault.documents doc ON doc.id=d.document_id
    WHERE r.recipient_id=:uid AND doc.owner_id=:uid AND doc.policy_outcome='ALLOWED'
    AND d.state='CONFIRMED' AND r.cancelled_at IS NULL"""


@router.get("/reminders")
def reminders(
    db: DB,
    user: User,
    state: Literal["SCHEDULED", "DUE", "DISMISSED"] | None = None,
    through: datetime | None = None,
):
    sql = (
        "SELECT * FROM (" + REMINDERS + ") visible WHERE status=coalesce(:state,status)"
    )
    if through:
        sql += " AND scheduled_at<=:through"
    return query(
        db,
        sql + " ORDER BY scheduled_at,id",
        uid=user["id"],
        state=state,
        through=through,
    ).all()


@router.post("/reminders/{id}/dismiss")
def dismiss(id: UUID, db: DB, user: User):
    row = required(
        query(
            db, REMINDERS + " AND r.id=:id FOR UPDATE OF r", uid=user["id"], id=id
        ).first()
    )
    updated = query(
        db,
        "UPDATE vault.reminders SET dismissed_at=coalesce(dismissed_at,now()) WHERE id=:id RETURNING dismissed_at",
        id=id,
    ).one()
    db.commit()
    return {**row, **updated, "status": "DISMISSED"}


class Chat(BaseModel):
    title: str | None = Field(None, max_length=255)


@router.post("/documents/{id}/chat", status_code=201)
def create_chat(id: UUID, db: DB, user: User, body: Chat | None = None):
    document(db, user, id, published=True)
    row = query(
        db,
        "INSERT INTO vault.chat_sessions(owner_id,document_id,title) VALUES (:uid,:id,:title) RETURNING *",
        uid=user["id"],
        id=id,
        title=body.title if body else None,
    ).one()
    db.commit()
    return dict(row)


@router.get("/documents/{id}/chat")
def chats(id: UUID, db: DB, user: User):
    document(db, user, id, published=True)
    return query(
        db,
        "SELECT * FROM vault.chat_sessions WHERE owner_id=:uid AND document_id=:id ORDER BY updated_at DESC",
        uid=user["id"],
        id=id,
    ).all()


def chat_session(db, user, id, *, lock=False):
    return required(
        query(
            db,
            "SELECT * FROM vault.chat_sessions WHERE id=:id AND owner_id=:uid" + (" FOR UPDATE" if lock else ""),
            id=id,
            uid=user["id"],
        ).first()
    )


@router.get("/chat/{id}")
def history(id: UUID, db: DB, user: User):
    row = chat_session(db, user, id)
    if row["document_id"] is not None:  # null = session over all readable documents
        document(db, user, row["document_id"], published=True, lock_share=True)
    return dict(
        row,
        turns=query(
            db,
            "SELECT * FROM vault.chat_turns WHERE session_id=:id ORDER BY turn_number",
            id=id,
        ).all(),
    )


@router.delete("/chat/{id}", status_code=204)
def delete_chat(id: UUID, db: DB, user: User):
    required(
        query(
            db,
            "DELETE FROM vault.chat_sessions WHERE id=:id AND owner_id=:uid RETURNING id",
            id=id,
            uid=user["id"],
        ).first()
    )
    db.commit()
