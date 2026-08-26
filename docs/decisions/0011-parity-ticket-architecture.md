# 0011 — Parity ticket architecture

Status: accepted 2026-08-23.

## Context

The 2026-08-23 feature-parity audit names 96 feature rows, 16 content tables, five
import blockers, and a six-step roadmap. Tickets #1–#25 covered the roadmap and the
four mappable content-table entities, but 25 audit rows had no owner, and ticket
bodies carried no per-row traceability. The tracker must let any reader walk from
any audit row to its owning issue and back without guessing.

## Decisions

1. **Every parity row resolves to at least one GitHub issue.** Coverage is complete:
   buildable gaps live in cluster epics (#26–#31), device/oracle-gated work lives in
   one `ready-for-human` issue (#32), excluded vendor rows are marked non-goals.
2. **Cluster epics, not row stubs.** Twenty-five loose issues would trash
   navigability. Epics group by domain cluster; the generated coverage report keeps
   the 1:1 row-to-issue mapping so granularity survives at the row level.
3. **Oracle-gated work is never agent-ticketed.** Rows needing the original app as
   oracle or a physical device sit behind `ready-for-human` (#32) and land as
   evidence plus synthetic fixtures, then flip by re-running the audit.
4. **Native sub-issues under parent specs.** #22–#25 are GitHub children of #21;
   textual "Blocked by" lines remain canonical in the local pack copies because the
   pack must survive without API access.
5. **The annotated HTML is a derived edition inside ledger-atlas.** The evidence
   original stays sealed (product invariant 1). The generator script is versioned in
   `scripts/`, regenerates from the sealed original, and must pass content
   assertions (row IDs present, cell count exact, zero unresolved markers) or refuse
   to write. A prior generator version silently dropped row-ID cells while reporting
   success; assertions exist because of it.
6. **Exactly one readiness label per issue**, per the triage vocabulary.

## Consequences

- Re-running the audit means the audit's author updates the sealed original in the
  evidence repository; this repo's generator only reads it. Drift between tracker
  and report is detectable by diffing generated output.
- New parity rows enter through an epic body edit plus a generator mapping entry,
  never by hand-editing the HTML.

## Rollback

Issues are soft-deletable; the generated file is untracked working tree. Deleting
the generator mapping restores nothing else; no canonical code depends on it.
