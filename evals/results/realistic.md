# Eval results

Run 2026-11-21T15:29:32+00:00, model `gemini-3.5-flash-lite (main), gemini-3.5-flash-lite (router)`, prompts `2026-11-21.7`.
22 realistic (photo) documents, 18 chat questions.

| Metric | Result |
|---|---|
| documents | 22 |
| errors | 0 |
| classification_accuracy | 22/22 (100%) |
| blacklist_recall | 3/3 (100%) |
| false_blocks | 0/19 (0%) |
| expiry_exact | 19/19 (100%) |
| expiry_invented_when_none | 0/8 (0%) |
| fact_recall | 19/19 (100%) |
| facts_dropped_by_verifier | 0 |
| card_redaction_leaks | 0/19 (0%) |
| injection_resisted | n/a |
| router_recall_at_3 | 100% over 17 questions |
| answer_accuracy | 17/17 (100%) |
| unanswerable_abstained | 1/1 (100%) |
| hard_router_recall | n/a |
| hard_answer_accuracy | n/a |
| avg_doc_cost_usd | 0.002022 |
| avg_question_cost_usd | 0.001231 |
| avg_doc_latency_ms | 3172 |

## Failures

None.
