# Ledger Atlas

Ledger Atlas is a clean-room, local-first personal-finance product. The current
macOS-first milestone contains a Money Manager compatibility boundary, a
versioned canonical-ledger backend, and an early native SwiftUI shell.

```sh
./scripts/bootstrap.sh
./scripts/verify.sh --full
swift run mmctl
```

The current `mmctl` surface is redacted `inspect`, `coverage`, `stage`, and
`reconcile` (`--observed-v19-request` or `--staging-db` / `--manifest` /
`--digest` / `--decisions`). There is no `mmctl commit` write path. The only
approved write is in-process `ImportWorkspace` approval. The positive import
cell is a named synthetic text-only v19 subset. The real Android v19 SQLite
and direct `.mmbak` files classify, but remain classification-only. The
supplied XLSX is unsupported rather than guessed at.

There is no universal compatibility claim. Certification is per named
profile/fixture cell and coverage still permits L0 only. The Mac shell can
select a synthetic source, review it, approve into a local canonical ledger,
browse journey-backed destinations, search that ledger, inspect an accessible
insight table, and begin a descriptor-bound edit. It is
not a shipped finance product. iOS, analytics, sync, and historical formats
remain out of scope.

Read `AGENTS.md`, `CONTEXT.md`, `SPEC.md`, and `docs/orchestration/RUNBOOK.md` before development. Real financial evidence stays in the separate read-only research repository described by `EVIDENCE.md`.
