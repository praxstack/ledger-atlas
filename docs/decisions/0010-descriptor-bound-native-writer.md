# 0010 — Native writes require descriptor-bound SQLite

Status: accepted for implementation; no writable UI is enabled yet.

## Decision

The native-ledger writer must not authenticate a file descriptor and then let
SQLite reopen the ledger pathname for read-write access. A pathname can be
replaced between those operations, and opening the replacement can trigger
SQLite recovery before an after-the-fact identity check rejects it.

The writer will use a small, tested SQLite VFS boundary that:

1. receives an already validated owner-only ledger descriptor;
2. binds the SQLite main database handle to that descriptor;
3. pins the containing directory for rollback-journal create/delete;
4. rejects unexpected WAL, SHM, symlink, hardlink, mode, and companion states;
5. validates the approved ledger identity immediately before durable commit.

The public native editing UI remains read-only until this exists.

## Rejected alternatives

- Opening the validated pathname again: a rename race remains.
- `file:/dev/fd/N` as a direct SQLite filename: SQLite derives unsafe journal
  names and this platform does not provide a general writable descriptor-open
  API.
- A UI-only editor or a whole-file copy/replace workaround: neither preserves
  the established canonical commit and crash-recovery contract.

## Acceptance evidence

Synthetic tests must prove all of the following:

- a swap after descriptor authentication leaves the replacement byte-identical;
- an attacker-created rollback journal is neither overwritten nor deleted;
- rollback after each native mutation step preserves the canonical checksum;
- same-process and cross-process writers observe normal SQLite exclusion;
- a successful commit leaves no companion files and reopens healthy;
- symlink, hardlink, foreign-owner, permissive-mode, WAL, and SHM inputs fail
  before writable SQLite access.

No real backup, screenshot, or personal financial content is used for these
tests.
