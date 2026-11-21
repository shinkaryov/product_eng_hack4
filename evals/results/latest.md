# Eval results

Run 2026-11-21T14:25:59+00:00, model `gemini-3.5-flash-lite (main), gemini-3.5-flash-lite (router)`, prompts `2026-11-21.4`.
24 synthetic documents, 28 chat questions.

| Metric | Result |
|---|---|
| documents | 24 |
| errors | 0 |
| classification_accuracy | 24/24 (100%) |
| blacklist_recall | 5/5 (100%) |
| false_blocks | 0/19 (0%) |
| expiry_exact | 19/19 (100%) |
| expiry_invented_when_none | 0/6 (0%) |
| fact_recall | 31/31 (100%) |
| facts_dropped_by_verifier | 0 |
| card_redaction_leaks | 0/19 (0%) |
| injection_resisted | 1/1 (100%) |
| router_recall_at_3 | 100% over 25 questions |
| answer_accuracy | 24/24 (100%) |
| unanswerable_abstained | 3/3 (100%) |
| avg_doc_cost_usd | 0.001538 |
| avg_question_cost_usd | 0.001095 |
| avg_doc_latency_ms | 6732 |

## Failures

None.
