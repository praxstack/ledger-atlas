# Money Manager v19: import certificate

A certificate states what one import of one exact backup achieved. It names the tested
bytes, the profile, the adapter, the locale, the oracle and the level reached. Every
field is a count or a hash, so a certificate can be shared without exposing the ledger.
The level is derived from checks; a caller cannot ask for one.

## Running it

```sh
mmctl certify --input <backup.mmbak> --work-dir <empty-dir> \
  --time-zone <iana-id|fixed:SECONDS> --locale <und|en-US|en-IN> \
  [--oracle <oracle.json>] [--json]
```

- `sourceSHA256` names the file as given. `importedArtifactSHA256` is the hash the
  ledger's import receipt records: equal for a plain backup, the SQLite member for a ZIP.
- `locale` is the supported locale the import was certified for. `sourceLocales` lists the
  backup's own `android_metadata.locale` values, so a mismatch is visible.
- The source is only read. It is hashed before and after; any change fails
  `source_unchanged`.
- The work directory must exist and be empty (exit 65 otherwise). Scratch ledgers
  `certify-a.sqlite` and `certify-b.sqlite` are left there for inspection. They hold
  private data, so delete them when done and never commit them.
- Exit 0 when every check passes, 5 when one fails, 4 when the import cannot run.
  Errors print a code only, never a path or a value.

An oracle is a small JSON file of expected counts written by whoever holds the backup:

```json
{ "eventsByKind": { "income": 2, "expense": 2, "transfer_debit": 1, "transfer_credit": 1 },
  "transferPairs": 1 }
```

Its id is a hash of its content, so the certificate points at exactly the expectations
used. Keep real oracles next to the real backup, outside the repo.

## Checks and levels

The certifier imports the backup into ledger A, imports it into A again, and imports it
into a fresh ledger B.

| Check | Passes when |
| --- | --- |
| `source_unchanged` | SHA-256 and size are identical before and after |
| `profile_observed_v19` | the backup classifies as a supported v19 profile |
| `committed` | the first import committed, and its event count matches the ledger |
| `no_blocking_subjects` | the reconciliation report has no blocking subject |
| `no_unresolved_semantics` | no unknown type, unproven transfer direction or deleted flag remains |
| `every_subject_dispositioned` | mapped + preserved + excluded = tables + records + fields + 1 artifact |
| `canonical_integrity` | `PRAGMA integrity_check` and `foreign_key_check` are clean |
| `no_duplicate_mapping` | no source record maps to two events |
| `reimport_unchanged` | importing the same bytes again changes nothing |
| `independent_import_identical` | ledger B has the same event set hash, reconciliation hash and counts |
| `oracle_counts` | events by kind and transfer pairs equal the oracle (only with `--oracle`) |

- **L1** read-only classification: some L2 check failed.
- **L2** lossless staging: the first eight checks pass.
- **L3** deterministic mapping: every check passes and an oracle was given.
- **L4** and **L5** need a canonical round trip and behavioural parity with the vendor
  app. This tool cannot produce that evidence, so it never claims them.

A same-account transfer pair is preserved with reason `sameAccountTransfer`. It does not block
certification.

## ZIP backups

A `.mmbak` can be a plain SQLite file or a ZIP holding one. Since #54 the staging id,
the manifest's artifact hash and its size come from the SQLite member, not from the ZIP
wrapper. So a ZIP and the plain file it wraps import to the same ledger, and importing
one after the other reports `unchanged`. The source-unchanged fingerprint still covers
the file on disk. ZIP imports staged before this change had wrapper-based ids; no
release shipped with them.

## Vendor writer

Ledger Atlas v1 never writes Money Manager files. Import is one way: the source is
opened read-only and `source_unchanged` proves it was not touched. An export the app
cannot read (a newer schema, a missing contract table, an unknown container) is refused
with a visible reason before anything is staged, and no partial import is kept.
Writing a Money Manager backup back out is out of scope for v1. An explicit refusal of a
Money Manager format export request, with its own test, is tracked in #135.
