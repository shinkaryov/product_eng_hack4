"""Tests run against a separate `<db>_test` database on the same Postgres.

The dev stack (API + worker in docker compose) keeps using the main database, so
its worker never sees test jobs and tests never touch dev data. This module runs
before any `vault.*` import, because vault.db builds its engine at import time.
"""

import os

from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url
from sqlalchemy.exc import OperationalError

from vault.config import Settings


def _prepare_test_database() -> None:
    main_url = make_url(os.environ.get("DATABASE_URL") or Settings().database_url)
    test_url = main_url.set(database=f"{main_url.database}_test")
    os.environ["DATABASE_URL"] = test_url.render_as_string(hide_password=False)

    try:
        admin = create_engine(main_url, isolation_level="AUTOCOMMIT")
        with admin.connect() as conn:
            exists = conn.execute(text("SELECT 1 FROM pg_database WHERE datname = :n"), {"n": test_url.database}).first()
            if not exists:
                conn.execute(text(f'CREATE DATABASE "{test_url.database}"'))
        admin.dispose()
    except OperationalError:
        return  # Postgres is down: integration tests skip themselves

    from alembic import command
    from alembic.config import Config

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    cfg = Config(os.path.join(root, "alembic.ini"))
    cfg.set_main_option("script_location", os.path.join(root, "migrations"))
    command.upgrade(cfg, "head")


_prepare_test_database()
