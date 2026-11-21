"""Runs against the test database on the compose Postgres (see tests/conftest.py)."""

import hashlib
import uuid

import pytest
from sqlalchemy import text
from sqlalchemy.exc import OperationalError

from vault.db import engine
from vault.services.documents import DocumentBusy, DocumentNotFound, NewFile, replace_document_file


@pytest.fixture
def session():
    try:
        conn = engine.connect()
    except OperationalError:
        pytest.skip("Postgres is not running")
    tx = conn.begin()
    from sqlalchemy.orm import Session

    s = Session(bind=conn)
    yield s
    s.close()
    tx.rollback()
    conn.close()


def _file(content: bytes) -> NewFile:
    return NewFile(uuid.uuid4(), "lease.pdf", "application/pdf", len(content), hashlib.sha256(content).hexdigest())


def _seed(s) -> tuple[uuid.UUID, uuid.UUID, NewFile]:
    owner = s.execute(text("INSERT INTO vault.users (email, password_hash) VALUES (:e, 'x') RETURNING id"),
                      {"e": f"{uuid.uuid4().hex}@test.dev"}).scalar()
    doc = s.execute(text("""
        INSERT INTO vault.documents (owner_id, title, category, review_status, confirmed_at, policy_outcome)
        VALUES (:o, 'Lease', 'LEASE', 'READY', now(), 'ALLOWED') RETURNING id"""), {"o": owner}).scalar()
    old = _file(b"old")
    s.execute(text("""INSERT INTO vault.document_files VALUES (:d, :k, :n, :m, :sz, :h)"""),
              {"d": doc, "k": old.storage_key, "n": old.display_filename, "m": old.media_type, "sz": old.size_bytes, "h": old.sha256})
    s.execute(text("""INSERT INTO vault.processing_jobs (document_id, status) VALUES (:d, 'COMPLETED')"""), {"d": doc})
    s.execute(text("""INSERT INTO vault.document_extractions (document_id, revision, pages, facts, model_id, schema_version)
                      VALUES (:d, 1, '[]', '{}', 'm', 1)"""), {"d": doc})
    confirmed = s.execute(text("""INSERT INTO vault.document_deadlines (document_id, kind, due_on, state, candidate_key)
                      VALUES (:d, 'CONTRACT_EXPIRATION', '2026-10-31', 'CONFIRMED', 'a') RETURNING id"""), {"d": doc}).scalar()
    s.execute(text("""INSERT INTO vault.document_deadlines (document_id, kind, due_on, state, candidate_key)
                      VALUES (:d, 'PAYMENT_DUE', '2026-10-01', 'PROPOSED', 'b')"""), {"d": doc})
    s.execute(text("""INSERT INTO vault.reminders (deadline_id, recipient_id, scheduled_at, offset_days)
                      VALUES (:dl, :o, now(), 7)"""), {"dl": confirmed, "o": owner})
    return owner, doc, old


def test_replace_resets_document_and_derived_data(session):
    owner, doc, old = _seed(session)
    new = _file(b"new")

    old_key = replace_document_file(session, document_id=doc, owner_id=owner, new_file=new)

    assert old_key == old.storage_key
    q = lambda sql: session.execute(text(sql), {"d": doc}).all()  # noqa: E731
    assert q("SELECT review_status, confirmed_at IS NULL, replaced_at IS NOT NULL, result_revision FROM vault.documents WHERE id = :d") == [("UPLOADED", True, True, 1)]
    assert q("SELECT storage_key FROM vault.document_files WHERE document_id = :d") == [(new.storage_key,)]
    assert session.execute(text("SELECT count(*) FROM vault.file_cleanup_jobs WHERE storage_key = :k"), {"k": old.storage_key}).scalar() == 1
    assert q("SELECT count(*) FROM vault.document_extractions WHERE document_id = :d") == [(0,)]
    assert q("SELECT kind, state FROM vault.document_deadlines WHERE document_id = :d") == [("CONTRACT_EXPIRATION", "PROPOSED")]
    assert q("""SELECT count(*) FROM vault.reminders r JOIN vault.document_deadlines dl ON dl.id = r.deadline_id
                WHERE dl.document_id = :d AND r.cancelled_at IS NULL""") == [(0,)]
    assert q("SELECT status, attempts FROM vault.processing_jobs WHERE document_id = :d") == [("PENDING", 0)]
    assert q("SELECT event_name, payload->>'new_sha256' FROM vault.document_events WHERE document_id = :d") == [("REPLACED", new.sha256)]


def test_replace_requires_owner(session):
    _, doc, _ = _seed(session)
    with pytest.raises(DocumentNotFound):
        replace_document_file(session, document_id=doc, owner_id=uuid.uuid4(), new_file=_file(b"x"))


def test_replace_rejected_while_processing(session):
    owner, doc, _ = _seed(session)
    session.execute(text("""UPDATE vault.processing_jobs SET status = 'PROCESSING', attempt_token = gen_random_uuid(),
                            lease_expires_at = now() + interval '1 minute' WHERE document_id = :d"""), {"d": doc})
    with pytest.raises(DocumentBusy):
        replace_document_file(session, document_id=doc, owner_id=owner, new_file=_file(b"x"))
