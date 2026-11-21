# Document Vault

## Local startup

Copy the sample environment file and set a URL-safe local `POSTGRES_PASSWORD` and a random `JWT_SECRET` of at least 32 bytes in `.env`.

```sh
cp .env.example .env
```

Start PostgreSQL, apply migrations, then start the API and worker.

```sh
docker compose up -d --build
```

The `migrate` service waits for PostgreSQL to accept TCP connections, runs `alembic upgrade head`, and exits. The API and worker start after that service succeeds. PostgreSQL persists data in a named volume and exposes port 5432 on loopback. The API listens on `http://localhost:8000`.

To start only PostgreSQL and its migration service, run `docker compose up -d --build migrate` and then `docker compose wait migrate`.

## Database schema

The initial Alembic revisions enable pgvector and create the `vault` schema. It contains accounts, family membership and grants, documents and processing jobs, summaries, deadlines and reminders, and document chatbot history. Revision `0003_local_ocr` adds private staging for locally extracted pages. The worker runs English and Czech Tesseract OCR when embedded text is insufficient. After OCR, a document reports `processing_stage=AWAITING_SCREENING` until the AI integration publishes a result. Published summaries and extractions can be read through the API with Gemini offline.

The API contract is available at `http://localhost:8000/docs`. Run the two-user local integration test against a healthy Compose stack with `docker compose exec -T api python - < tests/integration/test_local_vault.py`.

Check the migration and tables with these commands.

```sh
docker compose logs migrate
docker compose exec db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT version_num FROM alembic_version;"'
docker compose exec db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "\\dt vault.*"'
```

Add future revisions under `migrations/versions/` and rerun `docker compose up -d --build` followed by `docker compose wait migrate`.

See [BACKEND_PLAN.md](BACKEND_PLAN.md) for the backend roadmap.
