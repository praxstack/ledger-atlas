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
6. Build behavior interoperability with an original identity and native Mac interaction model. Do not copy vendor code, branding, proprietary assets, or a pixel-for-pixel UI.

## Autonomous engineering

- An explicitly armed atom may implement, test, stage its declared paths, obtain provider review, and create one gated commit. It expires at time/iteration/no-progress ceilings.
- The atom may not modify the hook, rule, verifier, review, gate, attestation, or evidence controls governing its own run. Change those only in a separate manual P0 atom.
- Keep one frozen criterion and exact path ownership. Preserve unrelated work. Never weaken/delete/skip tests to get green.
- Use bounded subagents only for genuinely independent scopes. One owner per writable file/module; reviewers are read-only.
- Commit only through `./scripts/gate-commit.sh` while exact finite authority is active. Direct commit, `--no-verify`, push, merge, rebase, deploy, credentials, messages, destructive cleanup, and scope expansion are unauthorized.

## Verification

```sh
./scripts/verify.sh --fast
./scripts/verify.sh --full
```

P0 includes import/mapping, money/time arithmetic, migrations, canonical schema, source writes, export/round-trip, sync, security/privacy, tests, and orchestration controls. It requires reviewer and red-team lenses. Green tests authorize neither integration nor universal compatibility claims.

## Agent skills

### Issue tracker

GitHub Issues in `praxstack/ledger-atlas` are canonical, with a Linear mirror and a durable local markdown pack under `.scratch/ledger-atlas-end-to-end/issues/`. See `docs/agents/issue-tracker.md`.

### Triage labels

Closed five-label readiness vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`); exactly one active per ticket. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: root `CONTEXT.md` plus six declared domains (delivery governance, compatibility laboratory, canonical ledger, v19 adapter, native Mac product, shared clients). See `docs/agents/domain.md`.

### Skill discovery

Start each session with the `using-superpowers` skill to discover available skills before answering. The gstack suite (browse, ship, investigate, retro, and related) is installed host-side under `~/.agents/skills/`; invoke it by name when a task matches. Per-role model mapping for pstack lives globally at `~/.config/pstack/models.md`. For any user-facing prose drafted here, run `stop-slop` or `humanize` over it before shipping.
