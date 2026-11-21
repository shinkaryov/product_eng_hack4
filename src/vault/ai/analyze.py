"""Document analysis pipeline: classify (cheap model) -> policy -> extract (main model)."""

from dataclasses import dataclass, field
from datetime import date

from vault.ai import prompts
from vault.ai.policy import block_reason
from vault.ai.redact import redact_card
from vault.ai.schemas import Classification, DocType, Extraction
from vault.ai.text import normalize_text
from vault.llm import Attachment, LLMClient, ModelRole, UsageLog

# Below this confidence the UI asks the user to confirm the type.
REVIEW_CONFIDENCE = 0.7


@dataclass
class AnalysisResult:
    classification: Classification
    blocked_reason: str | None = None
    extraction: Extraction | None = None
    expires_on: date | None = None
    needs_review: bool = False
    warnings: list[str] = field(default_factory=list)
    usage: UsageLog = field(default_factory=UsageLog)
    prompt_version: str = prompts.PROMPT_VERSION

    @property
    def blocked(self) -> bool:
        return self.blocked_reason is not None


def analyze_document(llm: LLMClient, data: bytes, mime_type: str) -> AnalysisResult:
    attachment = [Attachment(data=data, mime_type=mime_type)]
    usage = UsageLog()

    classified = llm.generate_json(
        role=ModelRole.ROUTER,
        system=prompts.CLASSIFY_SYSTEM,
        prompt=prompts.CLASSIFY_PROMPT,
        schema=Classification,
        attachments=attachment,
    )
    usage.add(classified.usage)
    classification = classified.value
    result = AnalysisResult(classification=classification, usage=usage)

    # Blacklist wins regardless of confidence: a false block is cheaper than storing a forbidden copy.
    reason = block_reason(classification.doc_type)
    if reason:
        result.blocked_reason = reason
        return result

    result.needs_review = classification.confidence < REVIEW_CONFIDENCE or classification.doc_type is DocType.OTHER

    extracted = llm.generate_json(
        role=ModelRole.MAIN,
        system=prompts.EXTRACT_SYSTEM,
        prompt=prompts.EXTRACT_PROMPT_TEMPLATE.format(doc_type=classification.doc_type.value),
        schema=Extraction,
        attachments=attachment,
    )
    usage.add(extracted.usage)
    extraction = extracted.value
    extraction.summary = redact_card(extraction.summary)
    result.extraction = extraction
    result.expires_on = _validated_expiry(extraction, result.warnings)
    if extraction.expires_on and result.expires_on is None:
        result.needs_review = True
    return result


def _validated_expiry(extraction: Extraction, warnings: list[str]) -> date | None:
    """Accept the date only if it parses and its quote really appears in the document text."""
    if not extraction.expires_on:
        return None
    try:
        parsed = date.fromisoformat(extraction.expires_on)
    except ValueError:
        warnings.append(f"expires_on is not a valid date: {extraction.expires_on!r}")
        return None
    quote = (extraction.expires_on_quote or "").strip()
    if not quote or normalize_text(quote) not in normalize_text(extraction.full_text):
        warnings.append("expires_on quote not found in document text")
        return None
    return parsed

