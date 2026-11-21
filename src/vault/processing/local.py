import json
import subprocess
import unicodedata
from pathlib import Path
from uuid import uuid4

import pymupdf
from sqlalchemy import text

from vault.config import get_settings
from vault.db import engine


def read_pages(path, language, heartbeat):
    pages = []
    with pymupdf.open(path) as source:
        for number, page in enumerate(source, 1):
            heartbeat()
            content = page.get_text().strip()
            method = "embedded"
            if len(content) < 20:
                pixmap = page.get_pixmap(matrix=pymupdf.Matrix(2, 2), alpha=False)
                result = subprocess.run(
                    ["tesseract", "stdin", "stdout", "-l", language or "eng+ces"],
                    input=pixmap.tobytes("png"),
                    capture_output=True,
                    check=True,
                    timeout=60,
                )
                recognized = result.stdout.decode().strip()
                if recognized:
                    content = recognized
                    method = "ocr"
            pages.append(
                {
                    "page": number,
                    "text": unicodedata.normalize("NFC", content),
                    "method": method,
                }
            )
    return pages


def process_next_job():
    token = uuid4()
    with engine.begin() as db:
        cleanup = db.execute(
            text("""SELECT storage_key FROM vault.file_cleanup_jobs WHERE retry_at<=now()
                                   ORDER BY retry_at LIMIT 1 FOR UPDATE SKIP LOCKED""")
        ).scalar()
        if cleanup:
            try:
                (Path(get_settings().files_dir) / str(cleanup)).unlink(missing_ok=True)
            except OSError:
                db.execute(
                    text("""UPDATE vault.file_cleanup_jobs SET attempts=attempts+1,retry_at=now()+interval '1 minute'
                                   WHERE storage_key=:key"""),
                    {"key": cleanup},
                )
            else:
                db.execute(
                    text("DELETE FROM vault.file_cleanup_jobs WHERE storage_key=:key"),
                    {"key": cleanup},
                )
            return True
        job = (
            db.execute(
                text("""SELECT j.document_id,f.storage_key,d.language_hint FROM vault.processing_jobs j
            JOIN vault.document_files f USING(document_id) JOIN vault.documents d ON d.id=j.document_id
            WHERE ((status='PENDING' AND available_at<=now()) OR (status='PROCESSING' AND lease_expires_at<=now()))
            AND NOT EXISTS (SELECT 1 FROM vault.document_ocr o WHERE o.document_id=j.document_id)
            ORDER BY available_at LIMIT 1 FOR UPDATE OF j SKIP LOCKED""")
            )
            .mappings()
            .first()
        )
        if not job:
            return False
        params = {"id": job["document_id"], "token": token}
        db.execute(
            text("""UPDATE vault.processing_jobs SET status='PROCESSING',attempt_token=:token,
            lease_expires_at=now()+interval '3 minutes',attempts=attempts+1,started_at=now() WHERE document_id=:id"""),
            params,
        )

    def renew():
        with engine.begin() as db:
            if not db.execute(
                text("""UPDATE vault.processing_jobs SET lease_expires_at=now()+interval '3 minutes'
                                      WHERE document_id=:id AND attempt_token=:token"""),
                params,
            ).rowcount:
                raise RuntimeError("Claim expired")

    try:
        pages = read_pages(
            Path(get_settings().files_dir) / str(job["storage_key"]),
            job["language_hint"],
            renew,
        )
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError):
        with engine.begin() as db:
            db.execute(
                text("""UPDATE vault.processing_jobs SET status=CASE WHEN attempts>=3 THEN 'FAILED' ELSE 'PENDING' END,
                error_code='OCR_FAILED',attempt_token=NULL,lease_expires_at=NULL,finished_at=now(),
                available_at=now()+interval '30 seconds' WHERE document_id=:id AND attempt_token=:token"""),
                params,
            )
        return True
    with engine.begin() as db:
        if db.execute(
            text("""UPDATE vault.processing_jobs SET status='PENDING',attempt_token=NULL,
                lease_expires_at=NULL,error_code=NULL WHERE document_id=:id AND attempt_token=:token"""),
            params,
        ).rowcount:
            db.execute(
                text(
                    "INSERT INTO vault.document_ocr(document_id,pages) VALUES (:id,cast(:pages AS jsonb))"
                ),
                {"id": job["document_id"], "pages": json.dumps(pages)},
            )
            db.execute(
                text(
                    "INSERT INTO vault.document_events(document_id,event_name) VALUES (:id,'OCR_DONE')"
                ),
                params,
            )
    return True
