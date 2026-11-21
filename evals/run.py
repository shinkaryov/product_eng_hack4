"""Run the AI evals against the configured LLM provider (Gemini by default).

    uv run python -m evals.run            # analyze all documents, then chat questions
    uv run python -m evals.run --reuse    # reuse cached document analysis, rerun chat only
    uv run python -m evals.run --set realistic   # photos (CORD receipts + generated) + photo chat questions
    uv run python -m evals.run --reuse --new     # only new docs + hard questions (results/hard.*)

Writes evals/results/latest.json and evals/results/latest.md. Rendered files and the
analysis cache live in evals/.cache (git-ignored). PNG "scans" are made with macOS `sips`.
"""

import argparse
import json
import re
import subprocess
import sys
import time
from datetime import UTC, datetime
from pathlib import Path

from evals import realistic
from evals.cases import DOCS, HARD_QUESTIONS, QUESTIONS
from vault.ai import prompts
from vault.ai.analyze import analyze_document
from vault.ai.chat import DocCard, answer_question
from vault.ai.policy import block_reason
from vault.ai.schemas import DocType
from vault.ai.text import validated_date
from vault.config import get_settings
from vault.llm import LLMError, UsageLog, get_llm_client
from vault.services.processing import PAYMENT_TYPES

ROOT = Path(__file__).parent
CACHE = ROOT / ".cache"
RESULTS = ROOT / "results"

# Gemini 3.5 Flash-Lite paid tier, USD per 1M tokens (verify on ai.google.dev/pricing).
PRICE_IN = 0.30
PRICE_OUT = 2.50


def cost(usage: UsageLog) -> float:
    return usage.input_tokens / 1e6 * PRICE_IN + usage.output_tokens / 1e6 * PRICE_OUT


class Paced:
    """Wraps an LLM client: spaces calls to stay under the free-tier rate limit and waits out 429s."""

    def __init__(self, llm, rpm: float) -> None:
        self._llm, self._gap, self._last = llm, 60.0 / rpm, 0.0
        self.provider = llm.provider

    def generate_json(self, **kwargs):
        from vault.llm import LLMUnavailable

        for attempt in range(4):
            wait = self._gap - (time.monotonic() - self._last)
            if wait > 0:
                time.sleep(wait)
            self._last = time.monotonic()
            try:
                return self._llm.generate_json(**kwargs)
            except LLMUnavailable:
                if attempt == 3:
                    raise
                print("rate limited, waiting 30s", file=sys.stderr)
                time.sleep(30)


# --- Rendering ----------------------------------------------------------------


def render_pdf(lines: list[str]) -> bytes:
    """Minimal one-page PDF with Helvetica text (Latin-1 only)."""

    def esc(line: str) -> str:
        return line.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")

    stream = "\n".join(["1 1 1 rg 0 0 612 842 re f 0 0 0 rg BT /F1 12 Tf 50 780 Td 16 TL"] + [f"({esc(l)}) Tj T*" for l in lines] + ["ET"])
    body = stream.encode("latin-1")
    objs = [
        b"<</Type/Catalog/Pages 2 0 R>>",
        b"<</Type/Pages/Kids[3 0 R]/Count 1>>",
        b"<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 842]/Resources<</Font<</F1 4 0 R>>>>/Contents 5 0 R>>",
        b"<</Type/Font/Subtype/Type1/BaseFont/Helvetica/Encoding/WinAnsiEncoding>>",
        b"<</Length %d>>stream\n" % len(body) + body + b"\nendstream",
    ]
    out, offsets = bytearray(b"%PDF-1.4\n"), []
    for i, obj in enumerate(objs, 1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % i + obj + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
    out += b"".join(b"%010d 00000 n \n" % o for o in offsets)
    out += b"trailer<</Size %d/Root 1 0 R>>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
    return bytes(out)


MIME = {b"\x89PNG": "image/png", b"\xff\xd8\xff": "image/jpeg"}


def render(case: dict) -> tuple[bytes, str]:
    CACHE.mkdir(exist_ok=True)
    if case.get("file"):
        data = (ROOT / "realistic" / case["file"]).read_bytes()
        return data, next(m for sig, m in MIME.items() if data.startswith(sig))
    pdf = render_pdf(case["lines"])
    if not case.get("image"):
        return pdf, "application/pdf"
    pdf_path, png_path = CACHE / f"{case['id']}.pdf", CACHE / f"{case['id']}.png"
    pdf_path.write_bytes(pdf)
    subprocess.run(["sips", "-s", "format", "png", str(pdf_path), "--out", str(png_path)], check=True, capture_output=True)
    return png_path.read_bytes(), "image/png"


# --- Document analysis --------------------------------------------------------


def _digits(s: str) -> str:
    return re.sub(r"[^0-9a-z]", "", s.lower())


def evaluate_doc(llm, case: dict) -> dict:
    data, mime = render(case)
    expected_blocked = block_reason(DocType(case["doc_type"])) is not None
    row = {"id": case["id"], "tags": case["tags"], "mime": mime, "expected_type": case["doc_type"],
           "expected_blocked": expected_blocked, "expected_expires_on": case["expires_on"]}
    started = time.monotonic()
    try:
        result = analyze_document(llm, data, mime)
    except LLMError as exc:
        row.update(error=f"{type(exc).__name__}: {exc}", latency_ms=int((time.monotonic() - started) * 1000))
        return row
    # Model time only: excludes the pacing sleeps added for the free-tier rate limit.
    row["latency_ms"] = sum(u.latency_ms for u in result.usage.calls)
    row["predicted_type"] = result.classification.doc_type.value
    row["confidence"] = result.classification.confidence
    row["blocked"] = result.blocked
    row["tokens_in"], row["tokens_out"] = result.usage.input_tokens, result.usage.output_tokens
    row["cost_usd"] = cost(result.usage)
    ext = result.extraction
    if ext is None:
        return row
    deadline = result.expires_on
    if result.classification.doc_type in PAYMENT_TYPES:
        # Same rule as the worker: a bill's key deadline is its validated payment due date.
        due = validated_date("payment_due_on", ext.payment_due_on, ext.payment_due_on_quote, ext.full_text, result.warnings)
        deadline = due or deadline
    row["expires_on"] = deadline.isoformat() if deadline else None
    row["warnings"] = result.warnings
    row["needs_review"] = result.needs_review
    extracted = [f.value for f in ext.identifiers + ext.terms] + [m.amount for m in ext.financials]
    blob = " | ".join(extracted + [f.quote for f in ext.identifiers + ext.terms] + [m.quote for m in ext.financials])
    row["facts_found"] = [f for f in case["facts"] if _digits(f) in _digits(blob)]
    row["facts_missing"] = [f for f in case["facts"] if f not in row["facts_found"]]
    card_text = ext.summary.model_dump_json()
    row["card_leaks"] = [s for s in case["secrets"] if _digits(s) in _digits(card_text)]
    row["card"] = ext.summary.model_dump()
    row["full_text"] = ext.full_text
    return row


# --- Chat ---------------------------------------------------------------------


def evaluate_questions(llm, doc_rows: list[dict], questions=QUESTIONS, hard: bool = False) -> list[dict]:
    published = [r for r in doc_rows if r.get("card")]
    cards = [DocCard(r["id"], r["predicted_type"], r.get("expires_on"), _card(r["card"])) for r in published]
    texts = {r["id"]: r["full_text"] for r in published}
    rows = []
    for question, expected, needle in questions:
        try:
            res = answer_question(llm, question, cards, lambda ids: {i: texts[i] for i in ids})
        except LLMError as exc:
            rows.append({"question": question, "expected": expected, "hard": hard, "error": f"{type(exc).__name__}: {exc}"})
            continue
        routed = res.routed_document_ids
        row = {"question": question, "hard": hard, "expected": expected, "routed": routed, "found": res.found, "answer": res.answer,
               "citations": len(res.citations), "dropped_citations": res.dropped_citations,
               "latency_ms": sum(u.latency_ms for u in res.usage.calls), "cost_usd": cost(res.usage),
               "tokens_in": res.usage.input_tokens, "tokens_out": res.usage.output_tokens}
        if expected:
            row["router_recall"] = len(set(expected) & set(routed)) / len(expected)
            if needle is not None:
                row["answer_ok"] = res.found and _answer_matches(needle, res.answer)
        else:
            row["abstained"] = not res.found  # unanswerable: must not claim an answer
        rows.append(row)
    return rows


def _answer_matches(needle: str | list[str] | tuple[str, ...], answer: str) -> bool:
    """str: must appear; list: all must appear; tuple: any one must appear (alternative spellings)."""
    hit = lambda n: _digits(n) in _digits(answer)  # noqa: E731
    if isinstance(needle, tuple):
        return any(hit(n) for n in needle)
    if isinstance(needle, list):
        return all(hit(n) for n in needle)
    return hit(needle)


def _card(data: dict):
    from vault.ai.schemas import SummaryCard

    return SummaryCard.model_validate(data)


# --- Report -------------------------------------------------------------------


def _pct(num: int, den: int) -> str:
    return f"{num}/{den} ({num / den:.0%})" if den else "n/a"


def summarize(docs: list[dict], all_qs: list[dict]) -> dict:
    qs = [q for q in all_qs if not q.get("hard")]
    hard = [q for q in all_qs if q.get("hard")]
    hard_routed = [q for q in hard if "router_recall" in q]
    hard_answered = [q for q in hard if "answer_ok" in q]
    ok = [d for d in docs if "error" not in d]
    allowed = [d for d in ok if not d["expected_blocked"]]
    extracted = [d for d in allowed if "facts_found" in d]
    facts_total = sum(len(d["facts_found"]) + len(d["facts_missing"]) for d in extracted)
    routed = [q for q in qs if "router_recall" in q]
    answered = [q for q in qs if "answer_ok" in q]
    unans = [q for q in qs if "abstained" in q]
    doc_cost = [d["cost_usd"] for d in ok if "cost_usd" in d]
    q_cost = [q["cost_usd"] for q in all_qs if "cost_usd" in q]
    return {
        "documents": len(docs),
        "errors": len(docs) - len(ok) + sum(1 for q in all_qs if "error" in q),
        "classification_accuracy": _pct(sum(d["predicted_type"] == d["expected_type"] for d in ok), len(ok)),
        "blacklist_recall": _pct(sum(d["blocked"] for d in ok if d["expected_blocked"]), sum(d["expected_blocked"] for d in ok)),
        "false_blocks": _pct(sum(d["blocked"] for d in allowed), len(allowed)),
        "expiry_exact": _pct(sum(d.get("expires_on") == d["expected_expires_on"] for d in extracted), len(extracted)),
        "expiry_invented_when_none": _pct(sum(d["expected_expires_on"] is None and d.get("expires_on") is not None for d in extracted),
                                          sum(d["expected_expires_on"] is None for d in extracted)),
        "fact_recall": _pct(sum(len(d["facts_found"]) for d in extracted), facts_total),
        "facts_dropped_by_verifier": sum(int(re.search(r"dropped (\d+)", w).group(1)) for d in extracted for w in d["warnings"] if w.startswith("dropped")),
        "card_redaction_leaks": _pct(sum(bool(d["card_leaks"]) for d in extracted), len(extracted)),
        "injection_resisted": _pct(sum(d["predicted_type"] == d["expected_type"] and d.get("expires_on") is None
                                       for d in ok if "injection" in d["tags"]), sum("injection" in d["tags"] for d in ok)),
        "router_recall_at_3": f"{sum(q['router_recall'] for q in routed) / len(routed):.0%} over {len(routed)} questions" if routed else "n/a",
        "answer_accuracy": _pct(sum(q["answer_ok"] for q in answered), len(answered)),
        "unanswerable_abstained": _pct(sum(q["abstained"] for q in unans), len(unans)),
        "hard_router_recall": f"{sum(q['router_recall'] for q in hard_routed) / len(hard_routed):.0%} over {len(hard_routed)} questions" if hard_routed else "n/a",
        "hard_answer_accuracy": _pct(sum(q["answer_ok"] for q in hard_answered), len(hard_answered)),
        "avg_doc_cost_usd": round(sum(doc_cost) / len(doc_cost), 6) if doc_cost else None,
        "avg_question_cost_usd": round(sum(q_cost) / len(q_cost), 6) if q_cost else None,
        "avg_doc_latency_ms": int(sum(d["latency_ms"] for d in ok) / len(ok)) if ok else None,
    }


def failures(docs: list[dict], qs: list[dict]) -> list[str]:
    out = []
    for d in docs:
        if "error" in d:
            out.append(f"doc `{d['id']}`: error {d['error']}")
            continue
        if d["predicted_type"] != d["expected_type"]:
            out.append(f"doc `{d['id']}`: type {d['predicted_type']} (expected {d['expected_type']})")
        if d["expected_blocked"] != d["blocked"]:
            out.append(f"doc `{d['id']}`: blocked={d['blocked']} (expected {d['expected_blocked']})")
        if "facts_found" in d:
            if d.get("expires_on") != d["expected_expires_on"]:
                out.append(f"doc `{d['id']}`: expires_on {d.get('expires_on')} (expected {d['expected_expires_on']}); warnings {d['warnings']}")
            if d["facts_missing"]:
                out.append(f"doc `{d['id']}`: missing facts {d['facts_missing']}")
            if d["card_leaks"]:
                out.append(f"doc `{d['id']}`: card leaks {d['card_leaks']}")
    for q in qs:
        tag = "[hard] " if q.get("hard") else ""
        if "error" in q:
            out.append(f"{tag}question \"{q['question']}\": error {q['error']}")
        elif q.get("router_recall", 1) < 1:
            out.append(f"{tag}question \"{q['question']}\": routed {q['routed']} (expected {q['expected']})")
        if q.get("answer_ok") is False:
            out.append(f"{tag}question \"{q['question']}\": answer \"{q['answer']}\"")
        elif q.get("abstained") is False:
            out.append(f"{tag}question \"{q['question']}\": should be not found, answered \"{q['answer']}\"")
    return out


def write_report(summary: dict, docs: list[dict], qs: list[dict], model: str, name: str = "latest", label: str = "synthetic") -> None:
    RESULTS.mkdir(exist_ok=True)
    meta = {"run_at": datetime.now(UTC).isoformat(timespec="seconds"), "model": model, "prompt_version": prompts.PROMPT_VERSION}
    slim_docs = [{k: v for k, v in d.items() if k not in ("full_text",)} for d in docs]
    (RESULTS / f"{name}.json").write_text(json.dumps({**meta, "summary": summary, "documents": slim_docs, "questions": qs},
                                                    indent=2, ensure_ascii=False))
    lines = ["# Eval results", "", f"Run {meta['run_at']}, model `{model}`, prompts `{meta['prompt_version']}`.",
             f"{len(docs)} {label} documents, {len(qs)} chat questions.", "", "| Metric | Result |", "|---|---|"]
    lines += [f"| {k} | {v} |" for k, v in summary.items()]
    lines += ["", "## Failures", ""] + ([f"- {f}" for f in failures(docs, qs)] or ["None."])
    (RESULTS / f"{name}.md").write_text("\n".join(lines) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--reuse", action="store_true", help="reuse cached analysis; analyze only documents missing from it")
    parser.add_argument("--new", action="store_true", help="synthetic: run only HARD_QUESTIONS, report to results/hard.*")
    parser.add_argument("--only", help="comma-separated document case ids")
    parser.add_argument("--set", choices=["synthetic", "realistic"], default="synthetic")
    parser.add_argument("--rpm", type=float, default=12, help="max model calls per minute")
    args = parser.parse_args()
    llm = Paced(get_llm_client(), args.rpm)
    settings = get_settings()
    model = f"{settings.gemini_model} (main), {settings.gemini_router_model} (router)" if llm.provider == "gemini" else llm.provider
    real = args.set == "realistic"
    all_cases, questions = (realistic.docs(), realistic.QUESTIONS) if real else (DOCS, QUESTIONS)
    cache_file = CACHE / ("analysis-realistic.json" if real else "analysis.json")

    cases = [c for c in all_cases if not args.only or c["id"] in args.only.split(",")]
    if args.only:
        cache_file = CACHE / "analysis-partial.json"
    cached = {d["id"]: d for d in json.loads(cache_file.read_text())} if args.reuse and cache_file.exists() else {}
    docs = []
    for case in cases:
        if case["id"] in cached and "error" not in cached[case["id"]]:
            docs.append(cached[case["id"]])
            continue
        row = evaluate_doc(llm, case)
        print(f"{case['id']:<18} {row.get('predicted_type', row.get('error'))}", file=sys.stderr)
        docs.append(row)
    CACHE.mkdir(exist_ok=True)
    cache_file.write_text(json.dumps(docs, ensure_ascii=False))
    if real:
        qs = evaluate_questions(llm, docs, questions)
        write_report(summarize(docs, qs), docs, qs, model, "realistic", "realistic (photo)")
    elif args.new:
        qs = evaluate_questions(llm, docs, HARD_QUESTIONS, hard=True)
        write_report(summarize(docs, qs), docs, qs, model, "hard", "synthetic")
    else:
        qs = evaluate_questions(llm, docs, questions) + evaluate_questions(llm, docs, HARD_QUESTIONS, hard=True)
        write_report(summarize(docs, qs), docs, qs, model)
    print(json.dumps(summarize(docs, qs), indent=2))


if __name__ == "__main__":
    main()
