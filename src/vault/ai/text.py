def normalize_text(text: str) -> str:
    """Collapse whitespace and casefold, for checking that a quote appears in a document."""
    return " ".join(text.split()).casefold()
