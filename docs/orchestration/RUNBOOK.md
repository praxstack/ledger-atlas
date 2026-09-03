# Ledger Atlas Codex Orchestrion runbook

This is the tested operating guide for the project-owned harness. It supersedes the supplied `codex-orchestrion-v1` archive, which is quarantined.

## Repositories

| Repository | Authority |
|---|---|
| `/Users/prax/Developer/money-manager-reverse-engineering` | Read-only source evidence and research after harness transfer. Never run a writable product agent here. |
| Current Ledger Atlas Git worktree | Product code, synthetic fixtures, generated projections, tests, and autonomous atoms. Derive it with `git rev-parse --show-toplevel`; do not hard-code the primary checkout. |

Do not copy real backups, personal screenshots, SMS, account names, notes, or photos into the product repository. Product processes may read explicitly referenced originals under a read-only sandbox for certification; routine tests use synthetic fixtures.

## Bootstrap

```sh
# Run from the chosen Ledger Atlas worktree.
ledger_root=$(git rev-parse --show-toplevel)
cd "$ledger_root"
./scripts/bootstrap.sh
codex --version
codex doctor
```

Open Codex in the product repository and run `/hooks`. Review the project `SessionStart`, `PreToolUse`, and `Stop` commands and trust their exact hashes. Never use the bypass-trust flag for normal operation.

## Admission smoke test

Use the automated hook tests first:

```sh
./scripts/verify.sh --full
.venv/bin/python -m pytest tests/orchestration/test_harness.py
```

Then conduct one interactive lifecycle test. Arm a synthetic atom without commit authority, make its focused verifier deliberately fail through a reversible synthetic fixture, and confirm the Stop continuation. Confirm `.orchestrion/off` releases it and the no-progress ceiling disables the state. Restore the synthetic fixture by an exact patch and rerun full verification. Do not overwrite `verify.sh` or use repository-wide checkout/reset for this test.

## Manual gated atom

Arm only the named atom and explicitly grant finite commit/review authority:

```sh
python3 scripts/orchestrion.py loop start \
  --atom <ATOM-ID> \
  --criterion "<exact prd.json criterion>" \
  --max-iterations 6 \
  --max-minutes 30 \
  --same-failure-limit 3 \
  --allow-gated-commit \
  --allow-provider-review
```

Inside Codex, implement and stage exact paths. The only commit command is:

```sh
./scripts/gate-commit.sh \
  --atom <ATOM-ID> \
  --message "<type(ATOM-ID): concise outcome>" \
  --criterion docs/orchestration/criteria/<ATOM-ID>.txt
```

Gate v2 never stages files. It permits unrelated untracked files only outside the armed atom's declared paths. Any owned untracked path is rejected as an incomplete atom. Verification runs from a temporary materialization of the exact staged tree, so unrelated working-tree files cannot make the candidate pass. The gate still refuses protected evidence, tracked unstaged changes, stale receipts, secret-like/binary/provider payloads over 400,000 bytes, non-passing structured reviews, changed staged trees, expired authority, and staged paths outside the armed PRD atom. `--criterion` must be a repository file whose text equals the frozen PRD atom criterion. P0 is the PRD flag plus a conservative path classification: every Swift file and every path under `Sources/`, `Tests/`, `tests/`, `src/`, `scripts/`, hooks, and `Package.swift`. Every P0 atom receives both reviewer and red-team lenses.

Architecture stabilization v1 uses separate manual runs in this exact pattern: subject
atom, admission atom, next subject. Its shared files intentionally transfer ownership, so
do not use unattended or batch mode for ARC/MIG/PKG/LED/IMP/MAC/TRUTH atoms. The admission
atom records the preceding subject done; it changes no product source or executable
control. See the accepted ticket pack for exact dependencies and paths.

The exact-tree verifier ignores the worktree `.venv`, caller `PATH`, Python injection variables, and compiler/toolchain overrides. It provisions a fresh offline environment from the staged `uv.lock` and requires the qualified Git, Swift, uv, Python, and Codex executable hashes embedded in the reviewed gate. Both provider lenses run from the materialized staged tree, not the ambient worktree. The pre-commit hook accepts only the short-lived capability created and consumed by that gate process. Tool upgrades fail closed until a separate Gate control review updates those hashes. Git replacement refs and caller-selected reviewer executables are rejected.

## Unattended sequential run

Preconditions: admission checks passed, exact hooks trusted, baseline committed, worktree/index clean, PRD valid, and each atom has disjoint path ownership.

```sh
./scripts/run-unattended.sh \
  --max-atoms 4 \
  --max-minutes 90 \
  --atom-minutes 30 \
  --max-turns 6 \
  --max-attempts 3 \
  --allow-gated-commits \
  --allow-provider-review
```

The two authorization flags are intentionally required on each run. State is written under ignored `.orchestrion/runtime/`; authority expires on success, kill switch, wall-clock limit, iteration ceiling, or repeated unchanged failure.

Stop from another terminal:

```sh
ledger_root=$(git rev-parse --show-toplevel)
touch "$ledger_root/.orchestrion/off"
```

Remove the switch only after inspecting the run summary and logs.

## Parallel batch

Only ready atoms with non-overlapping declared paths are eligible:

```sh
./scripts/batch-fanout.sh --jobs 3 --atoms ANL-001 ANL-002 ANL-003
```

Each atom gets a new branch/worktree and an independent one-atom runner. The batch never merges. Inspect the generated manifest/logs, review each branch, then authorize integration separately in dependency order.

## Daily review

```sh
git status --short --branch
git log --oneline -20
python3 scripts/orchestrion.py validate
./scripts/verify.sh --full
find .orchestrion/runtime -name summary.json -maxdepth 4 -print
```

Read P0 receipts and diffs. Green tests do not certify universal Money Manager compatibility; that remains a versioned corpus/matrix claim.

## Failure triage

| Symptom | Response |
|---|---|
| Hooks absent/untrusted | Stop. Run `/hooks`, inspect exact commands/hashes, and trust only reviewed project files. |
| Turn ends while an armed red check still has budget | Inspect hook trust/config and direct hook tests. Do not launch unattended work. |
| Repeated same error | The state must disable at the configured no-progress limit. Revise the hypothesis manually. |
| Gate says no authority | Re-arm the exact atom with both explicit authorization flags. |
| Gate says provider payload denied | Remove/separate secrets, binaries, personal data, or oversized changes; use offline human review. |
| Batch rejects overlap | Split ownership or run sequentially. Do not weaken the planner. |
| Kill switch used | Inspect child processes, worktrees, status, and receipts before removing it. |

## Integration boundary

The harness authorizes no push, merge, rebase, deploy, release, credential update, external message, or destructive cleanup. Add protected-branch required CI before sharing the repository. Local hooks and rules can be bypassed by a sufficiently privileged local user and are not a remote policy substitute.
