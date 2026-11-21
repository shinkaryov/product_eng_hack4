"""Structured outputs requested from the model, and pipeline results.

Field descriptions are part of the JSON schema the model sees, so keep them precise.
"""

from enum import StrEnum

from pydantic import BaseModel, Field


class DocType(StrEnum):
    # Identity
    PASSPORT = "passport"
    DRIVERS_LICENSE = "drivers_license"
    ID_CARD = "id_card"
    GREEN_CARD = "green_card"
    VISA = "visa"
    BIRTH_CERTIFICATE = "birth_certificate"
    # Insurance
    AUTO_INSURANCE = "auto_insurance"
    HOME_INSURANCE = "home_insurance"
    HEALTH_INSURANCE = "health_insurance"
    TRAVEL_INSURANCE = "travel_insurance"
    LIFE_INSURANCE = "life_insurance"
    # Contracts and utilities
    LEASE = "lease"
    UTILITY_CONTRACT = "utility_contract"
    UTILITY_BILL = "utility_bill"
    SUBSCRIPTION = "subscription"
    # Vehicle, warranties, receipts
    VEHICLE_REGISTRATION = "vehicle_registration"
    VEHICLE_INSPECTION = "vehicle_inspection"
    WARRANTY = "warranty"
    RECEIPT = "receipt"
    # Blacklisted: never stored
    MILITARY_OR_FEDERAL_ID = "military_or_federal_id"
    NATURALIZATION_CERTIFICATE = "naturalization_certificate"
    BIOMETRIC_OR_GENETIC = "biometric_or_genetic"
    CREDENTIALS_OR_SECRETS = "credentials_or_secrets"
    BANK_CARD_OR_CHECK = "bank_card_or_check"
    # Fallback
    OTHER = "other"


# --- Step 1: classification (router model) ---------------------------------


class Classification(BaseModel):
    doc_type: DocType = Field(description="Best matching document type. Use 'other' if nothing fits.")
    confidence: float = Field(ge=0, le=1, description="Confidence in doc_type, 0..1.")
    reason: str = Field(description="One short sentence: which visible features led to this type.")


# --- Step 2: extraction (main model) ----------------------------------------


class SummaryCard(BaseModel):
    """Compact English card used by the chat router to pick relevant documents."""

    title: str = Field(description="Short human title, e.g. 'US passport - John Smith'.")
    holder: str | None = Field(description="Person or household the document belongs to, if stated.")
    issuer: str | None = Field(description="Issuing authority, insurer, provider or seller, if stated.")
    key_facts: list[str] = Field(
        description="3-8 short facts a user may ask about: coverage, amounts, deductibles, plan, "
        "auto-renewal, notice period. Copy amounts and dates exactly as written. Never include identifiers "
        "(document/policy/account/card numbers, SSN, VIN), date of birth or home address; write e.g. "
        "'policy number present' instead.",
    )
    topics: list[str] = Field(description="5-12 lowercase search keywords, e.g. 'deductible', 'auto-renewal'.")


class Extraction(BaseModel):
    full_text: str = Field(description="Complete document text as read (OCR), preserving line breaks.")
    expires_on: str | None = Field(
        description="Expiration / end-of-validity date as YYYY-MM-DD. Null if the document has none or it is unreadable.",
    )
    expires_on_quote: str | None = Field(
        description="Exact substring of full_text that states the expiration date. Null if expires_on is null.",
    )
    summary: SummaryCard


# --- Chat -------------------------------------------------------------------


class RouteDecision(BaseModel):
    document_ids: list[str] = Field(description="IDs of documents likely to contain the answer, best first. Empty if none.")


class Citation(BaseModel):
    document_id: str
    quote: str = Field(description="Exact substring of that document's text that supports the answer.")


class ChatAnswer(BaseModel):
    found: bool = Field(description="False if the provided documents do not contain the answer.")
    answer: str = Field(description="Answer in the language of the question. If not found, say so briefly.")
    citations: list[Citation]
