"""Deterministic document policy. The model only classifies; code decides."""

from vault.ai.schemas import DocType

BLOCKED_TYPES: dict[DocType, str] = {
    DocType.MILITARY_OR_FEDERAL_ID: "Copies of military and federal agency IDs are restricted by US federal law.",
    DocType.NATURALIZATION_CERTIFICATE: "Copying naturalization and citizenship certificates is restricted by US federal law.",
    DocType.BIOMETRIC_OR_GENETIC: "We do not store biometric or genetic data.",
    DocType.CREDENTIALS_OR_SECRETS: "We do not store passwords, PINs, recovery codes or seed phrases.",
    DocType.BANK_CARD_OR_CHECK: "We do not store bank card images or blank checks.",
}


def block_reason(doc_type: DocType) -> str | None:
    """Return a user-facing reason if this type must not be stored, else None."""
    return BLOCKED_TYPES.get(doc_type)
