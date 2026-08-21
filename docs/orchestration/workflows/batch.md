# Workflow: bounded parallel batch

The planner reads only ready PRD atoms, validates requested IDs, and rejects overlapping declared paths. At most the policy limit (currently three) runs at once. Each run receives an isolated branch/worktree, locked dependencies, one atom, a fresh ephemeral Codex context, its own runtime state, and its own gate receipts.

The parent enforces a wall-clock and kill switch, aggregates exit status, and writes a manifest. It never suppresses failures, deletes worktrees, merges branches, or pushes. Integration remains an explicit later operation after branch review and full verification.
