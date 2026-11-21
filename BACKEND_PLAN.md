# Backend MVP design

Use one FastAPI application, one asynchronous document worker from the same Python package, PostgreSQL, and a private filesystem volume. The Gemini Developer API reads each uploaded file directly: it classifies the document type, extracts text and facts, and writes a structured summary card. There is no local OCR and no embedding search. Chat routes a question to documents by their summary cards with a cheap model, then answers from the full text of the selected documents with the main model. PostgreSQL also serves as the job queue.

## A. Current state (2026-11-21)

Branch `back`. Implemented: Compose stack (API, worker, migrations, Postgres), schema migrations `0001`–`0004`, local accounts with JWT and refresh tokens, families and invitations, explicit sharing, document upload/list/get/patch/delete/download/reprocess, extraction read and owner corrections, deadlines and reminders, chat session records, the provider-agnostic LLM layer with a Gemini adapter and a fake client, and the worker's Gemini pipeline (classify → policy → extract → publish). Also implemented: chat messages (card routing + grounded answers) and the eval suite in `evals/`. Not yet implemented: owner confirmation endpoint (`REVIEW_REQUIRED` → `READY`).

## B. Proposed architecture

### Local runtime

| Component | Responsibility |
|---|---|
| `api` | FastAPI REST endpoints, Pydantic schemas, authentication, authorization, and private downloads. Use SQLAlchemy 2.x with psycopg and explicit transaction boundaries. |
| `worker` | Single polling process from the same image. Sends the original file to Gemini for type screening and extraction, applies the policy in code, publishes results, retries provider failures, and unlinks files queued for cleanup. |
| `db` | PostgreSQL for relational data and job state. Alembic migrations run before the API and worker start. The pgvector extension from `0001` is unused since embeddings were dropped. |
| Gemini Developer API | External HTTPS dependency behind `vault.llm` (swappable provider). Two logical roles: `ROUTER` (cheap: classification, chat routing) and `MAIN` (extraction, chat answers), both `gemini-3.5-flash-lite` by default via `GEMINI_ROUTER_MODEL` and `GEMINI_MODEL`. All calls use structured JSON output validated with Pydantic. [Gemini structured outputs](https://aistudio.google.com/docs/structured-output), [Gemini pricing](https://aistudio.google.com/docs/pricing) |
| Volumes | Persistent volumes for PostgreSQL and original files. The API and worker share the private document volume. |

Publish the API and PostgreSQL developer ports on loopback. The API and worker use the Compose network to connect to PostgreSQL. Originals, extracted text, summary cards, accounts, and chatbot history are stored locally. Gemini inference requires internet access: the worker sends the original file, and chat sends summary cards and the full text of routed documents. Account data never goes to the provider. Use a server-side environment key, send only the text required for each call, and keep provider payloads out of logs.

Use synthetic documents for the hackathon demo. Verify the actual Gemini project's data-use terms and quota before live calls. Google distinguishes unpaid and paid data use, and its terms require Paid Services when making API clients available to users in the EEA, Switzerland, or the UK. If live access under those terms requires billing, obtain approval before enabling it. A stubbed provider supports local development and tests without a key or billing. [Gemini API terms](https://aistudio.google.com/docs/terms), [Gemini pricing](https://aistudio.google.com/docs/pricing)

### Upload and processing

1. **Validate and store.** The API reads at most `MAX_UPLOAD_MB` (20 MiB), requires a matching extension, declared media type and file signature (PDF, JPEG, PNG, and iPhone HEIC/HEIF photos, accepted by their `ftyp` brand even when the browser sends no specific media type), and rejects encrypted PDFs. No local parsing. It writes the file under a random UUID storage key and, in one transaction, inserts the document, file metadata (sanitized display filename, SHA-256), a `PENDING` processing job and an `UPLOADED` event. The response is `202`; clients poll `GET /v1/documents/{id}`.
2. **Claim work durably.** One `processing_jobs` row per document. The worker claims a ready or lease-expired row with `FOR UPDATE SKIP LOCKED`, sets `PROCESSING` with an attempt token and a 5-minute lease, and commits before any model call. Only the attempt that still holds the token can publish. [PostgreSQL locking clauses](https://www.postgresql.org/docs/current/sql-select.html)
3. **Classify (router model).** Gemini reads the file and returns `doc_type`, confidence and a reason (`vault.ai.schemas.Classification`). The model only classifies; `vault.ai.policy` decides. Blacklisted types (military or federal ID, naturalization certificate, biometric or genetic data, credentials, bank card or blank check) become `BLOCKED`: no extraction call, the file record is removed and the bytes are queued in `file_cleanup_jobs`. The document stays visible to its owner with the reason. Identity documents such as passports and driver's licenses are allowed.
4. **Extract (main model).** Gemini reads the file again and returns the full text, identifiers, contract terms, money amounts, an expiration date with its quote, and a summary card (title, holder, issuer, key facts, topics). The card is redacted (no identifiers, dates of birth or addresses).
5. **Verify against the text.** Every fact must quote an exact substring of the extracted text; identifiers must also appear inside their quote. Unsupported facts are dropped and the document is flagged `needs_review`. The expiration date must parse and its quote must be in the text, otherwise it is discarded.
6. **Publish in one transaction.** Bump `result_revision`; upsert `document_extractions` (text, identifiers, terms, financials, facts with warnings and `needs_review`) and `document_summaries` (card); upsert a `PROPOSED` deadline from the expiration date with a kind mapped from the document type; owner decisions on deadlines survive reprocessing. Set category and confidence, `policy_outcome = ALLOWED`, `review_status = REVIEW_REQUIRED`, and replace an automatic title (the filename) with the card title. Record an `ANALYZED` event with model and token usage for cost tracking.
7. **Failures.** `LLMUnavailable`, invalid model output or a missing file return the job to `PENDING` with backoff (15 s, 30 s), and after three attempts mark it `FAILED`. The owner can reprocess a completed or failed document; blocked documents cannot be reprocessed because no original is kept.

Two status fields: `processing_jobs.status` (worker lifecycle `PENDING`, `PROCESSING`, `COMPLETED`, `FAILED`, exposed as `processing_stage`) and `documents.review_status` (user lifecycle `UPLOADED` → `PROCESSING` → `REVIEW_REQUIRED` → `READY`, plus `FAILED` and `BLOCKED`). No document is `READY` before its owner confirms it.

Owner edits are stored as extraction overrides with separate provenance and never rewrite the extracted text or AI evidence.

### Authorization and accounts

- **Authentication.** Use normalized unique emails, Argon2id, a proposed 15-character minimum password, and a generous maximum that allows passphrases. Apply bounded login and registration limits by source address and login identifier in the single API process. Return generic login failures. Use short-lived signed JWTs with explicit issuer, audience, algorithm, expiry, subject, and session validation. Use opaque, hashed refresh tokens, rotate them atomically, and revoke the session on replay or logout. Check session revocation on protected requests so logout takes effect immediately. [JWT best practices](https://www.rfc-editor.org/rfc/rfc8725)
- **Document access.** An authenticated user can read a document when they own it or their current family membership has an explicit viewer grant for it. Viewers can read metadata, extracted text, deadlines, and originals, and can include the document in search and chat. Owner-only operations cover edits, reprocessing, deletion, deadline confirmation, and sharing. Reminders and chat histories are personal.
- **Family access.** A user may have one family. For MVP, a family owner can invite an already registered account. Invitations are bound to its user ID and use an expiring, single-use secret delivered manually. Acceptance requires the secret and authentication as the invited user. Sharing grants access to current recipient memberships. Joining or rejoining grants access to a previously shared document only after the owner explicitly shares it again. Removal or departure deletes inbound grants and the departing owner’s outbound grants in one transaction.
- **Request enforcement.** Use a shared authorization query in every document-backed repository read, including file lookup, extracted text, chat routing, and citation retrieval. An inaccessible UUID returns `404`. A viewer attempting to mutate a visible document receives `403`. Use bound query parameters, forbid raw storage paths in responses, serve files as attachments, and omit document text, prompts, filenames, emails, and tokens from application logs.
- **Revocation.** Keep grants out of JWTs and avoid authorization caching. Recheck access to the selected document before loading any conversation history or sending context to Gemini, and again before saving and releasing a non-streamed answer. Discard the answer if the document became inaccessible or changed during inference. Hide document-bound history immediately after revocation or member removal. Revocation governs access through the vault. Bytes already delivered to a client or text already submitted to Gemini are subject to the client and provider respectively.

### Deadlines and reminders

For allowed documents, extracted dates start as `PROPOSED`. Only the owner can confirm, correct, or reject them. A manual deadline can be created as `CONFIRMED` once the document passes screening. If a document states a notice period but leaves the actual cancellation deadline open to interpretation, display the source wording and leave the actionable date for the owner to enter.

Create reminders transactionally when a deadline is confirmed or rescheduled. Default to 7 and 1 calendar days before the deadline at 09:00 in the owner’s timezone. If both offsets have passed and the deadline is still upcoming or today, create one due reminder. Derive `SCHEDULED` or `DUE` at read time by comparing `scheduled_at` with the current time. Persist dismissal and cancel superseded schedules. This makes reminder timing independent of worker availability.

### Document chatbot

- **Routing, no embeddings.** For each question, the router model sees the summary cards (type, expiration, card) of documents the caller may read and returns up to three document IDs. The main model then answers from the full text of only those documents. Postgres full-text search is the fallback when routing returns nothing. Evals measure router recall on a labeled set of questions.
- **Answers.** Structured output: `found`, answer in the language of the question, and citations whose quotes are validated against the stored text. Unsupported facts return `INSUFFICIENT_INFORMATION`; requests for legal or financial decisions are refused. Document text is untrusted input; tools and web grounding stay disabled.
- **Sessions.** `chat_sessions.document_id` is optional so a session can span all readable documents; `chat_turns.routed_document_ids` records the router's choice. Access is rechecked before history is loaded and before an answer is saved.

## C. Database schema

Store application tables in the PostgreSQL `vault` schema. Use UUIDs for externally addressed resources, `timestamptz` for events, and `date` for document calendar dates. Validate structured JSON with Pydantic. Give foreign keys used in lookups or cascades an appropriate B-tree index.

| Entity | Keys, important fields, and indexes | Ownership and deletion |
|---|---|---|
| `users` | UUID PK. Unique normalized email, password hash, timezone, timestamps. | Account deletion is deferred. |
| `auth_sessions` | UUID PK, user FK, expiry, revocation timestamp. Index on user. | User-owned. Session deletion cascades to refresh records. |
| `refresh_tokens` | UUID PK, session FK, unique token hash, expiry, consumption timestamp. | Keep consumed hashes through session expiry for replay detection. |
| `families` | UUID PK, name, created timestamp. | Owner is represented by the owner membership. Leaving as the last member deletes the family. |
| `family_members` | Membership UUID PK, family and user FKs, role, joined timestamp. Unique user ID and partial unique owner index per family. | At most one family per user. Member removal cascades inbound grants. Family service maintains exactly one owner while members remain. |
| `family_invitations` | UUID PK, family, inviter, and existing invitee user FKs, unique secret hash, expiry, state. Index family and state and invitee user ID. | Family-owned. Family deletion cascades. Acceptance and membership creation commit together. |
| `documents` | UUID PK, owner FK, title, category (AI document types, see `vault.ai.schemas.DocType`), subtype, classification confidence, `review_status`, `confirmed_at`, `replaced_at`, timestamps, policy outcome and reason, result revision. Index owner and creation time, owner and review status. | Owner controls mutations. Deletion cascades to document data and enqueues physical file cleanup in the same transaction. |
| `document_files` | Document ID PK/FK. Unique private storage key, display filename, media type, size, SHA-256. | One original per document. Row cascades with document. |
| `file_cleanup_jobs` | Storage key UUID PK, retry time and attempt count. Index retry time. | Internal. Survives document deletion until idempotent unlink succeeds. |
| `processing_jobs` | Document ID PK/FK, status, ready time, attempts, attempt token, lease, timestamps, and sanitized error code. Partial indexes support claims and expired-lease recovery. | One job per document. Cascades with document deletion. |
| `document_events` | UUID PK, document FK, event name, JSONB payload (attempt, error code, model and token usage), timestamp. Index document and time. | Internal processing activity. Cascades with document deletion. |
| `document_extractions` | Document ID PK/FK. Pages JSONB (extracted text), facts JSONB (type, expiration and quote, warnings, `needs_review`), identifiers, terms and financials JSONB arrays (each with its quote), user overrides JSONB, model and schema versions, revision. | Document-owned and cascaded. One published extraction per document. |
| `document_summaries` | Document ID PK/FK. Summary text, structured card JSONB used by the chat router, model ID, prompt version, revision, publication timestamp. | One published summary per allowed document. Replace on successful reprocess and cascade on deletion. |
| `document_shares` | Composite PK on document and recipient membership FKs, grant timestamp. Reverse index on membership and document. | Each row is an explicit `VIEWER` grant. Deleting a document or membership cascades. Revoking a share deletes that document’s grants. |
| `document_deadlines` | UUID PK, document FK, type (including `DOCUMENT_EXPIRATION`), date or unresolved raw value, state, evidence, stable candidate key. Index document, state, and date. | Document-owned. Reprocessing reconciles proposals and preserves confirmed or rejected decisions. Cascades with document. |
| `reminders` | UUID PK, deadline and recipient FKs, UTC schedule time, offset, dismissal and cancellation timestamps. Unique deadline, offset, and scheduled time. Index recipient and schedule time. | Recipient is the document owner. Cascades with deadline deletion. |
| `chat_sessions` | UUID PK, owner user FK, optional document FK (null = all readable documents), optional title, timestamps, current turn version. Index owner, document, and update time. | Private to the creator while that user can read the document. Session or document deletion cascades to turns. |
| `chat_turns` | UUID PK, session FK, turn number, question, response status and body, citations, routed document IDs, optional source revision, timestamp. Unique session and turn number. | Return only to the session owner after a fresh authorization and policy check on the selected document. |

For metadata, summary search, and chatbot access, the common readable-document query selects the caller’s own documents plus documents with a viewer grant joined to the caller’s live membership. Require an allowed, published result for derived reads and sharing. Match children through that authorized set. Use an owner predicate in mutation statements. Use family-row locking for invitations, roster changes, and share writes so sharing and membership changes have a consistent order. Test authorization with real PostgreSQL.

## D. REST API specification

Use `/v1`, bearer access tokens, and cursor pagination where collections can grow. Return a consistent error body with `code`, `message`, and `request_id`. Authenticated routes can return `401` for invalid or revoked credentials. Request validation returns `422`. A `204` response has an empty body.

### Authentication and documents

| Method and path | Request → response | Access and additional errors |
|---|---|---|
| `POST /auth/register` | `Register(email, password, timezone?)` → `201 User` | Public. `409` email unavailable, `429` rate limit. |
| `POST /auth/login` | `Login(email, password)` → `200 TokenPair` | Public. `401` invalid credentials, `429` rate limit. |
| `POST /auth/refresh` | `Refresh(refresh_token)` → `200 TokenPair` | Valid refresh credential. `401` expired, revoked, or replayed token. |
| `POST /auth/logout` | Empty → `204` | Bearer. Revokes the caller’s current session. |
| `GET /users/me` | Empty → `200 User` | Bearer. Current account only. |
| `POST /documents` | Multipart `Upload(file, title?, category?)` → `202 Document` with a `Location` header | Bearer. Caller becomes owner. The request stores and queues the file and returns before any Gemini call. `413` too large, `415` unsupported or mismatched type, `422` encrypted PDF. |
| `GET /documents` | Scope (owned, shared, or all), category, status, cursor → `200 Page[Document]` | Bearer. Default scope is `owned`. Every scope is authorization-filtered. |
| `GET /documents/{id}` | Empty → `200 Document` | Owner/viewer. `404` inaccessible. |
| `PATCH /documents/{id}` | `DocumentPatch(title?, category?, subtype?)` → `200 Document` | Owner. `403` viewer, `404` inaccessible. A category override is preserved on processing. |
| `DELETE /documents/{id}` | Empty → `204` | Owner. `403` viewer, `404` inaccessible. Read access ends on commit. |
| `GET /documents/{id}/file` | Empty → `200 FileAttachment` | Owner/viewer. `404` inaccessible, `503` authorized file unavailable. |
| `GET /documents/{id}/extraction` | Empty → `200 Extraction` | Owner/viewer. `404` inaccessible or no published extraction, with distinct error codes for authorized documents. |
| `PATCH /documents/{id}/extraction` | `ExtractionPatch(fields, expected_revision)` → `200 Extraction` | Owner. `403` viewer, `404` inaccessible or no extraction, `409` stale revision. |
| `POST /documents/{id}/reprocess` | Empty → `202 Document` | Owner. `403` viewer, `404` inaccessible, `409` already queued or processing, or blocked document without a stored original. |
| `GET /documents/{id}/summary` | Empty → `200 {summary, card, revision}` | Owner/viewer of an allowed published result. `404` unavailable. |
| `POST /documents/{id}/confirm` | Empty → `200 Document` | Planned. Owner. `REVIEW_REQUIRED` → `READY`. |

`User` contains account ID, email, and timezone. `TokenPair` contains the access and refresh tokens and expiry information. `Document` contains safe file metadata (null for blocked documents), effective title and category, classification confidence, `processing_stage`, `review_status`, error code, processing timestamps, policy outcome and safe reason, published summary text and card when available, and revision. Clients poll `GET /documents/{id}` after receiving `202`. `Extraction` contains page text, proposed and effective field values, uncertainty, evidence, and owner-edit provenance.

### Deadlines, reminders, families, and shares

| Method and path | Request → response | Access and additional errors |
|---|---|---|
| `GET /documents/{id}/deadlines` | Optional state filter → `200 Deadline[]` | Owner/viewer. `404` inaccessible. |
| `POST /documents/{id}/deadlines` | `DeadlineCreate(type, date, label?)` → `201 Deadline` | Owner. `403` viewer, `404` inaccessible, `409` document lacks an allowed published result. Creates a confirmed manual deadline. |
| `PATCH /documents/{id}/deadlines/{deadline_id}` | `DeadlinePatch(date?, label?, state?)` → `200 Deadline` | Owner. `403` viewer, `404` wrong or inaccessible parent/child, `409` invalid transition or document lacks an allowed published result. |
| `GET /reminders` | State, `through`, cursor → `200 Page[Reminder]` | Bearer. Caller’s reminders only. |
| `POST /reminders/{id}/dismiss` | Empty → `200 Reminder` | Recipient only. `404` inaccessible, `409` superseded reminder. Repeated dismissal is idempotent. |
| `POST /families` | `FamilyCreate(name)` → `201 Family` | Bearer. `409` already a member. |
| `GET /families/me` | Empty → `200 Family` | Current member. `404` if unaffiliated. |
| `GET /families/{id}/members` | Cursor → `200 Page[FamilyMember]` | Current member. `404` outside caller’s family. |
| `DELETE /families/{id}/members/{user_id}` | Empty → `204` | Family owner. `403` regular member, `404` family/member unavailable, `409` attempted owner removal. |
| `POST /families/{id}/leave` | `LeaveFamily(successor_user_id?)` → `204` | Current member. `404` unavailable family, `409` owner with remaining members must designate a valid successor. Transfer and departure are atomic. |
| `POST /families/invitations` | `Invite(email)` → `201 InvitationCreated` | Family owner. `403` non-owner, `404` registered invitee unavailable, `409` existing member or active duplicate invite. Resolves the email to an existing user ID and returns the secret once. |
| `GET /families/invitations` | State, cursor → `200 Page[Invitation]` | Family owner. `403` otherwise. Responses omit secrets. |
| `POST /families/invitations/{id}/respond` | `InvitationDecision(secret, decision)`, with accept or reject → `200 Invitation` | Signed-in account bound to the invite with valid secret. `404` invalid or mismatched invite, `410` expired, `409` already resolved or already in a family when accepting. |
| `POST /documents/{id}/shares` | `ShareCreate(family_id)` → `200 ShareSummary` | Owner. `403` visible viewer, `404` inaccessible, `409` document lacks an allowed published result or there is no matching membership or eligible recipient. Repeating the action grants current recipients idempotently. |
| `GET /documents/{id}/shares` | Empty → `200 ShareSummary` | Owner only. `403` visible viewer, `404` inaccessible. |
| `DELETE /documents/{id}/shares` | Empty → `204` | Owner. `403` visible viewer, `404` inaccessible. Revokes all family viewer grants on the document. |

`Deadline` includes type, date, state, and source evidence. `Reminder` includes deadline and document IDs, effective status, and schedule time. `FamilyMember` includes identity, role, and join time. `ShareSummary` describes which recipient memberships have viewer access. `GET /documents?scope=shared` lists incoming shares.

### Document chatbot

| Method and path | Request → response | Access and additional errors |
|---|---|---|
| `POST /chat` | `ChatSessionCreate(title?)` → `201 ChatSession` | Implemented. Session over all documents the caller can read (`document_id` null). `GET /chat` lists them. |
| `POST /documents/{id}/chat` | `ChatSessionCreate(title?)` → `201 ChatSession` | Implemented. Owner/viewer of an allowed, processed document. Session belongs to caller. |
| `GET /documents/{id}/chat` | → `200 ChatSession[]` | Implemented. Lists only caller-owned sessions for that document. |
| `GET /chat/{id}` | → `200 ChatHistory` | Implemented. Session owner with current access. `404` inaccessible. |
| `POST /chat/{id}/messages` | `ChatMessage(message)` → `201 ChatTurn` | Implemented. Routes by summary cards (all readable documents, or the session's document), answers from routed documents' text with the last 3 turns as context. No transaction is held during the model call; access is rechecked before saving. `409` no processed documents, concurrent turn or documents changed, `502` invalid model output, `503` provider unavailable. Unverifiable answers return `INSUFFICIENT_INFORMATION`. |
| `DELETE /chat/{id}` | Empty → `204` | Implemented. Session owner. |

A citation contains document ID and a validated excerpt. `ChatTurn` contains the message, answer status, answer text, citations, and routed document IDs. Summary search with embeddings (`POST /search`) was dropped in favor of card routing.

## E. Project structure

| Location | Responsibility |
|---|---|
| `pyproject.toml`, `Dockerfile`, `compose.yaml`, `.env.example`, `README.MD` | Runtime and dependency configuration, local services, configuration keys without secrets, setup instructions. |
| `src/vault/main.py` | App setup, routers, CORS, error mapping, health check. |
| `src/vault/local_auth.py`, `families.py`, `documents.py`, `saved.py`, `chat_messages.py` | API routers: accounts and tokens; families and invitations; documents, files, extraction, sharing; deadlines, reminders and chat sessions; chat messages. |
| `evals/` | Labeled synthetic eval set, runner, latest results. |
| `src/vault/llm/` | Provider-agnostic LLM interface (`LLMClient`, model roles, usage), Gemini adapter, fake client, factory. |
| `src/vault/ai/` | Prompts, structured-output schemas, document policy, analysis pipeline with fact verification, card redaction, chat routing and answering. No database access. |
| `src/vault/services/processing.py` | Worker job logic: claim, analyze, publish, retries, file cleanup. |
| `src/vault/services/documents.py` | Replace a document's original file and reset derived data. |
| `src/vault/processing/worker.py` | Worker loop. |
| `migrations/` | Alembic revisions `0001`–`0005` (`0005` allows HEIC/HEIF originals). |
| `tests/unit/`, `tests/integration/` | AI pipeline unit tests with the fake client; API and worker integration tests on a separate `vault_test` database created by `tests/conftest.py`; a live two-user lifecycle test against the running stack. |

## F. Roadmap status

| Milestone | Status |
|---|---|
| Setup, database, authentication | Done. |
| Upload and asynchronous jobs | Done. |
| Gemini screening, extraction, verification, publication | Done (worker). Owner confirmation endpoint pending. |
| Deadlines and reminders | Done (API). Worker proposes deadlines from expiration dates. |
| Families and explicit sharing | Done. |
| Chat: card routing and answers | Done (`vault.ai.chat`, `vault.chat_messages`). |
| Evals | Done: `evals/` (24 synthetic documents, 28 questions), results in `evals/results/latest.md`. |
| Demo hardening | Pending: synthetic fixtures, live Gemini smoke run from a fresh database. |

## G. Trade-offs and decisions

| Decision | Choice and reason |
|---|---|
| OCR | Gemini reads the original file. Dropped local Tesseract and PyMuPDF: phone photos and scans read better, there is one processing stage, and the Docker image no longer needs Tesseract. Cost: every file goes to Google, and image input costs more tokens than plain text. A later option is to send embedded PDF text instead of the file for digital PDFs. |
| Search | No embeddings. Summary cards plus a cheap router model pick documents; the main model answers from full text. A family vault holds tens of documents, so cards fit in one router prompt. Postgres full-text search is the fallback. |
| Guardrails | The model classifies, code decides (blacklist). Facts must quote the source text or they are dropped. Cards are redacted. Uncertain results are flagged for owner review, and nothing becomes `READY` without confirmation. |
| Asynchronous processing | One worker and PostgreSQL-backed claims with attempt tokens and leases. No queue infrastructure. |
| Family scope | One family per user. Sharing applies to the roster at the time of the share action. |
| Accounts and invites | Local accounts and manually delivered invite secrets for registered users. No email verification or password recovery. |
| Deployment and data protection | Loopback API, private local volumes, server-side Gemini key, synthetic documents for the demo. |

The main risks are Gemini quota and data-use terms, document-type misclassification, and hallucinated facts. Fact verification against quotes and owner review mitigate the last two.

## H. End-to-end API demo

Use synthetic files.

1. Register **Alice** and **Bob**. Alice uploads a scanned lease, an auto insurance policy, and a synthetic bank card image. Each upload returns `202`.
2. Poll until processing finishes. The bank card is `BLOCKED` with a reason and no stored file. The lease shows its summary card, rent and notice period with quotes, and a proposed contract-expiration deadline. Alice confirms the deadline and lists its reminders.
3. Alice creates a family and invites Bob. Bob accepts but still cannot see Alice's documents (`404`).
4. Alice shares the lease. Bob opens it and starts a chat: "When does it expire?" then "What notice period does it give?" Answers cite the lease text. Bob's edit attempt returns `403`.
5. Alice revokes the share. Bob's download and chat history return `404`.
