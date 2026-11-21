# Document Vault

## Local startup

Copy the sample environment file and set a URL-safe local `POSTGRES_PASSWORD` in `.env`.

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

The initial Alembic revisions enable pgvector and create the `vault` schema. It contains accounts, family membership and grants, documents and processing jobs, summaries, deadlines and reminders, and document chatbot history. The database migration provides storage and constraints. The worker and API skeletons still need their application behavior.

Check the migration and tables with these commands.

```sh
docker compose logs migrate
docker compose exec db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT version_num FROM alembic_version;"'
docker compose exec db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "\\dt vault.*"'
```

Add future revisions under `migrations/versions/` and rerun `docker compose up -d --build` followed by `docker compose wait migrate`.

See [BACKEND_PLAN.md](BACKEND_PLAN.md) for the backend roadmap.
