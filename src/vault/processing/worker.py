"""Poll PostgreSQL for private file cleanup and local OCR work."""

import logging
import signal
import time

from sqlalchemy import text

from vault.config import get_settings
from vault.db import engine
from vault.processing.local import process_next_job

log = logging.getLogger("vault.worker")
_running = True


def _stop(*_: object) -> None:
    global _running
    _running = False


def main() -> None:
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s"
    )
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
