"""Align the schema with the Gemini pipeline decisions.

- documents.category uses the fixed AI document types (identity documents allowed,
  blacklisted types recorded with policy_outcome = 'BLOCKED' and no file kept).
- document_summaries store a structured summary card for the LLM router instead of an embedding.
- chat can span all of the user's documents: chat_sessions.document_id becomes optional and
  chat_turns record which documents the router selected.
- documents.review_status follows the PRD lifecycle UPLOADED -> PROCESSING -> REVIEW_REQUIRED -> READY (+ FAILED, BLOCKED).
- document_extractions get identifiers / terms / financials arrays; documents get replaced_at (PRD FR-11).
- document_deadlines get a generic DOCUMENT_EXPIRATION kind (passports, licenses...).
- documents.language_hint is dropped (it only selected Tesseract languages).
- document_ocr (local Tesseract staging from 0003) is dropped: Gemini reads the file directly.
- document_events get a payload (step details, model, token usage) for debugging and cost tracking.
"""

from alembic import op

revision = "0004_ai_pipeline_alignment"
down_revision = "0003_local_ocr"
branch_labels = None
depends_on = None

DOC_TYPES = (
    "PASSPORT", "DRIVERS_LICENSE", "ID_CARD", "GREEN_CARD", "VISA", "BIRTH_CERTIFICATE",
    "AUTO_INSURANCE", "HOME_INSURANCE", "HEALTH_INSURANCE", "TRAVEL_INSURANCE", "LIFE_INSURANCE",
    "LEASE", "UTILITY_CONTRACT", "UTILITY_BILL", "SUBSCRIPTION",
    "VEHICLE_REGISTRATION", "VEHICLE_INSPECTION", "WARRANTY", "RECEIPT",
    "MILITARY_OR_FEDERAL_ID", "NATURALIZATION_CERTIFICATE", "BIOMETRIC_OR_GENETIC",
    "CREDENTIALS_OR_SECRETS", "BANK_CARD_OR_CHECK",
    "OTHER",
)
OLD_CATEGORIES = ("UTILITY_CONTRACT", "UTILITY_BILL", "RECEIPT", "WARRANTY", "INSURANCE", "RENTAL_AGREEMENT", "OTHER")
OLD_DEADLINE_KINDS = ("CONTRACT_EXPIRATION", "CANCELLATION", "INSURANCE_EXPIRATION", "WARRANTY_EXPIRATION", "PAYMENT_DUE", "OTHER")


def _in(values: tuple[str, ...]) -> str:
    return ", ".join(f"'{v}'" for v in values)


def upgrade() -> None:
    op.drop_table("document_ocr", schema="vault")
    op.execute("ALTER TABLE vault.documents DROP COLUMN language_hint")

    # Documents: AI document types and classifier confidence
    op.execute("ALTER TABLE vault.documents DROP CONSTRAINT documents_category_check")
    op.execute("UPDATE vault.documents SET category = 'LEASE' WHERE category = 'RENTAL_AGREEMENT'")
    op.execute("UPDATE vault.documents SET category = 'OTHER' WHERE category = 'INSURANCE'")
    op.execute(f"ALTER TABLE vault.documents ADD CONSTRAINT documents_category_check CHECK (category IN ({_in(DOC_TYPES)}))")
    # PRD FR-02 user-facing lifecycle; no document is READY before the owner confirms it.
    # BLOCKED = blacklisted type, original file removed.
    op.execute("""
        ALTER TABLE vault.documents
            ADD COLUMN classification_confidence real CHECK (classification_confidence BETWEEN 0 AND 1),
            ADD COLUMN review_status text NOT NULL DEFAULT 'UPLOADED' CHECK (review_status IN (
                'UPLOADED', 'PROCESSING', 'REVIEW_REQUIRED', 'READY', 'FAILED', 'BLOCKED'
            )),
            ADD COLUMN confirmed_at timestamptz,
            ADD COLUMN replaced_at timestamptz,
            ADD CONSTRAINT documents_ready_confirmed_check CHECK (review_status <> 'READY' OR confirmed_at IS NOT NULL)
    """)
    op.create_index("documents_owner_status_idx", "documents", ["owner_id", "review_status"], schema="vault")

    # Extractions: structured facts, each item {name, value|amount, quote, ...} verified against the text
    op.execute("""
        ALTER TABLE vault.document_extractions
            ADD COLUMN identifiers jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(identifiers) = 'array'),
            ADD COLUMN terms jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(terms) = 'array'),
            ADD COLUMN financials jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(financials) = 'array')
    """)

    # Summaries: structured card for the LLM router, no embeddings
    op.execute("""
        ALTER TABLE vault.document_summaries
            DROP COLUMN embedding,
            DROP COLUMN embedding_model_id,
            ADD COLUMN card jsonb NOT NULL CHECK (jsonb_typeof(card) = 'object'),
            ADD COLUMN model_id text NOT NULL,
            ADD COLUMN prompt_version text NOT NULL
    """)

    # Deadlines: generic document expiration
    op.execute("ALTER TABLE vault.document_deadlines DROP CONSTRAINT document_deadlines_kind_check")
    op.execute(
        "ALTER TABLE vault.document_deadlines ADD CONSTRAINT document_deadlines_kind_check "
        f"CHECK (kind IN ({_in(OLD_DEADLINE_KINDS + ('DOCUMENT_EXPIRATION',))}))"
    )

    # Chat across all documents
    op.execute("ALTER TABLE vault.chat_sessions ALTER COLUMN document_id DROP NOT NULL")
    op.create_index("chat_sessions_owner_updated_idx", "chat_sessions", ["owner_id", "updated_at"], schema="vault")
    op.execute("""
        ALTER TABLE vault.chat_turns
            ALTER COLUMN source_revision DROP NOT NULL,
            ADD COLUMN routed_document_ids uuid[] NOT NULL DEFAULT '{}'
    """)

    # Processing events: step details and token usage
    op.execute("""
        ALTER TABLE vault.document_events
            ADD COLUMN payload jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(payload) = 'object')
    """)


def downgrade() -> None:
    op.execute("ALTER TABLE vault.documents ADD COLUMN language_hint text")
    op.execute("""CREATE TABLE vault.document_ocr (
        document_id uuid PRIMARY KEY REFERENCES vault.documents ON DELETE CASCADE,
        pages jsonb NOT NULL CHECK (jsonb_typeof(pages)='array'),
        created_at timestamptz NOT NULL DEFAULT now()
    )""")

    op.execute("ALTER TABLE vault.document_events DROP COLUMN payload")

    op.execute("ALTER TABLE vault.chat_turns DROP COLUMN routed_document_ids")
    op.execute("DELETE FROM vault.chat_turns WHERE source_revision IS NULL")
    op.execute("ALTER TABLE vault.chat_turns ALTER COLUMN source_revision SET NOT NULL")
    op.drop_index("chat_sessions_owner_updated_idx", table_name="chat_sessions", schema="vault")
    op.execute("DELETE FROM vault.chat_sessions WHERE document_id IS NULL")
    op.execute("ALTER TABLE vault.chat_sessions ALTER COLUMN document_id SET NOT NULL")

    op.execute("DELETE FROM vault.document_deadlines WHERE kind = 'DOCUMENT_EXPIRATION'")
    op.execute("ALTER TABLE vault.document_deadlines DROP CONSTRAINT document_deadlines_kind_check")
    op.execute(f"ALTER TABLE vault.document_deadlines ADD CONSTRAINT document_deadlines_kind_check CHECK (kind IN ({_in(OLD_DEADLINE_KINDS)}))")

    op.execute("ALTER TABLE vault.document_extractions DROP COLUMN identifiers, DROP COLUMN terms, DROP COLUMN financials")

    # Card-based summaries cannot be converted back to embeddings
    op.execute("DELETE FROM vault.document_summaries")
    op.execute("""
        ALTER TABLE vault.document_summaries
            DROP COLUMN card,
            DROP COLUMN model_id,
            DROP COLUMN prompt_version,
            ADD COLUMN embedding public.vector NOT NULL,
            ADD COLUMN embedding_model_id text NOT NULL
    """)

    op.drop_index("documents_owner_status_idx", table_name="documents", schema="vault")
    op.execute("""
        ALTER TABLE vault.documents
            DROP CONSTRAINT documents_ready_confirmed_check,
            DROP COLUMN confirmed_at,
            DROP COLUMN replaced_at,
            DROP COLUMN review_status,
            DROP COLUMN classification_confidence
    """)
    op.execute(f"UPDATE vault.documents SET category = 'OTHER' WHERE category NOT IN ({_in(OLD_CATEGORIES)})")
    op.execute("ALTER TABLE vault.documents DROP CONSTRAINT documents_category_check")
    op.execute(f"ALTER TABLE vault.documents ADD CONSTRAINT documents_category_check CHECK (category IN ({_in(OLD_CATEGORIES)}))")
