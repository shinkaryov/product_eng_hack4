"""Document processing job: claim (Postgres queue) -> Gemini reads the file (no transaction) -> publish.

Only the attempt that holds the current attempt_token may publish, so a stale or
expired worker cannot overwrite newer results.
"""

import json
import logging
import uuid
from dataclasses import dataclass
from pathlib import Path

from sqlalchemy import text
from sqlalchemy.orm import Session

from vault.ai.analyze import AnalysisResult, analyze_document
from vault.ai.schemas import DocType
from vault.config import get_settings
from vault.llm import LLMClient, LLMInvalidOutput, LLMUnavailable

log = logging.getLogger("vault.processing")

LEASE_SECONDS = 300
MAX_ATTEMPTS = 3
SCHEMA_VERSION = 1

_DEADLINE_KIND: dict[DocType, str] = {
    DocType.AUTO_INSURANCE: "INSURANCE_EXPIRATION",
    DocType.HOME_INSURANCE: "INSURANCE_EXPIRATION",
    DocType.HEALTH_INSURANCE: "INSURANCE_EXPIRATION",
    DocType.TRAVEL_INSURANCE: "INSURANCE_EXPIRATION",
    DocType.LIFE_INSURANCE: "INSURANCE_EXPIRATION",
    DocType.LEASE: "CONTRACT_EXPIRATION",
    DocType.UTILITY_CONTRACT: "CONTRACT_EXPIRATION",
    DocType.SUBSCRIPTION: "CONTRACT_EXPIRATION",
    DocType.UTILITY_BILL: "PAYMENT_DUE",
    DocType.WARRANTY: "WARRANTY_EXPIRATION",
}


def _file_path(storage_key: uuid.UUID) -> Path:
    return Path(get_settings().files_dir) / str(uuid.UUID(str(storage_key)))


@dataclass(frozen=True)
class ClaimedJob:
    document_id: uuid.UUID
    attempt_token: uuid.UUID
    attempts: int
    storage_key: uuid.UUID
    media_type: str


def claim_next_job(session: Session) -> ClaimedJob | None:
    """Claim one ready (or lease-expired) job and commit, so the LLM call runs outside any transaction."""
    token = uuid.uuid4()
    row = session.execute(
        text("""
            UPDATE vault.processing_jobs j
            SET status = 'PROCESSING', attempt_token = :token, attempts = j.attempts + 1,
                lease_expires_at = now() + make_interval(secs => :lease), started_at = now(),
                finished_at = NULL, error_code = NULL
            WHERE j.document_id = (
                SELECT document_id FROM vault.processing_jobs
                WHERE (status = 'PENDING' AND available_at <= now())
                   OR (status = 'PROCESSING' AND lease_expires_at < now())
                ORDER BY available_at
                FOR UPDATE SKIP LOCKED
                LIMIT 1
            )
            RETURNING j.document_id, j.attempts
        """),
        {"token": token, "lease": LEASE_SECONDS},
    ).first()
    if row is None:
        session.rollback()
        return None
    file = session.execute(
        text("SELECT storage_key, media_type FROM vault.document_files WHERE document_id = :id"),
        {"id": row.document_id},
    ).first()
    session.execute(
        text("UPDATE vault.documents SET review_status = 'PROCESSING', updated_at = now() WHERE id = :id"),
        {"id": row.document_id},
    )
    _event(session, row.document_id, "PROCESSING_STARTED", {"attempt": row.attempts})
    session.commit()
    if file is None:
        # Nothing to process (e.g. blocked earlier and file removed): finish without retries.
        with session.begin():
            if _owns_job(session, row.document_id, token):
                _finish_failed(session, row.document_id, "NO_FILE")
        return None
    return ClaimedJob(row.document_id, token, row.attempts, file.storage_key, file.media_type)


def run_job(session: Session, llm: LLMClient, job: ClaimedJob) -> None:
    """Analyze a claimed job and publish the outcome. Never raises for expected failures."""
    try:
        data = _file_path(job.storage_key).read_bytes()
        result = analyze_document(llm, data, job.media_type)
    except (LLMUnavailable, LLMInvalidOutput, OSError) as exc:
        log.warning("document %s attempt %s failed: %s", job.document_id, job.attempts, type(exc).__name__)
        _record_failure(session, job, type(exc).__name__)
        return
    except Exception:
        log.exception("document %s attempt %s crashed", job.document_id, job.attempts)
        _record_failure(session, job, "INTERNAL_ERROR")
        return

    publish_result(session, job, result)


def process_next_job(session: Session, llm: LLMClient) -> bool:
    job = claim_next_job(session)
    if job is None:
        return False
    run_job(session, llm, job)
    return True


def publish_result(session: Session, job: ClaimedJob, result: AnalysisResult) -> None:
    """Write the analysis in one transaction. Blocked files are unlinked later via file_cleanup_jobs."""
    with session.begin():
        if not _owns_job(session, job.document_id, job.attempt_token):
            log.info("document %s: attempt superseded, result discarded", job.document_id)
            return
        doc_type = result.classification.doc_type
        usage = {
            "input_tokens": result.usage.input_tokens,
            "output_tokens": result.usage.output_tokens,
            "calls": [{"model": u.model, "in": u.input_tokens, "out": u.output_tokens, "ms": u.latency_ms} for u in result.usage.calls],
        }

        if result.blocked:
            session.execute(
                text("""
                    UPDATE vault.documents
                    SET review_status = 'BLOCKED', category = :cat, classification_confidence = :conf,
                        policy_outcome = 'BLOCKED', policy_reason = :reason, updated_at = now()
                    WHERE id = :id
                """),
                {"id": job.document_id, "cat": doc_type.name, "conf": result.classification.confidence, "reason": result.blocked_reason},
            )
            # Blacklisted type: keep no copy of the original.
            session.execute(text("DELETE FROM vault.document_files WHERE document_id = :id"), {"id": job.document_id})
            session.execute(
                text("INSERT INTO vault.file_cleanup_jobs (storage_key) VALUES (:k) ON CONFLICT DO NOTHING"),
                {"k": job.storage_key},
            )
            _event(session, job.document_id, "BLOCKED", {"doc_type": doc_type.value, "usage": usage})
            _finish_completed(session, job.document_id)
            return

        extraction = result.extraction
        assert extraction is not None
        revision = session.execute(
            text("UPDATE vault.documents SET result_revision = result_revision + 1 WHERE id = :id RETURNING result_revision"),
            {"id": job.document_id},
        ).scalar_one()
        main_model = result.usage.calls[-1].model if result.usage.calls else "unknown"
        card = extraction.summary

        session.execute(
            text("""
                INSERT INTO vault.document_extractions
                    (document_id, revision, pages, facts, identifiers, terms, financials, model_id, schema_version)
                VALUES (:id, :rev, CAST(:pages AS jsonb), CAST(:facts AS jsonb), CAST(:ids AS jsonb),
                        CAST(:terms AS jsonb), CAST(:fin AS jsonb), :model, :schema)
                ON CONFLICT (document_id) DO UPDATE SET
                    revision = EXCLUDED.revision, pages = EXCLUDED.pages, facts = EXCLUDED.facts,
                    identifiers = EXCLUDED.identifiers, terms = EXCLUDED.terms, financials = EXCLUDED.financials,
                    model_id = EXCLUDED.model_id, schema_version = EXCLUDED.schema_version, published_at = now()
            """),
            {
                "id": job.document_id,
                "rev": revision,
                "pages": json.dumps([{"page": 1, "text": extraction.full_text, "method": "gemini"}]),
                "facts": json.dumps({
                    "doc_type": doc_type.value,
                    "classification_reason": result.classification.reason,
                    "expires_on": result.expires_on.isoformat() if result.expires_on else None,
                    "expires_on_quote": extraction.expires_on_quote if result.expires_on else None,
                    "warnings": result.warnings,
                    "needs_review": result.needs_review,
                }),
                "ids": json.dumps([f.model_dump() for f in extraction.identifiers]),
                "terms": json.dumps([f.model_dump() for f in extraction.terms]),
                "fin": json.dumps([m.model_dump() for m in extraction.financials]),
                "model": main_model,
                "schema": SCHEMA_VERSION,
            },
        )
        summary_text = card.title + ("\n" + "\n".join(card.key_facts) if card.key_facts else "")
        session.execute(
            text("""
                INSERT INTO vault.document_summaries (document_id, revision, summary, card, model_id, prompt_version)
                VALUES (:id, :rev, :summary, CAST(:card AS jsonb), :model, :pv)
                ON CONFLICT (document_id) DO UPDATE SET
                    revision = EXCLUDED.revision, summary = EXCLUDED.summary, card = EXCLUDED.card,
                    model_id = EXCLUDED.model_id, prompt_version = EXCLUDED.prompt_version, published_at = now()
            """),
            {"id": job.document_id, "rev": revision, "summary": summary_text, "card": card.model_dump_json(),
             "model": main_model, "pv": result.prompt_version},
        )

        if result.expires_on:
            kind = _DEADLINE_KIND.get(doc_type, "DOCUMENT_EXPIRATION")
            # Owner decisions (CONFIRMED / REJECTED) survive reprocessing.
            session.execute(
                text("""
                    INSERT INTO vault.document_deadlines (document_id, kind, due_on, raw_value, state, evidence, candidate_key)
                    VALUES (:id, :kind, :due, :raw, 'PROPOSED', CAST(:ev AS jsonb), 'expires_on')
                    ON CONFLICT (document_id, candidate_key) DO UPDATE SET
                        kind = EXCLUDED.kind, due_on = EXCLUDED.due_on, raw_value = EXCLUDED.raw_value, evidence = EXCLUDED.evidence
                    WHERE vault.document_deadlines.state = 'PROPOSED'
                """),
                {"id": job.document_id, "kind": kind, "due": result.expires_on, "raw": extraction.expires_on,
                 "ev": json.dumps({"quote": extraction.expires_on_quote})},
            )
        else:
            session.execute(
                text("DELETE FROM vault.document_deadlines WHERE document_id = :id AND candidate_key = 'expires_on' AND state = 'PROPOSED'"),
                {"id": job.document_id},
            )

        # No document becomes READY without the owner's confirmation (PRD FR-02).
        # Replace the auto title (= filename) with the AI title; keep titles the user typed.
        session.execute(
            text("""
                UPDATE vault.documents d
                SET review_status = 'REVIEW_REQUIRED', category = :cat, classification_confidence = :conf,
                    policy_outcome = :outcome, policy_reason = NULL, updated_at = now(),
                    title = CASE WHEN d.title = f.display_filename THEN :ai_title ELSE d.title END
                FROM vault.document_files f
                WHERE d.id = :id AND f.document_id = d.id
            """),
            {"id": job.document_id, "cat": doc_type.name, "conf": result.classification.confidence,
             "outcome": "ALLOWED", "ai_title": card.title[:200] or "Document"},
        )
        _event(session, job.document_id, "ANALYZED", {
            "doc_type": doc_type.value, "needs_review": result.needs_review, "warnings": result.warnings, "usage": usage,
        })
        _finish_completed(session, job.document_id)
    return


def _record_failure(session: Session, job: ClaimedJob, error_code: str) -> None:
    with session.begin():
        if not _owns_job(session, job.document_id, job.attempt_token):
            return
        _event(session, job.document_id, "PROCESSING_FAILED", {"attempt": job.attempts, "error": error_code})
        if job.attempts >= MAX_ATTEMPTS:
            _finish_failed(session, job.document_id, error_code)
            return
        backoff = 15 * 2 ** (job.attempts - 1)
        session.execute(
            text("""
                UPDATE vault.processing_jobs
                SET status = 'PENDING', attempt_token = NULL, lease_expires_at = NULL,
                    available_at = now() + make_interval(secs => :backoff), error_code = :err
                WHERE document_id = :id
            """),
            {"id": job.document_id, "backoff": backoff, "err": error_code},
        )
        session.execute(
            text("UPDATE vault.documents SET review_status = 'UPLOADED', updated_at = now() WHERE id = :id"), {"id": job.document_id}
        )


def _owns_job(session: Session, document_id: uuid.UUID, token: uuid.UUID) -> bool:
    return session.execute(
        text("""
            SELECT 1 FROM vault.processing_jobs
            WHERE document_id = :id AND status = 'PROCESSING' AND attempt_token = :token
            FOR UPDATE
        """),
        {"id": document_id, "token": token},
    ).first() is not None


def _finish_completed(session: Session, document_id: uuid.UUID) -> None:
    session.execute(
        text("""
            UPDATE vault.processing_jobs
            SET status = 'COMPLETED', attempt_token = NULL, lease_expires_at = NULL, finished_at = now(), error_code = NULL
            WHERE document_id = :id
        """),
        {"id": document_id},
    )


def _finish_failed(session: Session, document_id: uuid.UUID, error_code: str) -> None:
    session.execute(
        text("""
            UPDATE vault.processing_jobs
            SET status = 'FAILED', attempt_token = NULL, lease_expires_at = NULL, finished_at = now(), error_code = :err
            WHERE document_id = :id
        """),
        {"id": document_id, "err": error_code},
    )
    session.execute(text("UPDATE vault.documents SET review_status = 'FAILED', updated_at = now() WHERE id = :id"), {"id": document_id})


def _event(session: Session, document_id: uuid.UUID, name: str, payload: dict) -> None:
    session.execute(
        text("INSERT INTO vault.document_events (document_id, event_name, payload) VALUES (:id, :name, CAST(:p AS jsonb))"),
        {"id": document_id, "name": name, "p": json.dumps(payload)},
    )


def cleanup_files(session: Session, limit: int = 20) -> int:
    """Unlink files queued in file_cleanup_jobs (replaced, deleted or blocked documents)."""
    with session.begin():
        keys = session.execute(
            text("""
                SELECT storage_key FROM vault.file_cleanup_jobs
                WHERE retry_at <= now() ORDER BY retry_at FOR UPDATE SKIP LOCKED LIMIT :limit
            """),
            {"limit": limit},
        ).scalars().all()
        for key in keys:
            try:
                _file_path(key).unlink(missing_ok=True)
            except OSError:
                session.execute(
                    text("""UPDATE vault.file_cleanup_jobs SET attempts = attempts + 1,
                            retry_at = now() + interval '5 minutes' WHERE storage_key = :k"""),
                    {"k": key},
                )
                continue
            session.execute(text("DELETE FROM vault.file_cleanup_jobs WHERE storage_key = :k"), {"k": key})
    return len(keys)
