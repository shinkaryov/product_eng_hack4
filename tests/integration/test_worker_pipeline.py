"""Upload through the API, process with the worker (fake LLM), read results through the API.

Runs against the test database (see tests/conftest.py). Each test registers a fresh
user and deletes its rows afterwards.
"""

import uuid

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import text
from sqlalchemy.exc import OperationalError

from vault.ai.schemas import (
    Classification,
    DocType,
    DocumentFact,
    Extraction,
    MoneyFact,
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
