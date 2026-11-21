"""Document processing worker.

Postgres is the queue: jobs are claimed with FOR UPDATE SKIP LOCKED. Gemini reads
the original file (no local OCR), and every step writes a row to document_events
(PROCESSING_STARTED, ANALYZED, BLOCKED, PROCESSING_FAILED). The same loop unlinks
files queued in file_cleanup_jobs. Job logic lives in vault.services.processing.
"""

import logging
import signal
import time

from sqlalchemy import text

from vault.config import get_settings
from vault.db import SessionLocal, engine
from vault.llm import get_llm_client
from vault.services.processing import cleanup_files, process_next_job

log = logging.getLogger("vault.worker")
_running = True


def _stop(*_: object) -> None:
    global _running
    _running = False


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)
    settings = get_settings()
    llm = get_llm_client()

    with engine.connect() as conn:
        conn.execute(text("SELECT 1"))
    log.info("worker started, provider=%s poll=%ss", llm.provider, settings.worker_poll_seconds)

    while _running:
        handled = False
        try:
            with SessionLocal() as session:
                handled = process_next_job(session, llm)
                cleanup_files(session)
        except Exception:
            log.exception("worker iteration failed")
        if not handled:
            time.sleep(settings.worker_poll_seconds)
    log.info("worker stopped")


if __name__ == "__main__":
    main()
