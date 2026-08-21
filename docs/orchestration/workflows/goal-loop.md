# Workflow: bounded goal and atom loop

Use native `/goal` for a supervised objective in one persistent Codex task. Use `run-unattended.sh` for fresh ephemeral atom contexts.

An atom is eligible only when its dependencies are done, criterion is machine-checkable, declared paths are safe, the baseline is clean, and the finite run is explicitly armed. Stop continuation runs `verify.sh --fast`; success disables the loop, while iteration, elapsed-time, no-progress, malformed-state, and kill-switch paths release control safely.

The unattended runner additionally requires a reviewed baseline commit, provider/commit authorization flags, per-atom and whole-run wall clocks, observable HEAD/PRD completion, and a fresh context per attempt. It does not infer completion from a Codex exit code alone.
