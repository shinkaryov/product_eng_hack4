"""Upload through the API, process with the worker (fake LLM), read results through the API.

Runs against the test database (see tests/conftest.py). Each test registers a fresh
user and deletes its rows afterwards.
"""

import uuid
from datetime import date, timedelta

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import text
from sqlalchemy.exc import OperationalError

from vault import local_auth
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
from vault.config import get_settings
from vault.db import SessionLocal, engine
from vault.llm import LLMUnavailable
from vault.llm.fake import FakeLLMClient
from vault.services import processing

PDF = b"%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF"
PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 16
TEXT = (
    "ACME Auto Insurance\nPolicy number: AU-778812\nPolicy period: 2026-01-01 to 2026-12-31\n"
    "Collision deductible: $500.00\nThis policy expires on December 31, 2026."
)


def _insurance_llm() -> FakeLLMClient:
    return FakeLLMClient(responses={
        Classification: Classification(doc_type=DocType.AUTO_INSURANCE, confidence=0.95, reason="insurer logo"),
        Extraction: Extraction(
            full_text=TEXT,
            identifiers=[
                DocumentFact(name="policy_number", value="AU-778812", quote="Policy number: AU-778812"),
                DocumentFact(name="vin", value="1HGCM82633A004352", quote="VIN 1HGCM82633A004352"),  # hallucinated
            ],
            terms=[DocumentFact(name="policy_period", value="2026-01-01 to 2026-12-31",
                                quote="Policy period: 2026-01-01 to 2026-12-31")],
            financials=[MoneyFact(name="collision_deductible", amount="500.00", currency="USD", period=None,
                                  quote="Collision deductible: $500.00")],
            expires_on="2026-12-31",
            expires_on_quote="This policy expires on December 31, 2026.",
            summary=SummaryCard(title="ACME auto insurance policy", holder=None, issuer="ACME",
                                key_facts=["Collision deductible $500.00"], topics=["auto", "deductible"]),
        ),
    })


@pytest.fixture
def api(tmp_path, monkeypatch):
    try:
        engine.connect().close()
    except OperationalError:
        pytest.skip("Postgres is not running")
    monkeypatch.setenv("FILES_DIR", str(tmp_path))
    if len(get_settings().jwt_secret) < 32:
        monkeypatch.setenv("JWT_SECRET", "t" * 48)
    get_settings.cache_clear()
    from vault.main import app

    local_auth.attempts.clear()  # many registrations per test run would hit the auth rate limit
    client = TestClient(app)
    login = {"email": f"{uuid.uuid4().hex}@example.test", "password": uuid.uuid4().hex}
    assert client.post("/v1/auth/register", json=login).status_code == 201
    token = client.post("/v1/auth/login", json=login).json()["access_token"]
    client.headers["Authorization"] = f"Bearer {token}"
    client.files_dir = tmp_path

    yield client

    with engine.begin() as conn:
        conn.execute(text("DELETE FROM vault.documents WHERE owner_id IN (SELECT id FROM vault.users WHERE email = :e)"),
                     {"e": login["email"]})
        conn.execute(text("DELETE FROM vault.users WHERE email = :e"), {"e": login["email"]})
    get_settings.cache_clear()


def _upload(client, name, data, mime):
    r = client.post("/v1/documents", files={"file": (name, data, mime)})
    assert r.status_code == 202, r.text
    return r.json()["id"]


def _run_worker(llm) -> bool:
    with SessionLocal() as s:
        return processing.process_next_job(s, llm)


def _stored_files(client):
    return [p for p in client.files_dir.iterdir() if p.is_file() and not p.name.startswith(".")]


def _use_llm(monkeypatch, llm):
    from vault.chat_messages import get_llm
    from vault.main import app

    monkeypatch.setitem(app.dependency_overrides, get_llm, lambda: llm)


def _chat_llm(doc_id, response=None):
    return FakeLLMClient(responses={
        RouteDecision: RouteDecision(document_ids=[doc_id]),
        ChatAnswer: response or ChatAnswer(
            found=True, answer="The deductible is $500.",
            citations=[Citation(document_id=doc_id, quote="Collision deductible: $500.00")],
        ),
    })


@pytest.fixture
def household(api):
    from vault.main import app

    viewer = TestClient(app)
    login = {"email": f"{uuid.uuid4().hex}@example.test", "password": uuid.uuid4().hex}
    user = viewer.post("/v1/auth/register", json=login).json()
    viewer.headers["Authorization"] = "Bearer " + viewer.post("/v1/auth/login", json=login).json()["access_token"]
    family = api.post("/v1/families", json={"name": "Test household"}).json()
    try:
        invite = api.post("/v1/families/invitations", json={"email": login["email"]}).json()
        response = viewer.post(f"/v1/families/invitations/{invite['id']}/respond", json={
            "secret": invite["secret"], "decision": "accept",
        })
        assert response.status_code == 200, response.text
        yield viewer, family["id"]
    finally:
        with engine.begin() as conn:
            conn.execute(text("DELETE FROM vault.families WHERE id=:id"), {"id": family["id"]})
            conn.execute(text("DELETE FROM vault.users WHERE id=:id"), {"id": user["id"]})


def test_worker_publishes_summary_extraction_and_deadline(api):
    doc_id = _upload(api, "scan.pdf", PDF, "application/pdf")
    llm = _insurance_llm()
    assert _run_worker(llm) is True
    assert llm.calls[0].attachments[0].data == PDF  # Gemini gets the original file, no local OCR

    doc = api.get(f"/v1/documents/{doc_id}").json()
    assert doc["processing_stage"] == "COMPLETED"
    assert doc["review_status"] == "REVIEW_REQUIRED"
    assert doc["category"] == "AUTO_INSURANCE"
    assert doc["title"] == "ACME auto insurance policy"
    assert doc["policy_outcome"] == "ALLOWED"

    summary = api.get(f"/v1/documents/{doc_id}/summary").json()
    assert summary["card"]["issuer"] == "ACME"

    ext = api.get(f"/v1/documents/{doc_id}/extraction").json()
    assert [f["name"] for f in ext["identifiers"]] == ["policy_number"]  # hallucinated VIN dropped
    assert ext["facts"]["needs_review"] is True
    assert ext["pages"][0]["text"] == TEXT

    deadlines = api.get(f"/v1/documents/{doc_id}/deadlines").json()
    assert [(d["kind"], d["due_on"], d["state"]) for d in deadlines] == [("INSURANCE_EXPIRATION", "2026-12-31", "PROPOSED")]


def test_blocked_document_stays_visible_without_file(api):
    doc_id = _upload(api, "card.png", PNG, "image/png")
    llm = FakeLLMClient(responses={
        Classification: Classification(doc_type=DocType.BANK_CARD_OR_CHECK, confidence=0.9, reason="card number"),
    })
    _run_worker(llm)
    assert len(llm.calls) == 1  # extraction never ran

    doc = api.get(f"/v1/documents/{doc_id}").json()
    assert doc["review_status"] == "BLOCKED" and doc["policy_outcome"] == "BLOCKED" and doc["policy_reason"]
    assert doc["display_filename"] is None
    assert api.get(f"/v1/documents/{doc_id}/file").status_code == 404
    assert api.post(f"/v1/documents/{doc_id}/reprocess").status_code == 409

    with SessionLocal() as s:
        processing.cleanup_files(s)
    assert _stored_files(api) == []


def test_utility_due_date_and_owner_deadline_timeline(api, household):
    viewer, family_id = household
    doc_id = _upload(api, "utility.pdf", PDF, "application/pdf")
    path = f"/v1/documents/{doc_id}"
    due = (date.today() + timedelta(days=20)).isoformat()
    quote = f"Payment due: {due}"
    llm = _insurance_llm()
    llm.responses[Classification] = Classification(doc_type=DocType.UTILITY_BILL, confidence=0.98, reason="utility bill")
    llm.responses[Extraction] = Extraction(
        full_text=f"ACME Energy\nStatement date: 2026-11-01\n{quote}", identifiers=[], terms=[], financials=[],
        expires_on=None, expires_on_quote=None, payment_due_on=due, payment_due_on_quote=quote,
        summary=SummaryCard(title="ACME utility bill", holder=None, issuer="ACME", key_facts=[], topics=[]),
    )
    assert _run_worker(llm)
    assert api.get(path + "/extraction").json()["facts"]["payment_due_on"] == due
    deadline, = api.get(path + "/deadlines").json()
    assert (deadline["kind"], deadline["due_on"], deadline["state"]) == ("PAYMENT_DUE", due, "PROPOSED")
    assert deadline["evidence"] == {"quote": quote}
    assert api.get("/v1/deadlines").json() == []

    response = api.patch(path + f"/deadlines/{deadline['id']}", json={"state": "CONFIRMED"})
    assert response.status_code == 200, response.text
    reminder = api.get("/v1/reminders").json()[0]
    assert api.post(f"/v1/reminders/{reminder['id']}/dismiss").status_code == 200
    assert api.post(path + "/shares", json={"family_id": family_id}).status_code == 200
    assert viewer.get(path + "/deadlines").status_code == 200
    assert viewer.get("/v1/deadlines").json() == []
    item, = api.get("/v1/deadlines").json()
    assert (item["id"], item["document_id"], item["document_title"], item["due_on"]) == (
        deadline["id"], doc_id, "ACME utility bill", due,
    )

    # Older workers applied the expiration key to utility bills. Preserve the owner's decision on reprocess.
    with engine.begin() as conn:
        conn.execute(text("UPDATE vault.document_deadlines SET candidate_key='expires_on' WHERE id=:id"), {
            "id": deadline["id"],
        })
    assert api.post(path + "/reprocess").status_code == 202
    assert _run_worker(llm)
    updated, = api.get(path + "/deadlines").json()
    assert (updated["id"], updated["state"], updated["candidate_key"]) == (
        deadline["id"], "CONFIRMED", "payment_due_on",
    )

    llm.responses[Extraction].payment_due_on_quote = "A quote missing from the bill"
    assert api.post(path + "/reprocess").status_code == 202
    assert _run_worker(llm)
    facts = api.get(path + "/extraction").json()["facts"]
    assert facts["payment_due_on"] is None and facts["needs_review"]
    assert "payment_due_on quote not found in document text" in facts["warnings"]


def test_confirm_checks_current_owner_and_both_revisions(api, household):
    viewer, family_id = household
    doc_id = _upload(api, "policy.pdf", PDF, "application/pdf")
    path = f"/v1/documents/{doc_id}"
    revisions = {"expected_result_revision": 1, "expected_extraction_revision": 1}
    assert api.post(path + "/confirm", json=revisions).status_code == 409
    assert _run_worker(_insurance_llm())
    assert api.post(path + "/shares", json={"family_id": family_id}).status_code == 200
    assert viewer.post(path + "/confirm", json=revisions).status_code == 403
    ready = api.post(path + "/confirm", json=revisions)
    assert ready.status_code == 200, ready.text
    assert ready.json()["review_status"] == "READY" and ready.json()["confirmed_at"]
    assert api.post(path + "/confirm", json=revisions).json() == ready.json()
    assert api.get(path + "/deadlines").json()[0]["state"] == "PROPOSED"

    response = api.patch(path + "/extraction", json={"expected_revision": 1, "fields": {"issuer": "Updated"}})
    assert response.status_code == 200, response.text
    assert api.get(path).json()["review_status"] == "REVIEW_REQUIRED"
    assert api.post(path + "/confirm", json=revisions).status_code == 409
    revisions["expected_extraction_revision"] = 2
    assert api.post(path + "/confirm", json=revisions).status_code == 200
    assert api.post(path + "/reprocess").json()["confirmed_at"] is None
    assert api.post(path + "/confirm", json=revisions).status_code == 409
    assert _run_worker(_insurance_llm())
    assert api.post(path + "/confirm", json=revisions).status_code == 409
    revisions["expected_result_revision"] = 2
    assert api.post(path + "/confirm", json=revisions).status_code == 200


def test_chat_turns_respect_current_share_access(api, household, monkeypatch):
    viewer, family_id = household
    doc_id = _upload(api, "policy.pdf", PDF, "application/pdf")
    assert _run_worker(_insurance_llm())
    doc_path = f"/v1/documents/{doc_id}"
    assert api.post(doc_path + "/shares", json={"family_id": family_id}).status_code == 200
    chat_id = viewer.post(doc_path + "/chat").json()["id"]
    path = f"/v1/chat/{chat_id}"
    question = {"message": "What is the deductible?"}
    llm = _chat_llm(doc_id)
    _use_llm(monkeypatch, llm)
    assert api.post(path + "/messages", json=question).status_code == 404
    assert viewer.post(path + "/messages", json={"message": "   "}).status_code == 422

    def unavailable(_call):
        raise LLMUnavailable("provider down")

    _use_llm(monkeypatch, _chat_llm(doc_id, response=unavailable))
    assert viewer.post(path + "/messages", json=question).status_code == 503
    _use_llm(monkeypatch, llm)
    result = viewer.post(path + "/messages", json=question)
    assert result.status_code == 201, result.text
    turn = {k: v for k, v in result.json().items() if k not in ("standalone_question", "usage")}  # response-only
    assert (turn["turn_number"], turn["answer_status"], turn["source_revision"]) == (1, "ANSWERED", 1)
    assert [(c["n"], c["document_id"], c["quote"]) for c in turn["citations"]] == [
        (1, doc_id, "Collision deductible: $500.00")
    ]
    assert viewer.get(path).json()["turns"] == [turn]

    def revoke_during_inference(_call):
        assert api.delete(doc_path + "/shares").status_code == 204
        return llm.responses[ChatAnswer]

    _use_llm(monkeypatch, _chat_llm(doc_id, response=revoke_during_inference))
    assert viewer.post(path + "/messages", json=question).status_code == 404
    assert viewer.get(path).status_code == 404
    assert api.post(doc_path + "/shares", json={"family_id": family_id}).status_code == 200
    assert viewer.get(path).json()["turns"] == [turn]

    def republish_during_inference(_call):
        assert api.post(doc_path + "/reprocess").status_code == 202
        assert _run_worker(_insurance_llm())
        return llm.responses[ChatAnswer]

    _use_llm(monkeypatch, _chat_llm(doc_id, response=republish_during_inference))
    assert viewer.post(path + "/messages", json=question).status_code == 409
    assert viewer.get(path).json()["turns"] == [turn]


def test_reprocessing_as_blocked_purges_published_data(api, monkeypatch):
    doc_id = _upload(api, "policy.pdf", PDF, "application/pdf")
    assert _run_worker(_insurance_llm())
    path = f"/v1/documents/{doc_id}"
    due = (date.today() + timedelta(days=20)).isoformat()
    assert api.post(path + "/deadlines", json={"type": "OTHER", "date": due}).status_code == 201
    assert api.get("/v1/reminders").json()
    chat_id = api.post(path + "/chat").json()["id"]
    _use_llm(monkeypatch, _chat_llm(doc_id))
    assert api.post(f"/v1/chat/{chat_id}/messages", json={"message": "Deductible?"}).status_code == 201

    assert api.post(path + "/reprocess").status_code == 202
    assert _run_worker(FakeLLMClient(responses={
        Classification: Classification(doc_type=DocType.BANK_CARD_OR_CHECK, confidence=0.95, reason="bank card"),
    }))
    assert api.get(path).json()["title"] == "Blocked document"
    assert api.get("/v1/deadlines").json() == []
    assert api.get("/v1/reminders").json() == []
    assert api.get(f"/v1/chat/{chat_id}").status_code == 404
    with SessionLocal() as session:
        for table in ("document_extractions", "document_summaries", "document_deadlines", "chat_sessions"):
            assert session.execute(text(f"SELECT 1 FROM vault.{table} WHERE document_id=:id"), {"id": doc_id}).first() is None
        session.rollback()
        processing.cleanup_files(session)
    assert _stored_files(api) == []


def test_provider_outage_retries_then_fails(api):
    doc_id = _upload(api, "a.pdf", PDF, "application/pdf")

    class Down:
        provider = "down"

        def generate_json(self, **_):
            raise LLMUnavailable("503")

    for attempt in range(1, processing.MAX_ATTEMPTS + 1):
        with engine.begin() as conn:  # skip the backoff wait
            conn.execute(text("UPDATE vault.processing_jobs SET available_at = now() WHERE document_id = :d"), {"d": doc_id})
        assert _run_worker(Down())
        doc = api.get(f"/v1/documents/{doc_id}").json()
        assert doc["error_code"] == "LLMUnavailable"
        assert doc["processing_stage"] == ("FAILED" if attempt == processing.MAX_ATTEMPTS else "PENDING")

    assert api.post(f"/v1/documents/{doc_id}/reprocess").json()["processing_stage"] == "PENDING"
    assert _run_worker(_insurance_llm())
    assert api.get(f"/v1/documents/{doc_id}").json()["review_status"] == "REVIEW_REQUIRED"


def test_delete_cleans_up_file(api):
    doc_id = _upload(api, "a.pdf", PDF, "application/pdf")
    assert len(_stored_files(api)) == 1
    assert api.delete(f"/v1/documents/{doc_id}").status_code == 204
    with SessionLocal() as s:
        processing.cleanup_files(s)
    assert _stored_files(api) == []


def test_iphone_heic_photo_is_accepted_and_sent_to_gemini(api):
    heic = b"\x00\x00\x00\x18ftypheic\x00\x00\x00\x00mif1heic" + b"\x00" * 32
    # Browsers often send HEIC without a specific media type; the signature decides.
    doc_id = _upload(api, "IMG_0042.HEIC", heic, "application/octet-stream")
    assert api.get(f"/v1/documents/{doc_id}").json()["media_type"] == "image/heic"

    llm = _insurance_llm()
    _run_worker(llm)
    assert llm.calls[0].attachments[0].mime_type == "image/heic"

    heif = b"\x00\x00\x00\x18ftypmif1\x00\x00\x00\x00mif1" + b"\x00" * 32
    assert api.get(f"/v1/documents/{_upload(api, 'scan.heif', heif, 'image/heif')}").json()["media_type"] == "image/heif"
    r = api.post("/v1/documents", files={"file": ("fake.heic", b"\xff\xd8\xff" + b"\x00" * 40, "image/heic")})
    assert r.status_code == 415
