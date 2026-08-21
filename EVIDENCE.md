# External evidence contract

The writable product repository contains no real Money Manager backup or personal screenshot.

Canonical research root:

`/Users/prax/Developer/money-manager-reverse-engineering`

`scripts/verify.sh` honors `LEDGER_ATLAS_EVIDENCE_ROOT` as an override of that path. When the directory is missing or lacks `.orchestrion/protected-inputs.sha256`, the sibling protected-input check is skipped; originals stay read-only and are still hashed when the tree is present.

Its protected-input manifest is:

`/Users/prax/Developer/money-manager-reverse-engineering/.orchestrion/protected-inputs.sha256`

Product tests use `fixtures/synthetic/`. A named compatibility certification may read an explicit external backup with SQLite `mode=ro&immutable=1` while the product repository is the only writable sandbox root. Never create a writable copy as an unattended convenience.
