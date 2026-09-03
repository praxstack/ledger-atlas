# Architecture stabilization v1 review record

Status: accepted for ARC-001 freeze; product implementation waits for ARC-001 and ADM-002 gated commits  
Prepared: 2026-08-23  
Repository baseline: `ef515cbf1edb6f975da00210509abeb5fb221f4d`  
Prior planning-gate draft reviewed: `767ca6abd015b33d9ab4183e7475adb103773dcf7c736a2dca8d43ac8a1351dc`  
Corrected candidate submitted for exact-byte review: `0352fdafd2a91efab10740448bcd9fd538e54746aa7ff30b3f4c5e76d1da6b9b`
Accepted specification SHA-256: `9e256c2844d3ab18323ea2b8bd709698eb77627fe6d0dd9ca91065822da3c236`

## Scope and evidence boundary

This record covers architecture stabilization only. It does not certify a Money Manager
profile, claim release, or authorize merge/push/deploy. Reviews used repository code,
synthetic fixtures, redacted issue text, and content-free evidence. No real financial
content, backup, screenshot, path, name, note, credential, or value was sent to a model or
written here.

The work ran in the isolated worktree
`/Users/prax/Developer/ledger-atlas-architecture-review`; unrelated changes in the user's
main checkout were not modified or used as candidate evidence.

## Materials reviewed

- Root `AGENTS.md`, `CONTEXT.md`, `SPEC.md`, `prd.json`, `DESIGN.md`, `README.md`, and
  `docs/orchestration/RUNBOOK.md`.
- ADRs 0007, 0008, 0010, and 0011; orchestration decisions, audits, and workflows; plans
  001–003; product-status/history documents; Git history and package graph.
- Durable local issue pack 01–34 and canonical GitHub issues 1, 2, and 26–34.
- Actual schema, migration, package, store, import-workspace, native-Journey, and test call
  paths.
- Named autonomous-agent, orchestrion, apex, Hermes, research, council, spec, ticket,
  implementation, code-review, and planning-review skills. Apex was reviewed but not
  activated because its self-modifying loop conflicts with the frozen-governance contract.

## Tool and reviewer availability

| Requested reviewer | Receipt |
|---|---|
| Codex | Qualified offline gate binary `codex-cli 0.147.0`; independent read-only review completed. |
| Grok | Installed CLI; structured multi-turn attempts remained pending, then a bounded single-turn architecture review completed. Its conditional dissent is retained below. |
| MoA | No executable, tool, skill, or recommended installable plugin was available. Two labeled internal independent panels supplied integrity and product lenses. |
| Hermes | Installed skill/material reviewed; no separate Hermes verdict was substituted for a requested Codex/Grok/MoA verdict. |
| Subagents | Independent architecture, history, issue-33, GATE-002, CEO, engineering, design/DevEx, and council roles completed bounded read-only reviews. |

## Review rounds

| Round | Verdict | Findings and disposition |
|---|---|---|
| Architecture/history mapping | proceed | Existing local-first/module boundaries retained; migration ownership, package coupling, issue #34 paths, compatibility posture, and stale status were verified against code/history. |
| Codex independent review | hold | Required pre-upgrade recovery, complete v0 vector, import immutability, typed error ownership, occurrence bound, one opener, and feasible atoms. All accepted into draft 2. |
| Grok independent review | conditional hold | Required active transaction enforcement, complete hidden-row emptiness, normalized identity, one version authority, companion distinction, exact-profile blocking, durable destination, explicit backup action, and one opener. All accepted. Grok's opposition to v1 writes was conditional on freezing one authority/layout; that condition is met. |
| Internal MoA integrity | hold | Required transaction enforcement, import-only destination checks, cross-version identity, occurrence bound, duplicate-open removal, and journal distinction. All accepted. |
| Internal MoA product | hold | Required durable destination, onboarding, fresh timezone, async ownership, typed rescue, backup status, typed financial rows, accessible insights, and one motion source. All accepted. |
| Council synthesis, draft 2 | accept | No remaining P0/P1; preserved Grok dissent and confirmed package/migration conditions. Final-delta confirmation remains below. |
| CEO hold-scope, round 1 | hold | Scope was right-sized. Required populated v8/v9 semantic no-loss tests, materialized tickets/criteria/PRD, canonical lowercase test paths, and tracked receipts. Draft 2 fixed the semantic/path/receipt requirements; this planning atom materializes the remaining artifacts. |
| Engineering, draft 2 | hold | Required descriptor-pinned import writer, viable admission graph, metadata masking, complete package projection, security-scope ownership, explicit upgrade flow, executable accessibility evidence, and smaller atoms. Draft 3 accepted every finding. |
| Design, draft 2 | hold | Required DESIGN.md import order, upgrade rescue, exact-backup-only copy, and executable focus/accessibility/window evidence. Draft 3 accepted every finding. |
| DevEx, draft 2 | hold | Required complete atom criteria, a current-worktree-relative manual runbook, and verifiable UI gates. Draft 3 accepted every finding. |
| Engineering, draft 3 first pass | hold | Found one remaining P0: private staging had no lifetime/crash-cleanup contract. Added the one-shot locked `StagingLease`, authenticated terminal cleanup, safe restart sweep, and regressions. |
| Design/DevEx, draft 3 first pass | hold | Same staging-lifetime finding at P1. Accepted the same correction. |
| Engineering final delta | accept | Reviewed SHA `767ca6ab…`; no remaining P0/P1. |
| Design final delta | 9/10 accept | Reviewed SHA `767ca6ab…`; no remaining P0/P1. |
| DevEx final delta | 9/10 accept | Reviewed SHA `767ca6ab…`; no remaining P0/P1. |
| Council materialized-pack re-review | hold | Found that each admission depended on the subject whose status it must stage, which prevented the operator from arming it first. The corrected graph shifts each admission dependency to the prior admitted subject; exact corrected bytes require confirmation. |
| CEO scope re-review | accept | Reviewed corrected SHA `0352fdaf…`; the unchanged-gate dependency shift is the smallest coherent fix, ownership remains bounded, and no P0/P1 remains. |
| Council corrected-graph re-review | accept | Reviewed corrected SHA `0352fdaf…`; all seven mappings agree and the harness simulation leaves only `ADM-008` doing. No P0/P1 remains. |
| CEO exact-byte confirmation | accept | Confirmed accepted SHA `9e256c28…`; the status/version/date and planning-checkbox delta changed no scope or graph. No P0/P1 remains. |
| Council exact-byte confirmation | accept | Confirmed accepted SHA `9e256c28…`, matching both receipts; PRD, criteria, and diff validation remain clean. No P0/P1 remains. |
| Corrected fast verification | pass | Qualified fast verification passed 53 governance tests and 283 Swift tests in 13 suites on 2026-08-23. |

## Frozen decisions

1. Keep schema v10 until a real accepted product delta defines v11.
2. Move reusable migration execution to LedgerStore; both callers retain descriptor-bound
   write ownership and a verified pre-upgrade recovery image.
3. Treat the unversioned portable package as v0; v0/v1 share one frozen payload decoder,
   the manifest is the sole version authority, and content identity rejects hidden rows.
4. Close only verified foundations and issue #34 defects; do not expand parity,
   compatibility, release, transport, sync, or cloud scope.
5. Use serialized P0 subject/admission atoms because the current gate cannot commit its
   own done transition. No atom changes its governing criterion or executable gate.

## GATE-002 acceptance evidence

- Candidate implementation commit: `8623651` (gate v2 files are unchanged at the reviewed
  baseline).
- Frozen criterion: `docs/orchestration/criteria/GATE-002.txt`.
- Clean isolated-worktree fast verification passed with the qualified Codex binary.
- Full verification passed on 2026-08-23 with 53 Python governance tests, 283 Swift tests
  in 13 suites, mmctl smoke, qualified Codex-surface checks, and production builds of
  `mmctl` and `LedgerAtlasMac`:

  ```sh
  PATH="/Users/prax/.codex/packages/standalone/releases/0.147.0-aarch64-apple-darwin/bin:$PATH" \
    ./scripts/verify.sh --full
  ```

- Independent GATE-002 audit found the criterion implemented; the earlier local failure
  came from an unqualified newer Codex binary/cache, not from a candidate code defect.
- No gate, hook, verifier, reviewer, attestation, or protected-evidence file changes are
  part of architecture implementation.

## Dissent and deferrals

- Grok's conditional package-v1 dissent is closed by one manifest authority, a complete
  frozen v0 vector, one shared v0/v1 decoder, and normalized full-destination identity.
- A user-facing portable-package transport/restore flow, universal compatibility,
  unresolved vendor semantics, schema v11, UI redesign/parity, sync/cloud/iOS, and release
  remain explicitly deferred.
- The permanent gate done-transition repair remains a separate supervised governance
  issue. This run uses predeclared admission atoms and leaves only the final admission
  atom truthfully doing.

## Ticket synchronization

- GitHub #2 owns the ARC/TRUTH governance and product-status sequence.
- GitHub #33 owns `MIG-001` and `PKG-001` at schema v10.
- GitHub #34 owns `LED-003` and `MAC-001`.
- GitHub #35 owns `IMP-004` and its admission.
- The durable local pack mirrors all four records. Each uses `needs-triage` until the
  planning admission commits land. The Linear mirror remains pending because no connector
  is available in this session.

## Freeze gate

The accepted planning pack meets these conditions:

- this record, the ticket pack, every criterion file, and the PRD graph agree byte-for-byte;
- the CEO re-review confirms the materialized plan remains the smallest coherent scope;
- the council confirms its accept verdict against the final delta and preserves dissent;
- `git diff --check`, PRD validation, spec self-review, and secret/privacy checks pass; and
- the accepted specification SHA-256 is recorded here and in the ticket pack.

Product implementation remains forbidden until the ARC-001 and ADM-002 gated commits
freeze and admit these materials.
