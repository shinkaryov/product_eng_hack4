"""Deterministic masking of identifiers in summary cards.

Summary cards are sent to the router model on every chat question, so they must
not carry full identifiers. The full text (used only for the routed documents)
keeps them. This is a safety net on top of the prompt rule: the model may still
leak a number, the regex catches it.
"""

import re

from vault.ai.schemas import SummaryCard

# Card / account numbers written in digit groups: "4111 1111 1111 1111"
_GROUPED_DIGITS = re.compile(r"\b\d(?:[ -]?\d){11,18}\b")
# Identifier-like tokens: passport / license / policy numbers, VIN, SSN ("912345678", "SDM-4471-209")
_ID_TOKEN = re.compile(r"\b[A-Z0-9](?:[A-Z0-9-]){4,}[A-Z0-9]\b", re.IGNORECASE)
_ISO_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def _mask(token: str) -> str:
    tail = re.sub(r"[^A-Za-z0-9]", "", token)[-4:]
    return f"•••{tail}"


def _mask_id_token(match: re.Match[str]) -> str:
    token = match.group(0)
    digits = sum(ch.isdigit() for ch in token)
    if digits < 4 or _ISO_DATE.match(token):
        return token  # words, short codes and ISO dates stay readable
    return _mask(token)


def mask_identifiers(text: str) -> str:
    text = _GROUPED_DIGITS.sub(lambda m: _mask(m.group(0)), text)
    return _ID_TOKEN.sub(_mask_id_token, text)


def redact_card(card: SummaryCard) -> SummaryCard:
    def clean(value: str | None) -> str | None:
        return mask_identifiers(value) if value else value

    return SummaryCard(
        title=clean(card.title) or "",
        holder=card.holder,
        issuer=clean(card.issuer),
        key_facts=[clean(f) or "" for f in card.key_facts],
        topics=[clean(t) or "" for t in card.topics],
    )
