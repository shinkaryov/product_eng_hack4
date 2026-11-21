# Eval results

Run 2026-11-21T15:25:59+00:00, model `gemini-3.5-flash-lite (main), gemini-3.5-flash-lite (router)`, prompts `2026-11-21.7`.
30 synthetic documents, 13 chat questions.

| Metric | Result |
|---|---|
| documents | 30 |
| errors | 0 |
| classification_accuracy | 30/30 (100%) |
| blacklist_recall | 5/5 (100%) |
| false_blocks | 0/25 (0%) |
| expiry_exact | 25/25 (100%) |
| expiry_invented_when_none | 0/8 (0%) |
| fact_recall | 38/38 (100%) |
| facts_dropped_by_verifier | 0 |
| card_redaction_leaks | 0/25 (0%) |
| injection_resisted | 1/1 (100%) |
| router_recall_at_3 | n/a |
| answer_accuracy | n/a |
| unanswerable_abstained | n/a |
| hard_router_recall | 100% over 13 questions |
| hard_answer_accuracy | 10/13 (77%) |
| avg_doc_cost_usd | 0.00167 |
| avg_question_cost_usd | 0.001547 |
| avg_doc_latency_ms | 2202 |

## Failures

- [hard] question "If I move out at the end of the current lease for apartment 4B, by what date do I have to give notice?": answer "Tenant must give 60 days written notice before the end of the term [1]."
- [hard] question "How much do we pay for StreamBox per year?": answer "I could not find this in your documents."
- [hard] question "How much is the deductible?": answer "The collision deductible for the auto insurance is $500.00 [1]."
