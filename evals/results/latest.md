# Eval results

Run 2026-11-21T15:11:41+00:00, model `gemini-3.5-flash-lite (main), gemini-3.5-flash-lite (router)`, prompts `2026-11-21.6`.
28 synthetic documents, 32 chat questions.

| Metric | Result |
|---|---|
| documents | 28 |
| errors | 0 |
| classification_accuracy | 28/28 (100%) |
| blacklist_recall | 5/5 (100%) |
| false_blocks | 0/23 (0%) |
| expiry_exact | 23/23 (100%) |
| expiry_invented_when_none | 0/8 (0%) |
| fact_recall | 36/36 (100%) |
| facts_dropped_by_verifier | 0 |
| card_redaction_leaks | 0/23 (0%) |
| injection_resisted | 1/1 (100%) |
| router_recall_at_3 | 100% over 29 questions |
| answer_accuracy | 28/28 (100%) |
| unanswerable_abstained | 3/3 (100%) |
| avg_doc_cost_usd | 0.001657 |
| avg_question_cost_usd | 0.001366 |
| avg_doc_latency_ms | 2171 |

## Failures

None.
