"""Accept iPhone photos (HEIC / HEIF originals) and add bank statement and tax document types."""

from alembic import op

revision = "0005_heic_and_finance_types"
down_revision = "0004_ai_pipeline_alignment"
branch_labels = None
depends_on = None

OLD_TYPES = (
    "PASSPORT", "DRIVERS_LICENSE", "ID_CARD", "GREEN_CARD", "VISA", "BIRTH_CERTIFICATE",
    "AUTO_INSURANCE", "HOME_INSURANCE", "HEALTH_INSURANCE", "TRAVEL_INSURANCE", "LIFE_INSURANCE",
    "LEASE", "UTILITY_CONTRACT", "UTILITY_BILL", "SUBSCRIPTION",
    "VEHICLE_REGISTRATION", "VEHICLE_INSPECTION", "WARRANTY", "RECEIPT",
    "MILITARY_OR_FEDERAL_ID", "NATURALIZATION_CERTIFICATE", "BIOMETRIC_OR_GENETIC",
    "CREDENTIALS_OR_SECRETS", "BANK_CARD_OR_CHECK",
    "OTHER",
)
NEW_TYPES = OLD_TYPES + ("BANK_STATEMENT", "TAX_DOCUMENT")
OLD_MEDIA = ("application/pdf", "image/jpeg", "image/png")
NEW_MEDIA = OLD_MEDIA + ("image/heic", "image/heif")


def _in(values: tuple[str, ...]) -> str:
    return ", ".join(f"'{v}'" for v in values)


def _set_checks(types: tuple[str, ...], media: tuple[str, ...]) -> None:
    op.execute("ALTER TABLE vault.documents DROP CONSTRAINT documents_category_check")
    op.execute(f"ALTER TABLE vault.documents ADD CONSTRAINT documents_category_check CHECK (category IN ({_in(types)}))")
    op.execute("ALTER TABLE vault.document_files DROP CONSTRAINT document_files_media_type_check")
    op.execute(f"ALTER TABLE vault.document_files ADD CONSTRAINT document_files_media_type_check CHECK (media_type IN ({_in(media)}))")


def upgrade() -> None:
    _set_checks(NEW_TYPES, NEW_MEDIA)


def downgrade() -> None:
    op.execute("UPDATE vault.documents SET category = 'OTHER' WHERE category IN ('BANK_STATEMENT', 'TAX_DOCUMENT')")
    op.execute(f"DELETE FROM vault.documents WHERE id IN (SELECT document_id FROM vault.document_files WHERE media_type NOT IN ({_in(OLD_MEDIA)}))")
    _set_checks(OLD_TYPES, OLD_MEDIA)
