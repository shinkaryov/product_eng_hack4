"""Document processing worker.

Postgres is the queue: jobs are claimed with FOR UPDATE SKIP LOCKED, and every
step writes a row to document_events (UPLOADED, OCR_DONE, EXTRACTED, FAILED...).
The claim/process logic lands together with the schema migration.
"""

import logging
import signal
import time

from sqlalchemy import text

from vault.config import get_settings
from vault.db import engine

log = logging.getLogger("vault.worker")
_running = True


def _stop(*_: object) -> None:
    global _running
    _running = False


def process_next_job() -> bool:
    """Claim and process one job. Returns True if a job was handled."""
    # TODO: claim from processing_jobs once the schema migration exists
    return False


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)
    settings = get_settings()

    with engine.connect() as conn:
        conn.execute(text("SELECT 1"))
    log.info("worker started, poll=%ss", settings.worker_poll_seconds)

    while _running:
        try:
            handled = process_next_job()
        except Exception:
            log.exception("job failed")
            handled = False
        if not handled:
            time.sleep(settings.worker_poll_seconds)
    log.info("worker stopped")


if __name__ == "__main__":
    main()
