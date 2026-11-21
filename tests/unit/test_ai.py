from datetime import date

from vault.ai.analyze import analyze_document
from vault.ai.chat import (
    MAX_ROUTER_CARDS,
    NOT_FOUND,
    NOT_FOUND_UK,
    DocCard,
    Turn,
    answer_question,
)
from vault.ai.schemas import (
    ChatAnswer,
    Citation,
    Classification,
    DocType,
    DocumentFact,
    Extraction,
    MoneyFact,
    RouteDecision,
    SummaryCard,
)
from vault.llm import ModelRole
from vault.llm.fake import FakeLLMClient

PASSPORT_TEXT = "UNITED STATES OF AMERICA\nPASSPORT\nSurname: SMITH\nDate of expiration 12 AUG 2031"
CARD = SummaryCard(
    title="US passport - John Smith",
    holder="John Smith",
    issuer="U.S. Department of State",
    key_facts=["expires 12 AUG 2031"],
    topics=["passport", "travel"],
)


def _extraction(expires_on: str | None = "2031-08-12", quote: str | None = "12 AUG 2031") -> Extraction:
    return Extraction(
        full_text=PASSPORT_TEXT, identifiers=[], terms=[], financials=[],
        expires_on=expires_on, expires_on_quote=quote, summary=CARD,
    )


def test_blacklisted_document_skips_extraction():
    llm = FakeLLMClient(
        responses={Classification: Classification(doc_type=DocType.BANK_CARD_OR_CHECK, confidence=0.4, reason="card")}
    )
    result = analyze_document(llm, b"img", "image/jpeg")
    assert result.blocked
    assert result.extraction is None
    assert len(llm.calls) == 1
    assert llm.calls[0].role is ModelRole.ROUTER


def test_allowed_document_extracts_verified_expiry():
    llm = FakeLLMClient(
        responses={
            Classification: Classification(doc_type=DocType.PASSPORT, confidence=0.95, reason="passport"),
            Extraction: _extraction(),
        }
    )
    result = analyze_document(llm, b"img", "image/jpeg")
    assert not result.blocked
    assert result.expires_on == date(2031, 8, 12)
    assert not result.needs_review
    assert [c.role for c in llm.calls] == [ModelRole.ROUTER, ModelRole.MAIN]


def test_expiry_with_hallucinated_quote_is_rejected():
    llm = FakeLLMClient(
        responses={
            Classification: Classification(doc_type=DocType.PASSPORT, confidence=0.95, reason="passport"),
            Extraction: _extraction(quote="01 JAN 2040"),
        }
    )
    result = analyze_document(llm, b"img", "image/jpeg")
    assert result.expires_on is None
    assert result.needs_review
    assert result.warnings


def test_low_confidence_needs_review():
    llm = FakeLLMClient(
        responses={
            Classification: Classification(doc_type=DocType.LEASE, confidence=0.5, reason="maybe"),
            Extraction: _extraction(expires_on=None, quote=None),
        }
    )
    result = analyze_document(llm, b"img", "application/pdf")
    assert result.needs_review
    assert result.expires_on is None


def _cards() -> list[DocCard]:
    return [DocCard(document_id="doc-1", doc_type="passport", expires_on="2031-08-12", summary=CARD)]


def test_chat_ignores_unknown_routed_ids():
    llm = FakeLLMClient(responses={RouteDecision: RouteDecision(document_ids=["doc-999"])})
    result = answer_question(llm, "When does my passport expire?", _cards(), load_texts=lambda ids: {})
    assert not result.found
    assert result.answer == NOT_FOUND
    assert len(llm.calls) == 1


def test_chat_answer_with_valid_citation():
    llm = FakeLLMClient(
        responses={
            RouteDecision: RouteDecision(document_ids=["doc-1", "doc-1"]),
            ChatAnswer: ChatAnswer(
                found=True,
                answer="12 AUG 2031",
                citations=[Citation(document_id="doc-1", quote="Date of expiration 12 AUG 2031")],
            ),
        }
    )
    result = answer_question(llm, "Коли спливає паспорт?", _cards(), load_texts=lambda ids: {i: PASSPORT_TEXT for i in ids})
    assert result.found
    assert result.routed_document_ids == ["doc-1"]
    assert len(result.citations) == 1
    assert "<document id=\"doc-1\">" in llm.calls[1].prompt


def test_chat_answer_without_verifiable_citation_is_not_found():
    llm = FakeLLMClient(
        responses={
            RouteDecision: RouteDecision(document_ids=["doc-1"]),
            ChatAnswer: ChatAnswer(
                found=True,
                answer="It expires in 2040",
                citations=[Citation(document_id="doc-1", quote="expires 2040"), Citation(document_id="doc-1", quote=" ")],
            ),
        }
    )
    result = answer_question(llm, "When?", _cards(), load_texts=lambda ids: {i: PASSPORT_TEXT for i in ids})
    assert not result.found
    assert result.answer == NOT_FOUND
    assert result.dropped_citations == 2


def test_chat_sources_are_numbered_deduped_and_markers_renumbered():
    llm = FakeLLMClient(
        responses={
            RouteDecision: RouteDecision(document_ids=["doc-1"]),
            ChatAnswer: ChatAnswer(
                found=True,
                answer="Holder is SMITH [1]. It expires 12 AUG 2031 [2][3]. Renewal is free [4].",
                citations=[
                    Citation(document_id="doc-1", quote="Surname: SMITH"),
                    Citation(document_id="doc-1", quote="made up quote"),
                    Citation(document_id="doc-1", quote="Date of expiration 12 AUG 2031"),
                    Citation(document_id="doc-1", quote="surname:   smith"),
                ],
            ),
        }
    )
    result = answer_question(llm, "Passport?", _cards(), load_texts=lambda ids: {i: PASSPORT_TEXT for i in ids})
    assert result.found
    assert [(s.n, s.quote) for s in result.citations] == [(1, "Surname: SMITH"), (2, "Date of expiration 12 AUG 2031")]
    assert result.citations[0].document_title == "US passport - John Smith"
    assert result.citations[0].category == "passport"
    assert result.answer == "Holder is SMITH [1]. It expires 12 AUG 2031 [2]. Renewal is free [1]."
    assert result.dropped_citations == 1


def test_chat_document_id_marker_maps_to_its_source():
    llm = FakeLLMClient(
        responses={
            RouteDecision: RouteDecision(document_ids=["doc-1"]),
            ChatAnswer: ChatAnswer(found=True, answer="It expires 12 AUG 2031 [doc-1] (see [page 1]).",
                                   citations=[Citation(document_id="doc-1", quote="12 AUG 2031")]),
        }
    )
    result = answer_question(llm, "When?", _cards(), load_texts=lambda ids: {i: PASSPORT_TEXT for i in ids})
    assert result.answer == "It expires 12 AUG 2031 [1] (see [page 1])."


def test_chat_follow_up_uses_standalone_question_and_previous_documents():
    llm = FakeLLMClient(
        responses={
            RouteDecision: RouteDecision(standalone_question="When does John Smith's passport expire?",
                                         document_ids=["doc-1"]),
            ChatAnswer: ChatAnswer(found=True, answer="12 AUG 2031 [1]",
                                   citations=[Citation(document_id="doc-1", quote="12 AUG 2031")]),
        }
    )
    result = answer_question(
        llm, "And when does it expire?", _cards(), load_texts=lambda ids: {i: PASSPORT_TEXT for i in ids},
        history=[Turn("Whose passport is it?", "John Smith's [1]")], previous_document_ids=["doc-1", "doc-gone"],
    )
    router, answer = llm.calls
    assert "Whose passport is it?" in router.prompt
    assert 'Documents used in the previous answer: ["doc-1"]' in router.prompt
    assert "Question: When does John Smith's passport expire?" in answer.prompt
    assert "Question as asked: And when does it expire?" in answer.prompt
    assert result.standalone_question == "When does John Smith's passport expire?"


def test_mask_identifiers():
    from vault.ai.redact import mask_identifiers

    assert mask_identifiers("Passport No. 912345678") == "Passport No. •••5678"
    assert mask_identifiers("Policy number: SDM-4471-209") == "Policy number: •••1209"
    assert mask_identifiers("VIN 2T3P1RFV8KW012345") == "VIN •••2345"
    assert mask_identifiers("card 4111 1111 1111 1111") == "card •••1111"
    assert mask_identifiers("SSN 123-45-6789") == "SSN •••6789"
    # stays readable
    assert mask_identifiers("Collision deductible: $500") == "Collision deductible: $500"
    assert mask_identifiers("Bodily injury: $100,000 / $300,000") == "Bodily injury: $100,000 / $300,000"
    assert mask_identifiers("expires 2026-06-01, period 01/15/2026") == "expires 2026-06-01, period 01/15/2026"
    assert mask_identifiers("2019 Toyota RAV4") == "2019 Toyota RAV4"


def test_summary_card_is_redacted_after_extraction():
    leaky = CARD.model_copy(update={"key_facts": ["Passport No. 912345678", "expires 12 AUG 2031"]})
    llm = FakeLLMClient(
        responses={
            Classification: Classification(doc_type=DocType.PASSPORT, confidence=0.95, reason="passport"),
            Extraction: _extraction().model_copy(update={"summary": leaky}),
        }
    )
    result = analyze_document(llm, b"img", "image/jpeg")
    assert result.extraction.summary.key_facts == ["Passport No. •••5678", "expires 12 AUG 2031"]


POLICY_TEXT = """SAFEDRIVE MUTUAL INSURANCE
Policy number: SDM-4471-209
Policy period: 01/15/2026 to 07/15/2026
Cancellation requires 30 days written notice.
Six-month premium: $1,250.00
Collision deductible: $500"""


def test_facts_are_kept_only_when_supported_by_text():
    extraction = Extraction(
        full_text=POLICY_TEXT,
        identifiers=[
            DocumentFact(name="policy_number", value="SDM-4471-209", quote="Policy number: SDM-4471-209"),
            DocumentFact(name="policy_number", value="SDM-4471-999", quote="Policy number: SDM-4471-209"),  # fabricated
        ],
        terms=[
            DocumentFact(name="notice_period", value="30 days", quote="Cancellation requires 30 days written notice."),
            DocumentFact(name="auto_renewal", value="yes", quote="Renews automatically"),  # not in text
        ],
        financials=[
            MoneyFact(name="premium", amount="1,250.00", currency="USD", period="semiannual", quote="Six-month premium: $1,250.00"),
            MoneyFact(name="collision_deductible", amount="5000", currency="USD", period=None, quote="Collision deductible: $500"),
        ],
        expires_on="2026-07-15",
        expires_on_quote="07/15/2026",
        summary=CARD,
    )
    llm = FakeLLMClient(
        responses={
            Classification: Classification(doc_type=DocType.AUTO_INSURANCE, confidence=0.95, reason="policy"),
            Extraction: extraction,
        }
    )
    result = analyze_document(llm, b"img", "application/pdf")
    ext = result.extraction
    assert [f.value for f in ext.identifiers] == ["SDM-4471-209"]
    assert [f.name for f in ext.terms] == ["notice_period"]
    assert [m.name for m in ext.financials] == ["premium"]
    assert result.needs_review
    assert any("dropped 3" in w for w in result.warnings)


def test_parse_amount():
    from decimal import Decimal

    from vault.ai.analyze import parse_amount

    assert parse_amount("1,250.00") == Decimal("1250.00")
    assert parse_amount("$500") == Decimal("500")
    assert parse_amount("n/a") is None


def test_chat_prompts_get_today_and_router_prompt_ends_with_question():
    llm = FakeLLMClient(
        responses={
            RouteDecision: RouteDecision(document_ids=["doc-1"]),
            ChatAnswer: ChatAnswer(found=True, answer="Valid until 12 AUG 2031 [1]",
                                   citations=[Citation(document_id="doc-1", quote="12 AUG 2031")]),
        }
    )
    answer_question(llm, "Is my passport still valid?", _cards(), load_texts=lambda ids: {i: PASSPORT_TEXT for i in ids},
                    today=date(2026, 11, 21))
    router, answer = llm.calls
    assert router.system.endswith("Today's date: 2026-11-21.")
    assert answer.system.endswith("Today's date: 2026-11-21.")
    assert router.prompt.startswith("Document cards (JSON):")
    assert router.prompt.endswith("Current question: Is my passport still valid?")


def test_chat_not_found_is_in_the_language_of_the_question():
    llm = FakeLLMClient(responses={RouteDecision: RouteDecision(document_ids=[])})
    assert answer_question(llm, "Який у мене номер полісу?", _cards(), load_texts=lambda ids: {}).answer == NOT_FOUND_UK
    assert answer_question(llm, "What is my policy number?", _cards(), load_texts=lambda ids: {}).answer == NOT_FOUND


def test_document_bound_chat_skips_router():
    llm = FakeLLMClient(
        responses={ChatAnswer: ChatAnswer(found=True, answer="12 AUG 2031 [1]",
                                          citations=[Citation(document_id="doc-1", quote="12 AUG 2031")])}
    )
    result = answer_question(llm, "When?", _cards(), load_texts=lambda ids: {i: PASSPORT_TEXT for i in ids},
                             document_bound=True)
    assert [c.role for c in llm.calls] == [ModelRole.MAIN]
    assert result.found and result.routed_document_ids == ["doc-1"]


def test_history_answers_are_sent_without_citation_markers():
    llm = FakeLLMClient(responses={RouteDecision: RouteDecision(document_ids=[])})
    answer_question(llm, "And the holder?", _cards(), load_texts=lambda ids: {},
                    history=[Turn("When does it expire?", "It expires 12 AUG 2031 [1][2].")])
    assert "Assistant: It expires 12 AUG 2031." in llm.calls[0].prompt


def test_large_vault_is_prefiltered_before_routing():
    filler = SummaryCard(title="Electric bill", holder=None, issuer="Power Co", key_facts=["total due 80.00"],
                         topics=["electricity"])
    cards = [DocCard(f"bill-{i}", "utility_bill", None, filler) for i in range(MAX_ROUTER_CARDS + 10)]
    cards.insert(0, _cards()[0])  # the oldest card: only kept because it matches the question
    llm = FakeLLMClient(responses={RouteDecision: RouteDecision(document_ids=[])})
    answer_question(llm, "When does my passport expire?", cards, load_texts=lambda ids: {})
    prompt = llm.calls[0].prompt
    assert prompt.count('"id": ') == MAX_ROUTER_CARDS
    assert '"id": "doc-1"' in prompt
