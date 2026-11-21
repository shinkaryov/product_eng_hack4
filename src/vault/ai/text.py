from datetime import date


def normalize_text(text: str) -> str:
    """Collapse whitespace and casefold, for checking that a quote appears in a document."""
    return " ".join(text.split()).casefold()


def validated_date(field: str, value: str | None, quote: str | None, full_text: str, warnings: list[str]) -> date | None:
    """Accept the date only if it parses and its quote really appears in the document text."""
    if not value:
        return None
    try:
        parsed = date.fromisoformat(value)
    except ValueError:
        warnings.append(f"{field} is not a valid date")
        return None
    if not quote or not quote.strip() or normalize_text(quote) not in normalize_text(full_text):
        warnings.append(f"{field} quote not found in document text")
        return None
    return parsed
