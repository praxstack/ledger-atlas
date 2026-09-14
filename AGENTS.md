# Ledger Atlas operating contract

Ledger Atlas is an independent, local-first personal-finance product. macOS is the first client. Money Manager formats are compatibility inputs at the perimeter, never the canonical domain model.

## Read first

Read `CONTEXT.md`, `SPEC.md`, `prd.json`, and `docs/orchestration/RUNBOOK.md` before changing code.

## Product invariants

1. The reverse-engineering repository and real backups/screenshots are read-only evidence outside this writable repository. Never copy, edit, move, rename, normalize, or open them read-write.
2. No silent loss. Every source item must be mapped, preserved with provenance, intentionally excluded with a visible reason, or block the import. Certify only named tested profiles.
3. Vendor schemas/codes stay in versioned adapters. The canonical ledger, package, analytics contracts, and future sync protocol are independently owned.
4. Financial truth never uses binary floating point. Preserve raw literals and explicit unit, scale, rounding, timezone, local date, tombstone, linkage, and provenance.
5. Real financial content, credentials, SMS, photos, names, notes, and transaction values never enter tracked fixtures, prompts, logs, screenshots, or test output. Use synthetic fixtures.

## Engineering quality

- Normal local Git commits are allowed after the relevant checks pass. Ledger Atlas does not require finite atom authority, gate receipts, paired admission commits, or provider-review paperwork.
- Before editing, trace the affected flow and callers, state the acceptance criteria, and check the architecture boundaries above. Keep the change focused and preserve unrelated work.
- Never weaken, delete, or skip a relevant test to get green. Fix shared root causes in the lowest common layer instead of patching one caller.
- Money, import, migration, package, backup, restore, security, and privacy changes require focused tests plus independent review proportional to their actual risk. Review quality matters; a fixed two-provider ceremony does not.
- Project hooks catch common direct writes to named read-only evidence, reject destructive Git cleanup, and prevent test deletion. They are not a security boundary and do not grant commit authority, continue agent turns, or block ordinary product work.
- Use bounded subagents only for genuinely independent scopes. One owner per writable file or module; reviewers are read-only.

## Verification

```sh
./scripts/verify.sh --fast
./scripts/verify.sh --full
```

Fast and full verification are engineering evidence, not commit permissions. Import/mapping, money/time arithmetic, migrations, canonical schema, source writes, export/round-trip, security, and privacy changes receive extra adversarial coverage. Green tests authorize neither release nor universal compatibility claims.

## Agent skills

### Issue tracker

GitHub Issues in `praxstack/ledger-atlas` are canonical, with a Linear mirror and a durable local markdown pack under `.scratch/ledger-atlas-end-to-end/issues/`. See `docs/agents/issue-tracker.md`.

### Triage labels

Closed five-label readiness vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`); exactly one active per ticket. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: root `CONTEXT.md` plus six declared domains (engineering quality, compatibility laboratory, canonical ledger, v19 adapter, native Mac product, shared clients). See `docs/agents/domain.md`.

### Skill discovery

Start each session with the `using-superpowers` skill to discover available skills before answering. The gstack suite (browse, ship, investigate, retro, and related) is installed host-side under `~/.agents/skills/`; invoke it by name when a task matches. Per-role model mapping for pstack lives globally at `~/.config/pstack/models.md`. For any user-facing prose drafted here, run `unslop` (or `stop-slop` / `humanize`) over it before shipping.
