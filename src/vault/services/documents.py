"""Document use cases that span several tables. Each function runs inside the caller's transaction."""

import uuid
from dataclasses import dataclass

from sqlalchemy import text
from sqlalchemy.orm import Session


class DocumentNotFound(Exception):
    """Missing, or not owned by the caller (API maps to 404)."""


class DocumentBusy(Exception):
    """Processing is running; replacing now would race the worker (API maps to 409)."""


@dataclass(frozen=True)
class NewFile:
    storage_key: uuid.UUID
    display_filename: str
    media_type: str
    size_bytes: int
    sha256: str


def replace_document_file(session: Session, *, document_id: uuid.UUID, owner_id: uuid.UUID, new_file: NewFile) -> uuid.UUID:
    """Replace the original file of an owned document (PRD FR-11).

    The new file must already be written to storage under `new_file.storage_key`.
    Effects, all in one transaction:
    - document_files points to the new file; the old file is queued in file_cleanup_jobs;
    - stale derived data (extraction, summary) is removed so chat and search cannot use the old content;
    - proposed deadlines are deleted; confirmed ones go back to PROPOSED and their reminders are cancelled,
      so the owner has to reconsider them;
    - the document goes back to UPLOADED (needs processing and review again), revision is bumped;
    - a processing job is queued and a REPLACED event is recorded.
    No version history is kept. Returns the old storage key.
    """
    doc = session.execute(
        text("SELECT id FROM vault.documents WHERE id = :id AND owner_id = :owner FOR UPDATE"),
        {"id": document_id, "owner": owner_id},
    ).first()
    if doc is None:
        raise DocumentNotFound(document_id)

    job_status = session.execute(
        text("SELECT status FROM vault.processing_jobs WHERE document_id = :id FOR UPDATE"),
        {"id": document_id},
    ).scalar()
    if job_status == "PROCESSING":
        raise DocumentBusy(document_id)

    old = session.execute(
        text("SELECT storage_key, sha256 FROM vault.document_files WHERE document_id = :id"),
        {"id": document_id},
    ).first()

    params = {"id": document_id, **new_file.__dict__}
    if old is None:
        session.execute(
            text("""
                INSERT INTO vault.document_files (document_id, storage_key, display_filename, media_type, size_bytes, sha256)
                VALUES (:id, :storage_key, :display_filename, :media_type, :size_bytes, :sha256)
            """),
            params,
        )
    else:
        session.execute(
            text("""
                UPDATE vault.document_files
                SET storage_key = :storage_key, display_filename = :display_filename,
                    media_type = :media_type, size_bytes = :size_bytes, sha256 = :sha256
                WHERE document_id = :id
            """),
            params,
        )
        session.execute(
            text("INSERT INTO vault.file_cleanup_jobs (storage_key) VALUES (:key) ON CONFLICT DO NOTHING"),
            {"key": old.storage_key},
        )

    session.execute(text("DELETE FROM vault.document_extractions WHERE document_id = :id"), {"id": document_id})
    session.execute(text("DELETE FROM vault.document_summaries WHERE document_id = :id"), {"id": document_id})

    session.execute(
        text("DELETE FROM vault.document_deadlines WHERE document_id = :id AND state = 'PROPOSED'"), {"id": document_id}
    )
    session.execute(
        text("""
            UPDATE vault.reminders r SET cancelled_at = now()
            FROM vault.document_deadlines d
            WHERE r.deadline_id = d.id AND d.document_id = :id AND r.cancelled_at IS NULL
        """),
        {"id": document_id},
    )
    session.execute(
        text("UPDATE vault.document_deadlines SET state = 'PROPOSED' WHERE document_id = :id AND state = 'CONFIRMED'"),
        {"id": document_id},
    )

    session.execute(
        text("""
            UPDATE vault.documents
            SET review_status = 'UPLOADED', confirmed_at = NULL, policy_outcome = NULL, policy_reason = NULL,
                classification_confidence = NULL, result_revision = result_revision + 1,
                replaced_at = now(), updated_at = now()
            WHERE id = :id
        """),
        {"id": document_id},
    )
    session.execute(
        text("""
            INSERT INTO vault.processing_jobs (document_id) VALUES (:id)
            ON CONFLICT (document_id) DO UPDATE
            SET status = 'PENDING', available_at = now(), attempts = 0, attempt_token = NULL,
                lease_expires_at = NULL, started_at = NULL, finished_at = NULL, error_code = NULL
        """),
        {"id": document_id},
    )
    session.execute(
        text("""
            INSERT INTO vault.document_events (document_id, event_name, payload)
            VALUES (:id, 'REPLACED', jsonb_build_object('old_sha256', CAST(:old_sha AS text), 'new_sha256', CAST(:new_sha AS text)))
        """),
        {"id": document_id, "old_sha": old.sha256 if old else None, "new_sha": new_file.sha256},
    )
    return old.storage_key if old else None
