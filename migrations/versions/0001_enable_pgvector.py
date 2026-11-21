"""Enable pgvector in the vault database."""

from alembic import op

revision = "0001_enable_pgvector"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("CREATE EXTENSION vector WITH SCHEMA public")


def downgrade() -> None:
    op.execute("DROP EXTENSION vector")
