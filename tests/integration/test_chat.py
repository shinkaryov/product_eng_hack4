"""Chat messages through the API with a fake LLM, on documents processed by the worker."""

import re

from tests.integration.test_worker_pipeline import (  # noqa: F401
    PDF,
    _insurance_llm,
    _run_worker,
    _upload,
    api,
)
from vault.ai.schemas import ChatAnswer, Citation, RouteDecision
from vault.chat_messages import get_llm
from vault.llm import LLMUnavailable
from vault.llm.fake import FakeLLMClient
from vault.main import app


def _ids_in(prompt: str) -> list[str]:
    return re.findall(r'"id": "([0-9a-f-]{36})"', prompt)


def _chat_llm(*, route=True, quote="Collision deductible: $500.00") -> FakeLLMClient:
    def answer(call):
        doc_id = re.search(r'<document id="([0-9a-f-]{36})">', call.prompt).group(1)
        return ChatAnswer(found=True, answer="Your collision deductible is $500.00 [1].",
                          citations=[Citation(document_id=doc_id, quote=quote)])

    return FakeLLMClient(responses={
        RouteDecision: lambda call: RouteDecision(
            standalone_question="When does my auto policy expire?" if "Recent conversation" in call.prompt else "",
            document_ids=_ids_in(call.prompt) if route else [],
        ),
        ChatAnswer: answer,
    })


def _use(llm):
    app.dependency_overrides[get_llm] = lambda: llm


def _processed_doc(client) -> str:
    doc_id = _upload(client, "policy.pdf", PDF, "application/pdf")
    _run_worker(_insurance_llm())
    return doc_id


def test_vault_chat_answers_with_citation_and_keeps_history(api):  # noqa: F811
    doc_id = _processed_doc(api)
    llm = _chat_llm()
    _use(llm)
    try:
        session = api.post("/v1/chat", json={}).json()
        assert session["document_id"] is None

        r = api.post(f"/v1/chat/{session['id']}/messages", json={"message": "What is my collision deductible?"})
        assert r.status_code == 201, r.text
        turn = r.json()
        assert turn["answer_status"] == "ANSWERED" and "$500.00" in turn["answer"]
        assert turn["routed_document_ids"] == [doc_id]
        [source] = turn["citations"]
        assert source["n"] == 1 and source["document_id"] == doc_id
        assert source["quote"] == "Collision deductible: $500.00"
        assert source["document_title"] and source["category"]
        assert turn["answer"].endswith("[1].")
        assert turn["turn_number"] == 1

        r = api.post(f"/v1/chat/{session['id']}/messages", json={"message": "And when does it expire?"})
        router_call, answer_call = llm.calls[-2], llm.calls[-1]
        assert "What is my collision deductible?" in router_call.prompt  # follow-up sees history
        assert f'Documents used in the previous answer: ["{doc_id}"]' in router_call.prompt
        assert "Question: When does my auto policy expire?" in answer_call.prompt
        assert r.json()["standalone_question"] == "When does my auto policy expire?"

        history = api.get(f"/v1/chat/{session['id']}").json()
        assert [t["turn_number"] for t in history["turns"]] == [1, 2]
        assert [s["id"] for s in api.get("/v1/chat").json()] == [session["id"]]
    finally:
        app.dependency_overrides.clear()


def test_unverifiable_or_unrouted_answers_are_not_found(api):  # noqa: F811
    _processed_doc(api)
    session = api.post("/v1/chat", json={}).json()["id"]
    try:
        _use(_chat_llm(route=False))
        r = api.post(f"/v1/chat/{session}/messages", json={"message": "What is my dentist's phone?"}).json()
        assert r["answer_status"] == "INSUFFICIENT_INFORMATION" and r["routed_document_ids"] == []

        _use(_chat_llm(quote="Collision deductible: $50.00"))  # quote not in the document
        r = api.post(f"/v1/chat/{session}/messages", json={"message": "Deductible?"}).json()
        assert r["answer_status"] == "INSUFFICIENT_INFORMATION" and r["citations"] == []
    finally:
        app.dependency_overrides.clear()


def test_document_bound_chat_and_provider_outage(api):  # noqa: F811
    doc_id = _processed_doc(api)
    session = api.post(f"/v1/documents/{doc_id}/chat", json={}).json()["id"]

    class Down:
        provider = "down"

        def generate_json(self, **_):
            raise LLMUnavailable("503")

    try:
        _use(Down())
        assert api.post(f"/v1/chat/{session}/messages", json={"message": "Deductible?"}).status_code == 503
        assert api.get(f"/v1/chat/{session}").json()["turns"] == []

        _use(_chat_llm())
        turn = api.post(f"/v1/chat/{session}/messages", json={"message": "Deductible?"}).json()
        assert turn["answer_status"] == "ANSWERED" and turn["source_revision"] == 1
    finally:
        app.dependency_overrides.clear()


def test_chat_without_processed_documents(api):  # noqa: F811
    session = api.post("/v1/chat", json={}).json()["id"]
    _use(_chat_llm())
    try:
        assert api.post(f"/v1/chat/{session}/messages", json={"message": "Anything?"}).status_code == 409
        assert api.post(f"/v1/chat/{session}/messages", json={"message": "   "}).status_code == 422
    finally:
        app.dependency_overrides.clear()
