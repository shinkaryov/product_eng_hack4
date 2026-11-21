# Backend MVP implementation plan

Use one FastAPI application, one asynchronous document worker from the same Python package, PostgreSQL with pgvector, and a private filesystem volume. Use the Gemini Developer API with a key configured in Google AI Studio for document-type screening, extraction, summaries, summary embeddings, and conversational answers. Users search summaries, open a matching document, then start a multi-turn chatbot conversation about that document. PostgreSQL also serves as the job queue.

## A. Repository assessment

The repository is on branch `back`. Its only tracked files at inspection were a placeholder [README.MD](README.MD) and [.gitignore](.gitignore). The working tree already had a `.gitignore` change that ignores `.venv/`. The local environment uses Python 3.14.6. Docker and Compose CLIs are installed. The sandbox denied access to the Docker socket, so container startup remains unverified.

There is no reusable application code, dependency manifest, database schema, Compose configuration, or test suite. No existing architecture conflicts with the proposal. Use Python 3.12 for the initial container build and smoke-test the pinned OCR and database dependencies in Milestone 1. The existing virtual environment is separate from that proposed container runtime.

## B. Proposed architecture

### Local runtime

| Component | Responsibility |
|---|---|
| `api` | FastAPI REST endpoints, Pydantic schemas, authentication, authorization, and private downloads. Use SQLAlchemy 2.x with psycopg and explicit transaction boundaries. |
| `worker` | Single polling process from the same image. Runs local OCR, calls Gemini for document screening and approved processing, publishes results, and retries failures independently of API requests. |
| `db` | PostgreSQL for relational data, job state, and pgvector. Alembic migrations run before the API and worker start. |
| Gemini Developer API | External HTTPS dependency used by the worker for document processing and by the API for query embeddings and chatbot turns. Select generation and embedding model IDs in Milestone 1 based on account availability, structured-output support, quota, and latency. [Gemini structured outputs](https://aistudio.google.com/docs/structured-output), [Gemini pricing](https://aistudio.google.com/docs/pricing) |
| Volumes | Persistent volumes for PostgreSQL and original files. The API and worker share the private document volume. |

Publish the API and PostgreSQL developer ports on loopback. The API and worker use the Compose network to connect to PostgreSQL. Originals, OCR artifacts, summaries, embeddings, accounts, and chatbot history are stored locally. Gemini inference requires internet access and sends selected OCR text, summary and search text, or chatbot context to Google. Keep originals and account data out of provider requests. Use a server-side environment key, send only the text required for each call, and keep provider payloads out of logs.

Use synthetic documents for the hackathon demo. Verify the actual Gemini project's data-use terms and quota before live calls. Google distinguishes unpaid and paid data use, and its terms require Paid Services when making API clients available to users in the EEA, Switzerland, or the UK. If live access under those terms requires billing, obtain approval before enabling it. A stubbed provider supports local development and tests without a key or billing. [Gemini API terms](https://aistudio.google.com/docs/terms), [Gemini pricing](https://aistudio.google.com/docs/pricing)

### Upload and processing

1. **Validate and store.** Stream the upload into private staging with a byte limit. Verify the extension, declared media type, signature, and basic structure. Use configurable starting limits of 20 MiB, 50 PDF pages, and bounded image or rendered-page pixel counts. Reject unsupported and password-protected files. Generate a UUID storage key, save the original filename as sanitized display metadata, and calculate a SHA-256 digest. Move the file atomically within the volume, then commit the document and file records. On a failed commit, remove the file. A reconciler cleans up aged, unreferenced files and skips active uploads.
2. **Claim work durably.** Use one `processing_jobs` row per document. Claim a ready row with `FOR UPDATE SKIP LOCKED`, set `PROCESSING`, and record an attempt token and lease. Commit before performing OCR or inference. Record processing milestones in `document_events`. Renew the lease during long work, retry transient failures with bounded backoff, and recover expired claims. Only the current attempt can publish results. The owner can reprocess a completed or failed document. Concurrent reprocess requests return `409`. [PostgreSQL locking clauses](https://www.postgresql.org/docs/current/sql-select.html)
3. **Extract text page by page.** Use PyMuPDF for embedded text and Tesseract for scanned or low-text pages and images. Start with English and Czech OCR packs, with an optional language hint. Retain page numbers, text, extraction method, and normalized text. Keep mixed and unreadable pages visible through processing warnings. Run parsing with resource and time limits, as an unprivileged worker, without executing document actions or following embedded links. [PyMuPDF page OCR](https://pymupdf.readthedocs.io/en/latest/page.html)
4. **Screen document type with Gemini.** After local OCR, check obvious excluded-type signals locally before sending text. Use minimized text from across the document for a separate Gemini structured classification call. Require an allowlisted category, a policy outcome (`ALLOWED`, `BLOCKED`, `NEEDS_REVIEW`), reasons, and page evidence. The server applies the policy. Block identity documents, medical records and health insurance, and banking credentials. Route mixed, uncertain, unreadable, or incomplete screening to `NEEDS_REVIEW`. A user-supplied category and `OTHER` cannot override the gate. A blocked or uncertain document stays owner-private, with a reason and an option to delete or retry after improving the source or OCR. It has no published extraction, summary, reminders, sharing, or chatbot access. Gemini screening sees some text before it can classify it, so the local check reduces exposure but cannot guarantee that all out-of-scope text stays local.
5. **Extract facts and generate a summary.** For an allowed document, use bounded page batches and category-specific Pydantic schemas for Gemini structured output. Validate each proposed value, uncertainty, and page excerpt against the source. Preserve raw date and number strings, normalize supported formats, and leave ambiguous or missing facts unresolved. Keep currencies and units attached to values. Map purchase invoices to `RECEIPT` with an `INVOICE` subtype. Keep expiration, notice periods, and cancellation deadlines distinct. Generate a short searchable summary from supported facts and produce one Gemini embedding for that summary. [Gemini structured outputs](https://aistudio.google.com/docs/structured-output)
6. **Publish a consistent result.** Commit the extraction, summary and vector, and deadline candidates in one transaction. Preserve owner corrections and confirmed deadlines. A transient worker or provider failure leaves the prior allowed result available with the latest attempt status shown separately. If re-screening returns `BLOCKED` or `NEEDS_REVIEW`, immediately remove derived access, suppress associated reminders, and remove stale searchable data and grants. A deleted document or stale attempt cannot publish. Keep the worker lifecycle (`PENDING`, `PROCESSING`, `COMPLETED`, `FAILED`) separate from the policy outcome. Retry transient timeouts, rate limits, and upstream failures with bounded backoff. A valid policy decision ends the attempt without automatic retries.

Extraction covers generic dates and parties, provider and document identifiers, explicitly stated contract terms, insurance and warranty details, and deadlines. Utility bills are eligible for summaries, document questions, and payment due-date reminders. Specialized utility fields and SQL aggregation are post-MVP. Owner edits are stored as overrides with separate provenance. They do not rewrite the original OCR or AI evidence.

### Authorization and accounts

- **Authentication.** Use normalized unique emails, Argon2id, a proposed 15-character minimum password, and a generous maximum that allows passphrases. Apply bounded login and registration limits by source address and login identifier in the single API process. Return generic login failures. Use short-lived signed JWTs with explicit issuer, audience, algorithm, expiry, subject, and session validation. Use opaque, hashed refresh tokens, rotate them atomically, and revoke the session on replay or logout. Check session revocation on protected requests so logout takes effect immediately. [JWT best practices](https://www.rfc-editor.org/rfc/rfc8725)
- **Document access.** An authenticated user can read a document when they own it or their current family membership has an explicit viewer grant for it. Viewers can read metadata, OCR, deadlines, and originals, and can include the document in search and chat. Owner-only operations cover edits, reprocessing, deletion, deadline confirmation, and sharing. Reminders and chat histories are personal.
- **Family access.** A user may have one family. For MVP, a family owner can invite an already registered account. Invitations are bound to its user ID and use an expiring, single-use secret delivered manually. Acceptance requires the secret and authentication as the invited user. Sharing grants access to current recipient memberships. Joining or rejoining grants access to a previously shared document only after the owner explicitly shares it again. Removal or departure deletes inbound grants and the departing owner’s outbound grants in one transaction.
- **Request enforcement.** Use a shared authorization query in every document-backed repository read, including file lookup, OCR, search, analytics, and citation retrieval. An inaccessible UUID returns `404`. A viewer attempting to mutate a visible document receives `403`. Use bound query parameters, forbid raw storage paths in responses, serve files as attachments, and omit document text, prompts, filenames, emails, and tokens from application logs.
- **Revocation.** Keep grants out of JWTs and avoid authorization caching. Recheck access to the selected document before loading any conversation history or sending context to Gemini, and again before saving and releasing a non-streamed answer. Discard the answer if the document became inaccessible or changed during inference. Hide document-bound history immediately after revocation or member removal. Revocation governs access through the vault. Bytes already delivered to a client or text already submitted to Gemini are subject to the client and provider respectively.

### Deadlines and reminders

For allowed documents, extracted dates start as `PROPOSED`. Only the owner can confirm, correct, or reject them. A manual deadline can be created as `CONFIRMED` once the document passes screening. If a document states a notice period but leaves the actual cancellation deadline open to interpretation, display the source wording and leave the actionable date for the owner to enter.

Create reminders transactionally when a deadline is confirmed or rescheduled. Default to 7 and 1 calendar days before the deadline at 09:00 in the owner’s timezone. If both offsets have passed and the deadline is still upcoming or today, create one due reminder. Derive `SCHEDULED` or `DUE` at read time by comparing `scheduled_at` with the current time. Persist dismissal and cancel superseded schedules. This makes reminder timing independent of worker availability.

### Summary search and document chatbot

- **Summary search.** Embed the query with Gemini. Rank one summary vector per allowed, published document using exact cosine distance over the caller’s authorized set. Match embedding model and dimensions for queries and stored vectors. Apply explicit document/category filters and the access predicate before ranking and limiting. Return document ID, title, category, and summary so the caller can choose a document to open. Keep page text and vectors out of search results. [Gemini embeddings](https://aistudio.google.com/docs/embeddings), [pgvector filtering and exact search](https://github.com/pgvector/pgvector#filtering)
- **Document chatbot.** Bind each session to one selected document and one user. For each turn, load a bounded window of recent messages and retrieve relevant pages from that document using local text matching and the current question plus recent context. Send the selected excerpts and recent turns to Gemini in a stateless request, with conversation history stored in PostgreSQL. A follow-up such as “And what is the notice period?” should resolve against the same lease. Require citations to pages included in the current request and validate their excerpts against stored OCR. Use `INSUFFICIENT_INFORMATION` for unsupported facts and refuse requests for legal or financial decisions or personalized recommendations. Treat document text as untrusted input and disable tools, web grounding, and function calls. Use a turn version to detect concurrent updates without holding a database transaction open during inference.

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
| `documents` | UUID PK, owner FK, title, category, subtype, timestamps, policy outcome and reason, result revision. Index owner and creation time. | Owner controls mutations. Deletion cascades to document data and enqueues physical file cleanup in the same transaction. |
| `document_files` | Document ID PK/FK. Unique private storage key, display filename, media type, size, SHA-256. | One original per document. Row cascades with document. |
| `file_cleanup_jobs` | Storage key UUID PK, retry time and attempt count. Index retry time. | Internal. Survives document deletion until idempotent unlink succeeds. |
| `processing_jobs` | Document ID PK/FK, status, ready time, attempts, attempt token, lease, timestamps, and sanitized error code. Partial indexes support claims and expired-lease recovery. | One job per document. Cascades with document deletion. |
| `document_events` | UUID PK, document FK, event name and timestamp. Index document and time. | Internal processing activity. Cascades with document deletion. |
| `document_extractions` | Document ID PK/FK. Page text and evidence JSONB, typed AI facts and user overrides JSONB, model and schema versions, result revision. | Document-owned and cascaded. One published extraction per document. |
| `document_summaries` | Document ID PK/FK. Summary text, vector, embedding model ID, result revision, publication timestamp. | One published summary per allowed document. Replace on successful reprocess and cascade on deletion. |
| `document_shares` | Composite PK on document and recipient membership FKs, grant timestamp. Reverse index on membership and document. | Each row is an explicit `VIEWER` grant. Deleting a document or membership cascades. Revoking a share deletes that document’s grants. |
| `document_deadlines` | UUID PK, document FK, type, date or unresolved raw value, state, evidence, stable candidate key. Index document, state, and date. | Document-owned. Reprocessing reconciles proposals and preserves confirmed or rejected decisions. Cascades with document. |
| `reminders` | UUID PK, deadline and recipient FKs, UTC schedule time, offset, dismissal and cancellation timestamps. Unique deadline, offset, and scheduled time. Index recipient and schedule time. | Recipient is the document owner. Cascades with deadline deletion. |
| `chat_sessions` | UUID PK, owner user and document FKs, optional title, timestamps, current turn version. Index owner, document, and update time. | Private to the creator while that user can read the document. Session or document deletion cascades to turns. |
| `chat_turns` | UUID PK, session FK, turn number, question, response status and body, citations, source revision, timestamp. Unique session and turn number. | Return only to the session owner after a fresh authorization and policy check on the selected document. |

For metadata, summary search, and chatbot access, the common readable-document query selects the caller’s own documents plus documents with a viewer grant joined to the caller’s live membership. Require an allowed, published result for derived reads and sharing. Match children through that authorized set. Use an owner predicate in mutation statements. Use family-row locking for invitations, roster changes, and share writes so sharing and membership changes have a consistent order. Test authorization with real PostgreSQL and pgvector.

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
| `POST /documents` | Multipart `Upload(file, title?, category?, language_hint?)` → `202 Document` with a `Location` header | Bearer. Caller becomes owner. The request stages and queues the file and returns before OCR or Gemini calls. `413` too large, `415` unsupported or mismatched type, `422` invalid or unsupported document structure. |
| `GET /documents` | Scope (owned, shared, or all), category, status, cursor → `200 Page[Document]` | Bearer. Default scope is `owned`. Every scope is authorization-filtered. |
| `GET /documents/{id}` | Empty → `200 Document` | Owner/viewer. `404` inaccessible. |
| `PATCH /documents/{id}` | `DocumentPatch(title?, category?, subtype?)` → `200 Document` | Owner. `403` viewer, `404` inaccessible. A category override is preserved on processing. |
| `DELETE /documents/{id}` | Empty → `204` | Owner. `403` viewer, `404` inaccessible. Read access ends on commit. |
| `GET /documents/{id}/file` | Empty → `200 FileAttachment` | Owner/viewer. `404` inaccessible, `503` authorized file unavailable. |
| `GET /documents/{id}/extraction` | Empty → `200 Extraction` | Owner/viewer. `404` inaccessible or no published extraction, with distinct error codes for authorized documents. |
| `PATCH /documents/{id}/extraction` | `ExtractionPatch(fields, expected_revision)` → `200 Extraction` | Owner. `403` viewer, `404` inaccessible or no extraction, `409` stale revision. |
| `POST /documents/{id}/reprocess` | `Reprocess(language_hint?)` → `202 Document` | Owner. `403` viewer, `404` inaccessible, `409` already queued or processing. |

`User` contains account ID, email, and timezone. `TokenPair` contains the access and refresh tokens and expiry information. `Document` contains safe file metadata, effective title and category, processing timestamps, last attempt status, policy outcome and safe reason, published summary when available, and revision. Clients poll `GET /documents/{id}` after receiving `202`. `Extraction` contains page text, proposed and effective field values, uncertainty, evidence, and owner-edit provenance.

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

### Summary search and document chatbot

| Method and path | Request → response | Access and additional errors |
|---|---|---|
| `POST /search` | `Search(query, document_ids?, category?, limit?)` → `200 SummarySearchResults` | Bearer. Rank summaries for authorized, allowed documents only. `404` for an inaccessible explicit document filter, `503` embedding provider unavailable. |
| `POST /documents/{id}/chat` | `ChatSessionCreate(title?)` → `201 ChatSession` | Owner/viewer of an allowed, processed document. Session belongs to caller. `404` inaccessible document, `409` no allowed published result. |
| `GET /documents/{id}/chat` | Cursor → `200 Page[ChatSession]` | Owner/viewer of the document. Lists only caller-owned sessions for that document. `404` inaccessible or no published result. |
| `GET /chat/{id}` | Turn cursor → `200 ChatHistory` | Session owner with current access to the allowed document. `404` inaccessible. |
| `POST /chat/{id}/messages` | `ChatMessage(message)` → `201 ChatTurn` | Session owner with current access to the allowed document. `404` inaccessible, `409` concurrent turn or document changed during inference, `503` provider unavailable. Missing evidence returns `INSUFFICIENT_INFORMATION`. |
| `DELETE /chat/{id}` | Empty → `204` | Session owner can delete their session by ID, including after document access is revoked. `404` absent or owned by another user. |

A `SummarySearchHit` contains document ID, title, category, and summary. A citation contains document ID, page, and validated excerpt. `ChatTurn` contains the message, answer status, answer text, and citations.

## E. Project structure

| Location | Responsibility |
|---|---|
| `pyproject.toml`, `Dockerfile`, `compose.yaml`, `.env.example`, `README.MD` | Runtime and dependency configuration, local services, configuration keys without secrets, setup and demo instructions. |
| `src/vault/main.py`, `src/vault/api/` | App setup, routers, auth dependencies, request and response schemas, and error mapping. |
| `src/vault/services/` | Account, document, family, deadline, summary search, and document chatbot use cases. Services own transaction boundaries. |
| `src/vault/db/` | SQLAlchemy models, session setup, scoped repository queries, and the shared document access predicate. |
| `src/vault/processing/` | Worker loop, local OCR, document-type policy, normalization, extraction, summary generation and embedding, and publication. |
| `src/vault/infrastructure/` | Private original-file storage adapter, Gemini API client, configuration, and structured logging. The storage interface needs only put, open, and delete operations. |
| `migrations/` | Alembic revisions, including the pgvector extension migration. |
| `tests/unit/`, `tests/integration/`, `tests/fixtures/` | Parsing and schedule rules, API and worker integration, and synthetic documents. Use a Gemini stub for routine tests and a separate live smoke run with synthetic files. |

## F. Implementation roadmap

| Milestone | Scope, dependencies, and modules | APIs and database work | Acceptance and testing |
|---|---|---|---|
| **1. Setup, database, authentication** | Establish Compose, migrations, FastAPI, configuration, `api/auth`, and account services. Smoke-test OCR dependencies and verify Gemini model, quota, and terms for the demo project. | Register, login, refresh, logout, current user. Add users, sessions, and refresh tokens. | Fresh database migrates. Two users can register and sign in. Test invalid login, throttling, JWT expiry, refresh replay, concurrent rotation, logout, and secret-free logs. |
| **2. Private upload and asynchronous jobs** | Depends on 1. Add document services, scoped repositories, filesystem adapter, and durable worker claims. | Upload, list, get/status, patch, download, delete. Add documents, files, processing state, and cleanup jobs. | Upload returns `202` before processing even if the worker is stopped. The queued job survives restarts. Test cross-user CRUD, invalid uploads, retry after worker crashes, stale claims, and file cleanup. |
| **3. OCR, Gemini guardrails, and extraction** | Depends on 2. Add local PDF/image OCR, Gemini type screening, validation, and correction behavior. | Extraction read/edit and reprocess. Add policy outcome and extraction records. | Process native PDF, scanned PDF, and image fixtures. Test decisive and ambiguous classifications, disallowed and mixed docs, `OTHER` bypass attempts, prompt injection, incomplete screening, provider failures, evidence, and idempotent retries. Verify blocked docs never reach extraction or summary generation. |
| **4. Deadlines and reminders** | Depends on 3. Add candidate reconciliation, confirmations, schedule policy, and reminders. | Deadline list/create/edit and reminder list/dismiss. Add deadlines and reminders. | A pending candidate creates no reminders. Confirmation schedules two offsets when applicable, and time advancement makes them due without a worker tick. Test owner isolation, edits, rejection, timezone handling, and duplicate prevention. |
| **5. Families and explicit sharing** | Depends on 2 and 3. Extend the access query and add family transactions. Run after 4 to verify deadline and reminder boundaries as well. | Family, membership, registered-user invitation, and share routes. Add family, membership, invitation, and grant tables. | B joins A’s family and still sees no private documents. Sharing exposes only selected allowed documents. Test invite replay, rejection of unknown accounts, unauthorized edits and shares, removal, revocation, and rejoin. |
| **6. Summary search** | Depends on 3 and 5. Add grounded summaries, Gemini embeddings, and authorized pgvector queries. | Search endpoint. Add pgvector and document summaries. Backfill through the existing reprocess operation. | Search returns matching summaries as document entry points. Seed a private summary that would otherwise rank first and verify it is excluded. Test reprocessing, blocked docs, provider outages, revocation, and deletion. |
| **7. Multi-turn document chatbot** | Depends on 3, 5, and 6. Add document-bound conversation state, page retrieval, and citation validation. | Document-scoped chatbot sessions, history, messages, and deletion. Add sessions and turns. | After opening a search result, ask a question and a contextual follow-up. Test session isolation, missing evidence, provider payload scope, document prompt injection, concurrent turns, revocation during inference, and deletion. |
| **8. Integration, hardening, demo** | Depends on 1–7. Finish synthetic fixtures, Compose instructions, logging, and runtime checks. | No new product endpoints or schema planned. | Run the full two-user matrix on PostgreSQL and pgvector with a Gemini stub. Run an approved live Gemini smoke test with synthetic files. Rehearse from a fresh database and verify status behavior during a provider outage. |

The primary release test is one continuous two-user scenario spanning private CRUD, family membership, explicit sharing, revocation, and deletion. It checks OCR, policy outcomes, metadata, downloads, deadlines, reminders, summary results, Gemini request contents, and conversation history. Add separate cases for member removal and revocation while a turn is in progress. Authentication and authorization tests use the real API and database, with Gemini stubbed where deterministic inputs and outputs matter.

## G. Trade-offs and decisions for approval

| Decision | MVP choice |
|---|---|
| Asynchronous processing and search | One worker, PostgreSQL-backed claims, and exact vector search over document summaries. Defer queue infrastructure, approximate indexes, and page embeddings. |
| Family scope | One family per user. Sharing applies to the roster at the time of the share action. Owners explicitly include new members and must transfer ownership before leaving a populated family. |
| Accounts and invites | Local accounts and manually delivered invite secrets for registered users. Defer invitations for unregistered people, email verification, and password recovery. |
| Extraction and guardrails | Use Gemini screening plus a server-side allowlist. Start with English and Czech fixtures. Keep uncertain facts unresolved and require confirmation for reminder-producing deadlines. Defer complex contract interpretation and specialized table extraction. |
| Chatbot | Persist bounded multi-turn context per document and use page citations. Defer cross-document chatbot conversations. |
| Structured utility analytics | Defer specialized billing-field extraction, a utility SQL schema, aggregation endpoints, and cross-bill calculations. Utility bills stay in scope for search, single-document chat, and due-date reminders. |
| Deployment and data protection | Loopback API, private local volumes, server-side Gemini credentials, and minimized cloud inference payloads. Host and database administrators remain trusted. Defer application-managed encryption, sync, and multi-host deployment. |

The main execution risks are Gemini quota and access terms, document-type misclassification, OCR errors, and leaks through summary results or chatbot history. Measure OCR and provider latency in Milestone 1, keep evidence reviewable, and use synthetic documents for provider testing. The working decisions to approve are the Gemini cloud data boundary, the demo project's access terms and billing if required, current-roster sharing, and owner-only reminders.

## H. End-to-end API demo

Use a test clock set to **October 24, 2026** and synthetic files.

1. Register **Alice** and **Bob**. Alice uploads a scanned lease ending **October 31, 2026**, a private electricity bill, and a synthetic travel document that exercises the excluded-type guardrail. Bob uploads his private warranty certificate. Show that each upload returns `202` while work proceeds asynchronously.
2. Poll until processing finishes. Show that the out-of-scope document has no summary or chatbot access. For the lease, review the extracted end date and page citation. Confirm the deadline and list its October 24 and October 30 reminders.
3. Alice creates a family and invites Bob’s registered account. Bob accepts. As Bob, attempt to download Alice’s lease. The API returns `404`, and the lease also stays out of his search.
4. Alice explicitly shares the lease. Bob searches for “rental agreement,” opens the lease from its summary, and starts a chatbot session. He asks “When does it expire?” then “And what notice period does it give?” Both answers cite the lease. Bob’s attempt to edit it returns `403`. Alice’s bill stays private.
5. Alice revokes the lease share. Bob’s download and chatbot history return `404`, a new turn on that session is rejected, and summary search excludes the lease. Bob can still access his own warranty.

Implementation is pending approval.
