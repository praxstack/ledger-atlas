# Budget period-6 evidence decision

Status: unresolved; no semantic certification.

The evidence set documents the budget-period schema and calls for analysis of
`PERIOD_TYPE=6`, but it does not provide privacy-safe row-level evidence or an
oracle that establishes the product behavior represented by that value.

Decision: preserve the raw period value and provenance, do not infer a vendor
label or budgeting formula, and keep the behavior unknown/blocking for any
lossless or parity claim. A future decision needs a synthetic corpus, an
explicit oracle, and before/after tests for creation, recurrence, migration,
and reporting behavior.

Evidence: `research/orchestration/audit/wave-01/shard-source-requirements.md`
and the schema/feature entries in the immutable compatibility manifests.
