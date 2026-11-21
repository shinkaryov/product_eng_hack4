"""Store model usage and prompt version per chat turn (cost per user, prompt regressions)."""

from alembic import op

revision = "0006_chat_turn_usage"
down_revision = "0005_heic_and_finance_types"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("""
        ALTER TABLE vault.chat_turns
            ADD COLUMN prompt_version text,
            ADD COLUMN usage jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(usage) = 'object')
    """)


def downgrade() -> None:
    op.execute("ALTER TABLE vault.chat_turns DROP COLUMN usage, DROP COLUMN prompt_version")
