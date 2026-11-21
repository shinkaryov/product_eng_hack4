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
    # Finance (statements and tax forms are stored; card images and checks are blacklisted below)
    BANK_STATEMENT = "bank_statement"
    TAX_DOCUMENT = "tax_document"
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


class DocumentFact(BaseModel):
    name: str = Field(description="snake_case key, e.g. 'policy_number', 'notice_period', 'auto_renewal'.")
    value: str = Field(description="Value exactly as written in the document.")
    quote: str = Field(description="Exact substring of full_text that contains the value.")


class MoneyFact(BaseModel):
    name: str = Field(description="snake_case key, e.g. 'premium', 'collision_deductible', 'monthly_rent', 'total_due'.")
    amount: str = Field(description="Amount exactly as written, without currency symbol, e.g. '1,250.00'.")
    currency: str | None = Field(description="ISO 4217 code, e.g. 'USD'. Null if not stated.")
    period: str | None = Field(description="'one_time', 'monthly', 'quarterly', 'semiannual', 'annual' or null if not stated.")
    quote: str = Field(description="Exact substring of full_text that contains the amount.")


class Extraction(BaseModel):
    full_text: str = Field(description="Complete document text as read (OCR), preserving line breaks.")
    identifiers: list[DocumentFact] = Field(
        description="Identifiers printed on the document: document, passport, license, policy, contract, account, "
        "member, invoice numbers, VIN. Never invent or complete partial numbers.",
    )
    terms: list[DocumentFact] = Field(
        description="Contract and validity terms: policy/contract period, notice period for cancellation, "
        "auto-renewal, cancellation conditions, early termination, warranty duration, grace period, payment due rules.",
    )
    financials: list[MoneyFact] = Field(
        description="Money amounts: premiums, rent, deductibles, coverage limits, fees, penalties, totals due.",
    )
    expires_on: str | None = Field(
        description="Expiration / end of validity / contract end as YYYY-MM-DD. Not a payment due date. "
        "Null if the document has none or it is unreadable.",
    )
    expires_on_quote: str | None = Field(
        description="Exact substring of full_text that states the expiration date. Null if expires_on is null.",
    )
    payment_due_on: str | None = Field(
        default=None,
        description="Explicit payment due date on a bill, invoice, credit card statement or tax bill as YYYY-MM-DD. Null if absent or ambiguous.",
    )
    payment_due_on_quote: str | None = Field(
        default=None,
        description="Exact substring of full_text that identifies the utility bill payment due date.",
    )
    summary: SummaryCard


# --- Chat -------------------------------------------------------------------


class RouteDecision(BaseModel):
    standalone_question: str = Field(
        default="",
        description="The current question rewritten to be understandable without the conversation "
        "(resolve 'it', 'that policy', 'and the deductible?'). Same language as the question.",
    )
    document_ids: list[str] = Field(description="IDs of documents likely to contain the answer, best first. Empty if none.")


class Citation(BaseModel):
    document_id: str
    quote: str = Field(description="Exact substring of that document's text that supports the answer.")


class ChatAnswer(BaseModel):
    found: bool = Field(description="False if the provided documents do not contain the answer.")
    answer: str = Field(
        description="Answer in the language of the question, with markers like [1] after each claim that refer to "
        "citations by 1-based position. If not found, say so briefly.",
    )
    citations: list[Citation]


class Source(BaseModel):
    """A verified citation as returned to the client: `n` matches the [n] marker in the answer text."""

    n: int
    document_id: str
    document_title: str
    category: str
    quote: str
