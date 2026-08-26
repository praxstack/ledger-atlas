# Ledger Atlas engineering runbook

This is the product-development workflow. It raises the technical and architecture
bar without creating a separate permission system for commits.

## Repository boundary

| Location | Use |
|---|---|
| `/Users/prax/Developer/money-manager-reverse-engineering` | Read-only original backups, exports, screenshots, and research. |
| `/Users/prax/Developer/ledger-atlas` | Product code, synthetic fixtures, tests, specifications, and generated reports. |

Original financial evidence stays unmodified and outside Git. Product tools and
private reconciliation tests may read explicitly named originals in read-only mode.
Tracked tests use synthetic fixtures and must not print personal data.

## Start a change

1. Read `AGENTS.md`, `CONTEXT.md`, `SPEC.md`, and the relevant `prd.json` item.
2. State observable acceptance criteria.
3. Trace the affected flow and all callers before editing.
4. Check the canonical-ledger and versioned-adapter boundaries.
5. Preserve unrelated working-tree changes.

## Implement

- Fix the shared root cause, not one visible caller.
- Keep vendor tables and codes inside versioned import adapters.
- Preserve exact money, time, timezone, provenance, tombstones, and unknown fields.
- Never write to an original backup or export.
- Add the smallest test that fails without the fix. Do not delete or weaken tests.

## Verify

Run the narrow test while developing, then the repository verifier:

```sh
./scripts/verify.sh --fast
./scripts/verify.sh --full
```

For imports, money, migrations, backup, restore, package formats, security, and
privacy, also run the named acceptance tests and obtain an independent review of
the actual diff. Review findings must be fixed or explicitly rejected with evidence.
There is no fixed provider count and no review receipt required for ordinary work.

## Commit

Use normal Git commands after the relevant checks pass:

```sh
git status --short
git diff --check
git commit -m "<concise outcome>"
```

No finite permission, staged-tree receipt, admission commit, paired paperwork
commit, or special commit script is required. A commit records work; it does not
prove release, shipment, or compatibility certification.

Push, merge, release, deployment, credentials, external messages, and destructive
cleanup remain separate actions. Perform them only when the task actually includes
them and after checking their real destination and effect.

## Project hooks

`.codex/hooks/quality.py` provides two small, heuristic safeguards:

- session startup reminds agents of the evidence and architecture boundaries;
- pre-tool checks catch common direct writes to named original evidence, destructive
  Git cleanup, and deletion of tests.

The hook is not a security boundary. The read-only evidence contract, immutable
SQLite open mode, and before/after hashes are authoritative. The hook does not block
normal commits, run goal loops, grant authority, choose work, or replace tests and review.

## Status language

Use these statements precisely:

- passing tests: the tested behavior passed;
- committed: the bytes are in local Git history;
- import certified: a named source profile completed private import and reconciliation;
- shipped: a distributable application was built, smoke-tested, and delivered.

Never substitute one statement for another.
