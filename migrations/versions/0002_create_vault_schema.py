"""Create the application tables in the vault PostgreSQL schema."""

from alembic import op

revision = "0002_create_vault_schema"
down_revision = "0001_enable_pgvector"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("CREATE SCHEMA vault")
    op.execute("""
        CREATE TABLE vault.users (
            id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            email text NOT NULL UNIQUE CHECK (email <> '' AND email = lower(btrim(email))),
            password_hash text NOT NULL,
            timezone text NOT NULL DEFAULT 'UTC',
            created_at timestamptz NOT NULL DEFAULT now()
        )
    """)
    op.execute("""
        CREATE TABLE vault.auth_sessions (
            id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id uuid NOT NULL REFERENCES vault.users ON DELETE CASCADE,
            created_at timestamptz NOT NULL DEFAULT now(),
            expires_at timestamptz NOT NULL,
            revoked_at timestamptz,
            CHECK (expires_at > created_at)
        )
    """)
    op.create_index("auth_sessions_user_idx", "auth_sessions", ["user_id"], schema="vault")
    op.execute("""
        CREATE TABLE vault.refresh_tokens (
            id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            session_id uuid NOT NULL REFERENCES vault.auth_sessions ON DELETE CASCADE,
            token_hash text NOT NULL UNIQUE,
            created_at timestamptz NOT NULL DEFAULT now(),
            expires_at timestamptz NOT NULL,
            consumed_at timestamptz,
            CHECK (expires_at > created_at)
        )
    """)
    op.create_index("refresh_tokens_session_idx", "refresh_tokens", ["session_id"], schema="vault")

    op.execute("""
        CREATE TABLE vault.families (
            id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            name text NOT NULL CHECK (btrim(name) <> ''),
            created_at timestamptz NOT NULL DEFAULT now()
        )
    """)
    op.execute("""
        CREATE TABLE vault.family_members (
            id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            family_id uuid NOT NULL REFERENCES vault.families ON DELETE CASCADE,
            user_id uuid NOT NULL UNIQUE REFERENCES vault.users,
            role text NOT NULL CHECK (role IN ('OWNER', 'MEMBER')),
            joined_at timestamptz NOT NULL DEFAULT now()
        )
    """)
    op.create_index("family_members_family_idx", "family_members", ["family_id"], schema="vault")
    op.execute("CREATE UNIQUE INDEX family_members_owner_idx ON vault.family_members (family_id) WHERE role = 'OWNER'")
    op.execute("""
        CREATE TABLE vault.family_invitations (
            id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            family_id uuid NOT NULL REFERENCES vault.families ON DELETE CASCADE,
            inviter_id uuid NOT NULL REFERENCES vault.users,
            invitee_id uuid NOT NULL REFERENCES vault.users,
            secret_hash text NOT NULL UNIQUE,
            state text NOT NULL DEFAULT 'PENDING'
                CHECK (state IN ('PENDING', 'ACCEPTED', 'REJECTED', 'EXPIRED')),
            created_at timestamptz NOT NULL DEFAULT now(),
            expires_at timestamptz NOT NULL,
            CHECK (inviter_id <> invitee_id),
            CHECK (expires_at > created_at)
        )
    """)
    op.create_index("family_invitations_family_idx", "family_invitations", ["family_id", "state"], schema="vault")
    op.create_index("family_invitations_invitee_idx", "family_invitations", ["invitee_id"], schema="vault")

    op.execute("""
        CREATE TABLE vault.documents (
            id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            owner_id uuid NOT NULL REFERENCES vault.users,
            title text NOT NULL CHECK (btrim(title) <> ''),
            category text CHECK (category IN (
                'UTILITY_CONTRACT', 'UTILITY_BILL', 'RECEIPT', 'WARRANTY',
                'INSURANCE', 'RENTAL_AGREEMENT', 'OTHER'
            )),
            subtype text,
            language_hint text,
            policy_outcome text CHECK (policy_outcome IN ('ALLOWED', 'BLOCKED', 'NEEDS_REVIEW')),
            policy_reason text,
            result_revision integer NOT NULL DEFAULT 0 CHECK (result_revision >= 0),
            created_at timestamptz NOT NULL DEFAULT now(),
            updated_at timestamptz NOT NULL DEFAULT now()
        )
    """)
    op.create_index("documents_owner_created_idx", "documents", ["owner_id", "created_at", "id"], schema="vault")
    op.execute("""
        CREATE TABLE vault.document_files (
            document_id uuid PRIMARY KEY REFERENCES vault.documents ON DELETE CASCADE,
            storage_key uuid NOT NULL UNIQUE,
            display_filename text NOT NULL,
            media_type text NOT NULL CHECK (media_type IN ('application/pdf', 'image/jpeg', 'image/png')),
            size_bytes bigint NOT NULL CHECK (size_bytes > 0),
            sha256 text NOT NULL CHECK (sha256 ~ '^[a-f0-9]{64}$')
        )
    """)
    op.execute("""
        CREATE TABLE vault.file_cleanup_jobs (
            storage_key uuid PRIMARY KEY,
            retry_at timestamptz NOT NULL DEFAULT now(),
            attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0)
        )
    """)
    op.create_index("file_cleanup_jobs_retry_idx", "file_cleanup_jobs", ["retry_at"], schema="vault")
    op.execute("""
        CREATE TABLE vault.processing_jobs (
            document_id uuid PRIMARY KEY REFERENCES vault.documents ON DELETE CASCADE,
            status text NOT NULL DEFAULT 'PENDING'
                CHECK (status IN ('PENDING', 'PROCESSING', 'COMPLETED', 'FAILED')),
            available_at timestamptz NOT NULL DEFAULT now(),
            attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
            attempt_token uuid,
            lease_expires_at timestamptz,
            started_at timestamptz,
            finished_at timestamptz,
            error_code text,
            CHECK ((status = 'PROCESSING') = (attempt_token IS NOT NULL)),
            CHECK ((status = 'PROCESSING') = (lease_expires_at IS NOT NULL))
        )
    """)
    op.execute("CREATE INDEX processing_jobs_ready_idx ON vault.processing_jobs (available_at) WHERE status = 'PENDING'")
    op.execute("CREATE INDEX processing_jobs_lease_idx ON vault.processing_jobs (lease_expires_at) WHERE status = 'PROCESSING'")
    op.execute("""
        CREATE TABLE vault.document_events (
            id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            document_id uuid NOT NULL REFERENCES vault.documents ON DELETE CASCADE,
            event_name text NOT NULL CHECK (btrim(event_name) <> ''),
            created_at timestamptz NOT NULL DEFAULT now()
        )
    """)
    op.create_index("document_events_document_idx", "document_events", ["document_id", "created_at"], schema="vault")
    op.execute("""
        CREATE TABLE vault.document_extractions (
            document_id uuid PRIMARY KEY REFERENCES vault.documents ON DELETE CASCADE,
            revision integer NOT NULL CHECK (revision > 0),
            pages jsonb NOT NULL CHECK (jsonb_typeof(pages) = 'array'),
            facts jsonb NOT NULL CHECK (jsonb_typeof(facts) = 'object'),
            overrides jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(overrides) = 'object'),
            model_id text NOT NULL,
            schema_version integer NOT NULL CHECK (schema_version > 0),
            published_at timestamptz NOT NULL DEFAULT now()
        )
    """)
    op.execute("""
        CREATE TABLE vault.document_summaries (
            document_id uuid PRIMARY KEY REFERENCES vault.documents ON DELETE CASCADE,
            revision integer NOT NULL CHECK (revision > 0),
            summary text NOT NULL CHECK (btrim(summary) <> ''),
            embedding public.vector NOT NULL,
            embedding_model_id text NOT NULL,
            published_at timestamptz NOT NULL DEFAULT now()
        )
    """)
    op.execute("""
        CREATE TABLE vault.document_shares (
            document_id uuid NOT NULL REFERENCES vault.documents ON DELETE CASCADE,
            membership_id uuid NOT NULL REFERENCES vault.family_members ON DELETE CASCADE,
            granted_at timestamptz NOT NULL DEFAULT now(),
            PRIMARY KEY (document_id, membership_id)
        )
    """)
    op.create_index("document_shares_membership_idx", "document_shares", ["membership_id", "document_id"], schema="vault")

    op.execute("""
        CREATE TABLE vault.document_deadlines (
            id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            document_id uuid NOT NULL REFERENCES vault.documents ON DELETE CASCADE,
            kind text NOT NULL CHECK (kind IN (
                'CONTRACT_EXPIRATION', 'CANCELLATION', 'INSURANCE_EXPIRATION',
                'WARRANTY_EXPIRATION', 'PAYMENT_DUE', 'OTHER'
            )),
            label text,
            due_on date,
            raw_value text,
            state text NOT NULL DEFAULT 'PROPOSED' CHECK (state IN ('PROPOSED', 'CONFIRMED', 'REJECTED')),
            evidence jsonb,
            candidate_key text,
            UNIQUE (document_id, candidate_key),
            CHECK (state <> 'CONFIRMED' OR due_on IS NOT NULL)
        )
    """)
    op.create_index("document_deadlines_lookup_idx", "document_deadlines", ["document_id", "state", "due_on"], schema="vault")
    op.execute("""
        CREATE TABLE vault.reminders (
            id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            deadline_id uuid NOT NULL REFERENCES vault.document_deadlines ON DELETE CASCADE,
            recipient_id uuid NOT NULL REFERENCES vault.users,
            scheduled_at timestamptz NOT NULL,
            offset_days integer NOT NULL CHECK (offset_days >= 0),
            dismissed_at timestamptz,
            cancelled_at timestamptz,
            UNIQUE (deadline_id, offset_days, scheduled_at)
        )
    """)
    op.create_index("reminders_recipient_schedule_idx", "reminders", ["recipient_id", "scheduled_at", "id"], schema="vault")

    op.execute("""
        CREATE TABLE vault.chat_sessions (
            id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            owner_id uuid NOT NULL REFERENCES vault.users ON DELETE CASCADE,
            document_id uuid NOT NULL REFERENCES vault.documents ON DELETE CASCADE,
            title text,
            turn_version integer NOT NULL DEFAULT 0 CHECK (turn_version >= 0),
            created_at timestamptz NOT NULL DEFAULT now(),
            updated_at timestamptz NOT NULL DEFAULT now()
        )
    """)
    op.create_index("chat_sessions_owner_document_idx", "chat_sessions", ["owner_id", "document_id", "updated_at"], schema="vault")
    op.create_index("chat_sessions_document_idx", "chat_sessions", ["document_id"], schema="vault")
    op.execute("""
        CREATE TABLE vault.chat_turns (
            id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            session_id uuid NOT NULL REFERENCES vault.chat_sessions ON DELETE CASCADE,
            turn_number integer NOT NULL CHECK (turn_number > 0),
            question text NOT NULL CHECK (btrim(question) <> ''),
            answer_status text NOT NULL CHECK (answer_status IN ('ANSWERED', 'INSUFFICIENT_INFORMATION', 'REFUSED')),
            answer text NOT NULL,
            citations jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(citations) = 'array'),
            source_revision integer NOT NULL CHECK (source_revision > 0),
            created_at timestamptz NOT NULL DEFAULT now(),
            UNIQUE (session_id, turn_number)
        )
    """)


def downgrade() -> None:
    for table in (
        "chat_turns", "chat_sessions", "reminders", "document_deadlines", "document_shares",
        "document_summaries", "document_extractions", "document_events", "processing_jobs",
        "file_cleanup_jobs", "document_files", "documents", "family_invitations", "family_members",
        "families", "refresh_tokens", "auth_sessions", "users",
    ):
        op.drop_table(table, schema="vault")
    op.execute("DROP SCHEMA vault")
