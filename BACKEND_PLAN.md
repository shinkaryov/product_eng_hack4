# Backend MVP implementation plan

Use one FastAPI application, one worker from the same Python package, PostgreSQL with pgvector, a private filesystem volume, and local Ollama. The worker handles OCR, extraction, embeddings, and file cleanup. The API handles authentication, authorization, and document access. PostgreSQL also serves as the job queue, so the MVP needs no separate broker.

## A. Repository assessment

The repository is on branch `back`. Its only tracked files at inspection were a placeholder [README.MD](README.MD) and [.gitignore](.gitignore). The working tree already had a `.gitignore` change that ignores `.venv/`. The local environment uses Python 3.14.6. Docker and Compose CLIs are installed. The sandbox denied access to the Docker socket, so container startup remains unverified.

There is no reusable application code, dependency manifest, database schema, Compose configuration, or test suite. No existing architecture conflicts with the proposal. Use Python 3.12 for the initial container build and smoke-test the pinned OCR and database dependencies in Milestone 1. The existing virtual environment is separate from that proposed container runtime.

## B. Proposed architecture

### Local runtime

| Component | Responsibility |
|---|---|
| `api` | FastAPI REST endpoints, Pydantic schemas, authentication, authorization, and private downloads. Use SQLAlchemy 2.x with psycopg and explicit transaction boundaries. |
| `worker` | Single polling process from the same image. Owns file processing, bounded retries, and filesystem cleanup. |
| `db` | PostgreSQL for relational data, job state, and pgvector. Alembic migrations run before the API and worker start. |
| `ollama` | Local generation and embeddings. Start by testing `qwen3:4b` and `bge-m3` on the demo machine. Pin the model artifacts and verify embedding dimensions before fixing the vector schema. [Generation model](https://ollama.com/library/qwen3:4b), [embedding model](https://ollama.com/library/bge-m3) |
| Volumes | Separate persistent volumes for PostgreSQL, original files, and model weights. The API and worker share the private document volume. |

Publish only the API on loopback and keep PostgreSQL and Ollama on the Compose network. Preload model weights, disable Ollama cloud features, and prove the demo works with internet connectivity disabled after setup. Start with containerized inference. Measure latency early and use native local Ollama on the demo machine if container inference is too slow. [Ollama local configuration](https://docs.ollama.com/faq), [Docker Compose networking](https://docs.docker.com/compose/how-tos/networking)

### Upload and processing

1. **Validate and store.** Stream the upload into private staging with a byte limit. Verify the extension, declared media type, signature, and basic structure. Use configurable starting limits of 20 MiB, 50 PDF pages, and bounded image or rendered-page pixel counts. Reject unsupported and password-protected files. Generate a UUID storage key, save the original filename as sanitized display metadata, and calculate a SHA-256 digest. Move the file atomically within the volume, then commit the document and file records. On a failed commit, remove the file. A reconciler cleans up aged, unreferenced files and skips active uploads.
2. **Claim work durably.** Use the document row as the queue item. Claim a ready row with `FOR UPDATE SKIP LOCKED`, set `PROCESSING`, and record an attempt token and lease. Commit before performing OCR or inference. Renew the lease during long work, retry transient failures with bounded backoff, and recover expired claims. Only the current attempt can publish results. The owner can reprocess a completed or failed document. Concurrent reprocess requests return `409`. [PostgreSQL locking clauses](https://www.postgresql.org/docs/current/sql-select.html)
3. **Extract text page by page.** Use PyMuPDF for embedded text and Tesseract for scanned or low-text pages and images. Start with English and Czech OCR packs, with an optional language hint. Retain page numbers, text, extraction method, and normalized text. Keep mixed and unreadable pages visible through processing warnings. Run parsing with resource and time limits, as an unprivileged worker, without executing document actions or following embedded links. [PyMuPDF page OCR](https://pymupdf.readthedocs.io/en/latest/page.html)
4. **Extract and validate facts.** Use bounded page batches and a category-specific Pydantic schema for Ollama structured output. Each proposed fact carries a value, uncertainty, and a page and excerpt. Check that the excerpt exists on the indicated page and supports the value before accepting it. Preserve raw strings, normalize supported dates and decimal formats, and leave ambiguous or missing values unresolved. Keep currency and units attached to their values. Map purchase invoices to `RECEIPT` with an `INVOICE` subtype. Treat cancellation notice periods, explicit cancellation deadlines, and expiration dates as distinct fields. [Ollama structured outputs](https://docs.ollama.com/capabilities/structured-outputs)
5. **Publish a consistent result.** Chunk text within page boundaries and embed locally. Commit the replacement extraction, chunks, eligible utility record, and deadline candidate updates in one transaction. Preserve owner corrections and confirmed deadlines. A failed retry leaves the last successful result available, with the latest attempt status shown separately. A deleted document or stale worker attempt cannot publish results. [Ollama embeddings](https://docs.ollama.com/capabilities/embeddings)

Extraction covers generic dates and parties, provider and document identifiers, contract terms explicitly stated in the text, insurance policy and premium details, warranty periods, and utility billing periods, usage, amounts, and due dates. Owner edits are stored as overrides with separate provenance. They do not rewrite the original OCR or AI evidence.

### Authorization and accounts

- **Authentication.** Use normalized unique emails, Argon2id, a proposed 15-character minimum password, and a generous maximum that allows passphrases. Apply bounded login and registration limits by source address and login identifier in the single API process. Return generic login failures. Use short-lived signed JWTs with explicit issuer, audience, algorithm, expiry, subject, and session validation. Use opaque, hashed refresh tokens, rotate them atomically, and revoke the session on replay or logout. Check session revocation on protected requests so logout takes effect immediately. [JWT best practices](https://www.rfc-editor.org/rfc/rfc8725)
- **Document access.** An authenticated user can read a document when they own it or their current family membership has an explicit viewer grant for it. Viewers can read metadata, OCR, deadlines, and originals, and can include the document in search and chat. Owner-only operations cover edits, reprocessing, deletion, deadline confirmation, and sharing. Reminders and chat histories are personal.
- **Family access.** A user may have one family. Invitations use an expiring, single-use secret delivered manually, independent of whether the invitee has registered. Acceptance requires the secret and a signed-in account matching the normalized invite email. Sharing grants access to the current recipient memberships. Joining or rejoining grants access to a previously shared document only after the owner explicitly shares it again. Removal or departure deletes inbound grants and the departing owner’s outbound grants in one transaction.
- **Request enforcement.** Use a shared authorization query in every document-backed repository read, including file lookup, OCR, search, analytics, and citation retrieval. An inaccessible UUID returns `404`. A viewer attempting to mutate a visible document receives `403`. Use bound query parameters, forbid raw storage paths in responses, serve files as attachments, and omit document text, prompts, filenames, emails, and tokens from application logs.
- **Revocation.** Keep grants out of JWTs and avoid authorization caching. Admit retrieval and downloads using current database permissions. Recheck chat evidence before model handoff and again before releasing the non-streamed answer. Discard the answer if a dependency became inaccessible or changed while inference ran. Store the complete set of source documents used by each turn and check that set when returning history. An already admitted download may have delivered bytes before revocation commits.

### Deadlines and reminders

Extracted dates start as `PROPOSED`. Only the owner can confirm, correct, or reject them. A manual deadline can be created as `CONFIRMED`. If a document states a notice period but leaves the actual cancellation deadline open to interpretation, display the source wording and leave the actionable date for the owner to enter.

Create reminders transactionally when a deadline is confirmed or rescheduled. Default to 7 and 1 calendar days before the deadline at 09:00 in the owner’s timezone. If both offsets have passed and the deadline is still upcoming or today, create one due reminder. Derive `SCHEDULED` or `DUE` at read time by comparing `scheduled_at` with the current time. Persist dismissal and cancel superseded schedules. This makes reminder timing independent of worker availability.

### Search, chat, and exact analytics

- **Semantic search.** Embed the query, select authorized document IDs in PostgreSQL, and rank only chunks joined to that set. Apply document filters and authorization before ranking and limiting results. Start with exact cosine search and ordinary relational indexes. API responses return citations and excerpts, with vectors kept internal. [pgvector filtering and exact search](https://github.com/pgvector/pgvector#filtering)
- **Grounded chat.** Route each question to a fixed intent such as document lookup, deadline lookup, or utility totals. Send only authorized excerpts to the model as untrusted data. Give the model no tools, filesystem access, network actions, or ability to issue SQL. Validate citation IDs against the supplied evidence. Use structured facts or short verbatim quotes for dates, amounts, and contract clauses. Return `INSUFFICIENT_INFORMATION` for weak, ambiguous, or unsupported evidence. Each MVP turn retrieves fresh context. Stored history is available to its owner, with an unavailable placeholder for any turn whose sources are no longer accessible.
- **Utility analytics.** Use a validated request with utility type, metric, date range, and optional document IDs. Join authorized utility records before any grouping. Deduplicate identical files and equivalent invoices within that visible set. Report conflicting copies or overlapping periods for review. Use SQL `NUMERIC` or Python `Decimal`, group by unit and currency, and return source documents, gaps, and estimated versus actual usage when available. Monthly buckets use bills whose full billing periods fit in the calendar month. Report cross-month bills separately without prorating. Costs use compatible currencies, and missing periods stay missing. The API renders the computed figures directly. The model can interpret the question and explain the result.

## C. Database schema

Use UUIDs for externally addressed resources, `timestamptz` for events, `date` for document calendar dates, and `NUMERIC` for money and consumption. Validate structured JSON with Pydantic. Give every foreign key used in lookups or cascades an appropriate B-tree index.

| Entity | Keys, important fields, and indexes | Ownership and deletion |
|---|---|---|
| `users` | UUID PK. Unique normalized email, password hash, timezone, timestamps. | Account deletion is deferred. |
| `auth_sessions` | UUID PK, user FK, expiry, revocation timestamp. Index on user. | User-owned. Session deletion cascades to refresh records. |
| `refresh_tokens` | UUID PK, session FK, unique token hash, expiry, consumption timestamp. | Keep consumed hashes through session expiry for replay detection. |
| `families` | UUID PK, name, created timestamp. | Owner is represented by the owner membership. Leaving as the last member deletes the family. |
| `family_members` | Membership UUID PK, family and user FKs, role, joined timestamp. Unique user ID and partial unique owner index per family. | At most one family per user. Member removal cascades inbound grants. Family service maintains exactly one owner while members remain. |
| `family_invitations` | UUID PK, family and inviter FKs, normalized invite email, unique secret hash, expiry, state. Index family and state. | Family-owned. Family deletion cascades. Acceptance and membership creation commit together. |
| `documents` | UUID PK, owner FK, title, category, subtype, timestamps, processing status, attempt token, lease, retry time, sanitized error code, result revision. Index owner and creation time, plus a partial queue index. | Owner controls mutations. Deletion cascades to document data and enqueues physical file cleanup in the same transaction. |
| `document_files` | Document ID PK/FK. Unique private storage key, display filename, media type, size, SHA-256. | One original per document. Row cascades with document. |
| `file_cleanup_jobs` | UUID PK, unique storage key, retry time and attempt count. Index retry time. | Internal. Survives document deletion until idempotent unlink succeeds. |
| `document_extractions` | Document ID PK/FK. Page text and evidence JSONB, typed AI facts and user overrides JSONB, model and schema versions, result revision. | Document-owned and cascaded. One published extraction per document. |
| `document_chunks` | UUID PK, document FK, page, ordinal, text, vector, model fingerprint, result revision. Unique document and ordinal. | Document-owned. Replace on successful reprocess and cascade on deletion. |
| `document_shares` | Composite PK on document and recipient membership FKs, grant timestamp. Reverse index on membership and document. | Each row is an explicit `VIEWER` grant. Deleting a document or membership cascades. Revoking a share deletes that document’s grants. |
| `document_deadlines` | UUID PK, document FK, type, date or unresolved raw value, state, evidence, stable candidate key. Index document, state, and date. | Document-owned. Reprocessing reconciles proposals and preserves confirmed or rejected decisions. Cascades with document. |
| `reminders` | UUID PK, deadline and recipient FKs, UTC schedule time, offset, dismissal and cancellation timestamps. Unique deadline, offset, and scheduled time. Index recipient and schedule time. | Recipient is the document owner. Cascades with deadline deletion. |
| `utility_bill_records` | Document ID PK/FK. Utility type, provider, invoice and service identifiers when present, normalized billing range, decimal consumption and total cost, unit, currency, reading type, evidence. Index type and billing range. | One usable bill record per document. Replaced with the published extraction and cascaded on deletion. |
| `chat_sessions` | UUID PK, user FK, optional title, timestamps. Index owner and update time. | Private to the creator. Session deletion cascades to turns. |
| `chat_turns` | UUID PK, session FK, question, response status and body, citations, complete source document ID set, timestamp. Index session and time. | Return only to session owner after a fresh source-access check. Deleting a source document clears dependent answer text and citations while retaining an unavailable marker. Keep dependency IDs available for the access check even when a source disappears. |

For metadata, vector search, and analytics, the common readable-document query selects the caller’s own documents plus documents with a viewer grant joined to the caller’s live membership. Match children through that authorized set. Use an owner predicate in mutation statements. Use family-row locking for invitations, roster changes, and share writes so sharing and membership changes have a consistent order. Test authorization with real PostgreSQL and pgvector.

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
| `POST /documents` | Multipart `Upload(file, title?, category?, language_hint?)` → `202 Document` | Bearer. Caller becomes owner. `413` too large, `415` unsupported or mismatched type, `422` invalid or unsupported document structure. |
| `GET /documents` | Scope (owned, shared, or all), category, status, cursor → `200 Page[Document]` | Bearer. Default scope is `owned`. Every scope is authorization-filtered. |
| `GET /documents/{id}` | Empty → `200 Document` | Owner/viewer. `404` inaccessible. |
| `PATCH /documents/{id}` | `DocumentPatch(title?, category?, subtype?)` → `200 Document` | Owner. `403` viewer, `404` inaccessible. A category override is preserved on processing. |
| `DELETE /documents/{id}` | Empty → `204` | Owner. `403` viewer, `404` inaccessible. Read access ends on commit. |
| `GET /documents/{id}/file` | Empty → `200 FileAttachment` | Owner/viewer. `404` inaccessible, `503` authorized file unavailable. |
| `GET /documents/{id}/extraction` | Empty → `200 Extraction` | Owner/viewer. `404` inaccessible or no published extraction, with distinct error codes for authorized documents. |
| `PATCH /documents/{id}/extraction` | `ExtractionPatch(fields, expected_revision)` → `200 Extraction` | Owner. `403` viewer, `404` inaccessible or no extraction, `409` stale revision. |
| `POST /documents/{id}/reprocess` | `Reprocess(language_hint?)` → `202 Document` | Owner. `403` viewer, `404` inaccessible, `409` already queued or processing. |

`User` contains account ID, email, and timezone. `TokenPair` contains the access and refresh tokens and expiry information. `Document` contains safe file metadata, effective title and category, processing timestamps, last attempt status, and published revision. `Extraction` contains page text, proposed and effective field values, uncertainty, evidence, and owner-edit provenance.

### Deadlines, reminders, families, and shares

| Method and path | Request → response | Access and additional errors |
|---|---|---|
| `GET /documents/{id}/deadlines` | Optional state filter → `200 Deadline[]` | Owner/viewer. `404` inaccessible. |
| `POST /documents/{id}/deadlines` | `DeadlineCreate(type, date, label?)` → `201 Deadline` | Owner. `403` viewer, `404` inaccessible. Creates a confirmed manual deadline. |
| `PATCH /documents/{id}/deadlines/{deadline_id}` | `DeadlinePatch(date?, label?, state?)` → `200 Deadline` | Owner. `403` viewer, `404` wrong or inaccessible parent/child, `409` invalid transition. |
| `GET /reminders` | State, `through`, cursor → `200 Page[Reminder]` | Bearer. Caller’s reminders only. |
| `POST /reminders/{id}/dismiss` | Empty → `200 Reminder` | Recipient only. `404` inaccessible, `409` superseded reminder. Repeated dismissal is idempotent. |
| `POST /families` | `FamilyCreate(name)` → `201 Family` | Bearer. `409` already a member. |
| `GET /families/me` | Empty → `200 Family` | Current member. `404` if unaffiliated. |
| `GET /families/{id}/members` | Cursor → `200 Page[FamilyMember]` | Current member. `404` outside caller’s family. |
| `DELETE /families/{id}/members/{user_id}` | Empty → `204` | Family owner. `403` regular member, `404` family/member unavailable, `409` attempted owner removal. |
| `POST /families/{id}/leave` | `LeaveFamily(successor_user_id?)` → `204` | Current member. `404` unavailable family, `409` owner with remaining members must designate a valid successor. Transfer and departure are atomic. |
| `POST /families/invitations` | `Invite(email)` → `201 InvitationCreated` | Family owner. `403` non-owner, `409` existing member or active duplicate invite. Returns the secret once. |
| `GET /families/invitations` | State, cursor → `200 Page[Invitation]` | Family owner. `403` otherwise. Responses omit secrets. |
| `POST /families/invitations/{id}/respond` | `InvitationDecision(secret, decision)`, with accept or reject → `200 Invitation` | Signed-in matching invitee with valid secret. `404` invalid or mismatched invite, `410` expired, `409` already resolved or already in a family when accepting. |
| `POST /documents/{id}/shares` | `ShareCreate(family_id)` → `200 ShareSummary` | Owner. `403` visible viewer, `404` inaccessible, `409` no matching membership or eligible recipients. Repeating the action grants current recipients idempotently. |
| `GET /documents/{id}/shares` | Empty → `200 ShareSummary` | Owner only. `403` visible viewer, `404` inaccessible. |
| `DELETE /documents/{id}/shares` | Empty → `204` | Owner. `403` visible viewer, `404` inaccessible. Revokes all family viewer grants on the document. |

`Deadline` includes type, date, state, and source evidence. `Reminder` includes deadline and document IDs, effective status, and schedule time. `FamilyMember` includes identity, role, and join time. `ShareSummary` describes which recipient memberships have viewer access. `GET /documents?scope=shared` lists incoming shares.

### Search, analytics, and chat

| Method and path | Request → response | Access and additional errors |
|---|---|---|
| `POST /search` | `Search(query, document_ids?, category?, limit?)` → `200 SearchResults` | Bearer. Authorized documents only. `404` for an inaccessible explicit document filter, `503` embedding model unavailable. |
| `POST /search/utility` | `UtilityQuery(type, metric, from, to, document_ids?)` → `200 UtilityResult` | Same document authorization. `404` inaccessible explicit filter, `422` invalid period or metric. |
| `POST /chat` | `ChatSessionCreate(title?)` → `201 ChatSession` | Bearer. Session belongs to caller. |
| `GET /chat` | Cursor → `200 Page[ChatSession]` | Bearer. Caller’s sessions only. |
| `GET /chat/{id}` | Turn cursor → `200 ChatHistory` | Session owner. `404` inaccessible. Source permissions checked for each returned turn. |
| `POST /chat/{id}/messages` | `ChatQuestion(question, document_ids?)` → `201 ChatTurn` | Session owner, with authorized source filtering. `404` inaccessible session or explicit document filter, `503` inference unavailable. Missing evidence is a successful turn with `INSUFFICIENT_INFORMATION`. |
| `DELETE /chat/{id}` | Empty → `204` | Session owner. `404` inaccessible. |

A citation contains document ID, page, and validated excerpt. `UtilityResult` includes grouped values, units or currencies, coverage gaps, and cited inputs. `ChatTurn` contains status, answer, citations, and an optional typed utility result.

## E. Project structure

| Location | Responsibility |
|---|---|
| `pyproject.toml`, `Dockerfile`, `compose.yaml`, `.env.example`, `README.MD` | Runtime and dependency configuration, local services, configuration keys without secrets, setup and demo instructions. |
| `src/vault/main.py`, `src/vault/api/` | App setup, routers, auth dependencies, request and response schemas, and error mapping. |
| `src/vault/services/` | Account, document, family, deadline, search, chat, and analytics use cases. Services own transaction boundaries. |
| `src/vault/db/` | SQLAlchemy models, session setup, scoped repository queries, and the shared document access predicate. |
| `src/vault/processing/` | Worker loop, text extraction, normalization, structured extraction, chunking, and publication. |
| `src/vault/infrastructure/` | Private original-file storage adapter, Ollama client, configuration, and structured logging. The storage interface needs only put, open, and delete operations. |
| `migrations/` | Alembic revisions, including the pgvector extension migration. |
| `tests/unit/`, `tests/integration/`, `tests/fixtures/` | Parsing and schedule rules, API and worker integration, and synthetic documents. Keep a small real-OCR and real-Ollama smoke suite alongside deterministic tests. |

## F. Implementation roadmap

| Milestone | Scope, dependencies, and modules | APIs and database work | Acceptance and testing |
|---|---|---|---|
| **1. Setup, database, authentication** | Establish Compose, migrations, FastAPI, configuration, `api/auth`, and account services. Smoke-test OCR dependencies and model startup early. | Register, login, refresh, logout, current user. Add users, sessions, and refresh tokens. | Fresh database migrates. Two users can register and sign in. Test invalid login, throttling, JWT expiry, refresh replay, concurrent rotation, logout, and secret-free logs. |
| **2. Private upload and CRUD** | Depends on 1. Add `services/documents`, scoped repositories, and filesystem adapter. | Upload, list, get, patch, download, delete. Add documents, files, and cleanup jobs. | A can upload and retrieve an original. B cannot list, read, download, edit, or delete it. Test malformed signatures, oversized uploads, path-like filenames, upload rollback, and retriable deletion cleanup. |
| **3. OCR and extraction** | Depends on 2. Add worker claims, PDF/image OCR, validation, and correction behavior. | Extraction read/edit and reprocess. Add extraction data and job fields. | Process native PDF, scanned PDF, and image fixtures. Validate multilingual dates, missing fields, and page evidence. Test worker crashes, stale leases, reprocessing, preserved overrides, and failed results without duplicate rows. |
| **4. Deadlines and reminders** | Depends on 3. Add candidate reconciliation, confirmations, schedule policy, and reminders. | Deadline list/create/edit and reminder list/dismiss. Add deadlines and reminders. | A pending candidate creates no reminders. Confirmation schedules two offsets when applicable, and time advancement makes them due without a worker tick. Test owner isolation, edits, rejection, timezone handling, and duplicate prevention. |
| **5. Families and explicit sharing** | Depends on 2. Extend the access query and add family transactions. Run after 4 to verify deadline and reminder boundaries as well. | Family, membership, invitation, and share routes. Add family, membership, invitation, and grant tables. | B joins A’s family and still sees no private documents. Sharing exposes only selected documents with viewer permissions. Test invite replay, future invitee registration, unauthorized edits and shares, removal, revocation, and rejoin. |
| **6. Embeddings, search, and chat** | Depends on 3 and 5. Add chunking, local embeddings, evidence-only retrieval, and citation validation. | Search and chat routes. Add pgvector, chunks, sessions, and turns. Backfill through the existing reprocess operation. | B sees only shared chunks. Seed a private chunk that would otherwise rank first and assert it never reaches the model. Test revocation during inference, stale history, document deletion, document prompt injection, and insufficient evidence. |
| **7. Utility analytics** | Depends on 3 and 5 for extraction and scope, and 6 for chat integration. Add billing normalization and a fixed query path. | Utility endpoint and typed chat result. Add utility records and relevant indexes. | Verify exact decimal results, source pages, and access scope. Test duplicate and conflicting invoices, missing months, mixed units and currencies, estimates, overlapping bills, and cross-month periods. |
| **8. Integration, hardening, demo** | Depends on 1–7. Finish synthetic fixtures, clean Compose instructions, structured logging, and runtime checks. | No new product endpoints or schema planned. | Run the full two-user matrix on real PostgreSQL and pgvector. Use model stubs to inspect the exact inputs, plus a real OCR and Ollama smoke run. Rehearse from a fresh database with internet disconnected after setup. |

The primary release test is one continuous two-user scenario spanning private CRUD, family membership, explicit sharing, revoke, and deletion. It checks OCR, metadata, downloads, deadlines, reminders, vector results, model inputs, analytics, and chat history. Add separate cases for member removal and revocation while inference is in progress. Authentication and authorization tests use the real API and database, with only inference stubbed where deterministic inputs and outputs matter.

## G. Trade-offs and decisions for approval

| Decision | MVP choice |
|---|---|
| Worker, database, and vectors | One worker, PostgreSQL-backed claims, and exact vector search. Defer queue infrastructure, approximate indexes, and distributed processing until measurements justify them. |
| Family scope | One family per user. Sharing applies to the roster at the time of the share action. Owners explicitly include new members and must transfer ownership before leaving a populated family. |
| Accounts and invites | Local accounts and manually delivered invite secrets. An email is a local identifier in the MVP. Defer email verification and password recovery. |
| Extraction accuracy | Start with English and Czech fixtures. Treat unknown dates and amounts as unresolved. Confirm every reminder-producing deadline. Defer complex contract interpretation, extensive language coverage, and specialized table extraction. |
| Chat and analytics | Persist history and retrieve fresh evidence per turn. Keep the supported numeric operations small, typed, and deterministic. Defer contextual follow-ups, proration, currency conversion, and custom reports. |
| Deployment and data protection | Loopback API, private volumes, isolated model runtime, and application-level access control. Host and database administrators remain trusted. Defer application-managed encryption, key sharing, sync, and multi-host deployment. |

The main execution risks are model latency on the demo machine, OCR errors in dates and bill tables, and access leaks through derived data. Measure OCR and inference in Milestone 1, keep uncertain fields and evidence reviewable, and require the two-user test matrix before using real documents. The working decisions to approve are Python 3.12 in Compose, current-roster sharing, owner-only reminders, and conservative monthly reporting without bill proration.

## H. End-to-end API demo

Use a test clock set to **October 24, 2026** and synthetic files.

1. Register **Alice** and **Bob**. Alice uploads a scanned lease that explicitly ends **October 31, 2026** and July, August, and September electricity bills for **126, 142, and 118 kWh**. Bob uploads his own private warranty certificate.
2. Poll the lease until processing completes. Show the extracted end date and its page citation. Show that the proposed deadline generates no reminder until Alice confirms it. Confirm it and list the October 24 and October 30 reminders.
3. Alice creates a family and Bob accepts the invitation. As Bob, attempt to download Alice’s lease. The API returns `404`. The lease also stays out of Bob’s search.
4. Alice explicitly shares the lease. Bob can download it and ask, “When does the lease expire?” The answer returns **October 31, 2026** and cites the lease page. Bob’s attempt to edit the lease returns `403`. Alice’s bills stay private.
5. As Alice, ask, “How much electricity did I use from July through September?” Show the three monthly readings and the **386 kWh** total from the structured query, with bill citations. Ask for June and show the missing period.
6. Alice revokes the lease share. Bob’s download returns `404`, search excludes the lease, a fresh chat question returns insufficient information, and the prior chat answer displays as unavailable. Bob can still access his own warranty.

Implementation is pending approval.
