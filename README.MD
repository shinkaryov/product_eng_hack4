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

The Alembic revisions create the `vault` schema: accounts, family membership and grants, documents and processing jobs, extractions, summary cards, deadlines and reminders, and chat history. Revision `0004_ai_pipeline_alignment` aligns it with the Gemini pipeline (AI document types, summary cards instead of embeddings, `review_status`, event payloads) and drops the local OCR staging table.

The API contract is available at `http://localhost:8000/docs`. Run the two-user lifecycle test against a healthy Compose stack with `docker compose exec -T api python - < tests/integration/test_local_vault.py`.

Check the migration and tables with these commands.

```sh
docker compose logs migrate
docker compose exec db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT version_num FROM alembic_version;"'
docker compose exec db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "\\dt vault.*"'
```

Add future revisions under `migrations/versions/` and rerun `docker compose up -d --build` followed by `docker compose wait migrate`.

## Document processing

Gemini reads the uploaded file directly; there is no local OCR. The worker claims jobs with `FOR UPDATE SKIP LOCKED`, classifies the document (router model), blocks blacklisted types in code, extracts text, facts and a summary card (main model), drops facts whose quotes are not in the text, and publishes in one transaction only if it still holds the attempt token. Blocked documents keep no original file. Provider outages retry with backoff up to three attempts, then `FAILED`. Every step, including token usage, is written to `document_events`.

Documents expose two statuses: `processing_stage` (worker: `PENDING`, `PROCESSING`, `COMPLETED`, `FAILED`) and `review_status` (`UPLOADED` → `PROCESSING` → `REVIEW_REQUIRED` → `READY`, or `BLOCKED`, `FAILED`). Set `LLM_PROVIDER=fake` to run without a Gemini key.

Run tests with `uv run pytest`. Integration tests need the Compose Postgres. They create and migrate a separate `vault_test` database automatically, so the running stack and its data are not affected.

## Evals

`evals/cases.py` holds a labeled synthetic set: 28 documents (insurance, contracts, utilities, bank statements, tax forms, identity, vehicle, receipts, 5 blacklisted types, 4 image scans, a prompt-injection receipt, Czech and Ukrainian texts, documents without an expiration date) and 32 chat questions (3 of them not answerable from any document). `uv run python -m evals.run` runs the real pipeline against Gemini and writes [evals/results/latest.md](evals/results/latest.md) with metrics and every failure. `--reuse` reruns only the chat part on cached document results; `--rpm` paces calls for the free tier. `--set realistic` runs the photo set from [evals/realistic.py](evals/realistic.py) and writes `evals/results/realistic.md`: real receipt photos from the CORD v2 dataset (CC BY 4.0) plus phone-style photos generated with a Gemini image model (`python -m evals.generate_photos`, needs billing), each checked by a person before it counts.

Metrics: classification accuracy, blacklist recall and false blocks, exact expiration date (and dates invented where none exist), key fact recall, facts dropped by the quote verifier, identifier leaks in summary cards, prompt-injection resistance, router recall@3, answer accuracy, abstention on unanswerable questions, cost and latency per document and per question.

See [BACKEND_PLAN.md](BACKEND_PLAN.md) for the backend roadmap.
