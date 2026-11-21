"""Stage private OCR pages until document screening and publication."""

from alembic import op

revision = "0003_local_ocr"
down_revision = "0002_create_vault_schema"
branch_labels = None
depends_on = None


def upgrade():
    op.execute("""CREATE TABLE vault.document_ocr (
        document_id uuid PRIMARY KEY REFERENCES vault.documents ON DELETE CASCADE,
        pages jsonb NOT NULL CHECK (jsonb_typeof(pages)='array'),
        created_at timestamptz NOT NULL DEFAULT now()
    )""")


def downgrade():
    op.drop_table("document_ocr", schema="vault")
