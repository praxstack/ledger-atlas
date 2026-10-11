# Security audit: ledger-atlas (PRIVATE, praxstack/ledger-atlas)

HEAD d2c2ba3e (prepass/manifest.json). No tracked files modified. No processes started by this audit. The `node` listener on 127.0.0.1:7265 belongs to another agent and was left alone.

## Scope facts
- 6296 tracked files; 6012 are `.agents/` (vendored third-party skill pack). First-party code: `Sources/` (Swift, 68 files), `app/` + `lib/` (Next.js, ~530 lines), `scripts/`, `tests/`.
- No `.github/` directory in the repo, so the repo itself has no CI. Workflows seen by semgrep are inside `.agents/skills/*` and are inert.
- GitHub side: Dependabot alerts, secret scanning and code scanning are all disabled on the repo (403/404). Visibility private.

## Threat model
Assets: personal finance ledger (SQLite canonical store, Money Manager imports and backups), the app-lock secret in Keychain, widget projection in the app group, `data/transactions.json` for the web demo.
Entry points:
1. Untrusted Money Manager SQLite/backup files opened by the importer (MMImport, mmctl). Hostile schema or table names are the main parser risk.
2. Loopback status portal (LedgerLoopbackPortal): 127.0.0.1 ephemeral port, GET /status?token=.
3. App-group UserDefaults intent queue (widget/App Intents to app).
4. Next.js web app: `/api/transactions` GET/POST, no auth.
5. Dev tooling: scripts, skill pack, agent configs (.codex, .cursor, .specify).
Trust boundaries: file import to store; widget extension to app (same team, same app group); local network to web app; vendored skills to developer agents.

## Tool table
| Tool | Result | Raw | True positives |
|---|---|---|---|
| gitleaks history (65 commits) | exit 1 | 27 | 0 |
| gitleaks tree | exit 1 | 164 | 0 |
| trufflehog history (unverified) | exit 0 | 15 | 0 (0 verified) |
| trivy fs | exit 0 | 4 vulns in root lock, rest in .agents | postcss (see F1) |
| osv-scanner | exit 1 | root: postcss, vitest, brace-expansion; many in .agents | see F1/F4 |
| semgrep p/default, secrets, actions | exit 0 | 136 (135 in `.agents/`, 1 in pyproject) | 0 first-party code issues |
| npm audit | run | 10 (7 high, 3 moderate) | dev-time only, F1 |
| gh alerts (dependabot/secret/code scanning) | disabled | n/a | F5 |
| pip-audit / bandit / cargo audit / zizmor | not applicable: no first-party Python deps (`dependencies = []`), no first-party workflows, no Rust | | |

## Findings

### F1 (P2, security/tech-debt) Root npm lockfile has known-vulnerable transitive deps
`package-lock.json`: postcss 8.4.31 (nested under next; GHSA-qx2v-qp2m-jg93 XSS in stringify, source-map path traversal/file read), vitest/@vitest/mocker 3.2.7 (GHSA-82fw-gwwq-j7x9 arbitrary file read via mock redirect), brace-expansion 1.1.18 / 5.0.9 (ReDoS-style DoS), eslint-config-next chain (glob/micromatch). All are build/dev-time; none is reachable from the API route with attacker input. Real exposure: vitest dev server file read if run while exposed. Fix: `npm audit fix`, bump vitest, and add a postcss override; note npm's suggested `next@16`/`eslint-config-next@14` downgrade is not required. Confidence: high on versions, medium on reachability.

### F2 (P2, security) Web app binds 0.0.0.0 with an unauthenticated finance API
`package.json:6-7` runs `next dev` and `next start` with `--hostname 0.0.0.0 --port 3000`. `app/api/transactions/route.ts` GET returns every transaction and balance, POST appends one, with no auth, no Origin/CSRF check (JSON body but `request.json()` accepts text/plain cross-site "simple" posts), no CORS policy. Anyone on the same LAN can read and write the ledger; a malicious web page can POST to localhost via fetch with text/plain. Data file is gitignored (`.gitignore:39`) and written 0600 (`lib/ledger.ts` persistLedger). Mitigations: it is a demo/prototype surface alongside the real Mac app. Fix: bind 127.0.0.1, check `Origin`/`Content-Type: application/json`, add a token if kept. Confidence: high.

### F3 (P3, security) Loopback portal hardening gaps
`Sources/LedgerAtlasMacUI/LedgerLoopbackPortal.swift`: binds only IPv4 loopback with a 122-bit random token (UUID), idle timeout 900s, stops on sleep, serves only counts (accountCount/transactionCount). Good. Minor: token compared with `==` (not constant time, impractical over loopback), token travels in the query string (line 96; appears in URL history), no Host header validation, and `token` is read on the network queue but written from the main actor without a lock (data race under Swift concurrency, `@unchecked Sendable`). Impact low because payload is counts only.

### F4 (P3, tech-debt/supply-chain) Vendored third-party skill pack in a finance repo
6012 tracked files under `.agents/` include requirements pinned to vulnerable versions (requests 2.9.2, pillow 9.5.0, urllib3, python-multipart 0.0.9, bun.lock with axios/tar/undici; osv/trivy hits all under `.agents/`), a Dockerfile misconfiguration (`devcontainer-setup/resources/Dockerfile`), mutable action tags in bundled workflow templates, and scripts that execute shell. They are not part of the shipped app, but they are executed by agents on the developer machine, so they are a supply-chain surface and they inflate every scanner. Recommend excluding `.agents/` from scanning config, or not committing it (the canonical copy lives in `~/.agents/skills`). Also `pyproject.toml:13` triggers uv-missing-dependency-cooldown (informational).

### F5 (P3, build-ci) No GitHub-side security tooling or CI
Dependabot, secret scanning and code scanning are disabled; no `.github/workflows`. For a private finance repo, enabling secret scanning and Dependabot is cheap. Also Xcode project has no `ENABLE_HARDENED_RUNTIME` (grep count 0 in `LedgerAtlas.xcodeproj/project.pbxproj`): required for notarized distribution, not for local runs. Code signing is Automatic.

## Reviewed and clean (positive evidence)
- Entitlements: `LedgerAtlas.entitlements` has app-sandbox, one app group, user-selected read-write only. No network client/server entitlement, no temporary-exception, widget has no file access.
- No `Process`/`NSTask`/osascript/`/bin/sh` use in `Sources/` (rg empty). No URLSession, no URL schemes, no WKWebView in `Sources/`.
- SQL: all `sqlite3_prepare_v2` statements use bind parameters; the only interpolated SQL is table/column names from imported DB, passed through `quotedIdentifier` which doubles quotes (`MoneyManagerV19ObservedStructureReview.swift:664`, `SourceClassifier.swift:593`). Imports use `PRAGMA query_only=ON` and `trusted_schema=OFF` (`ImmutableSourceStager.swift:295-296`).
- File access uses `O_NOFOLLOW`/`O_CLOEXEC` descriptors (LedgerStore.swift:205,259,285,2296; mmctl main.swift:268), mitigating symlink races.
- Keychain: app lock uses `SecItemCopyMatching` (LedgerAppLock.swift:183-193).
- Web: no `dangerouslySetInnerHTML`/`innerHTML` in app/lib; React escapes output; ledger writes use `wx` 0600 temp file plus rename, amounts validated to exact cents.
- Intent bridge: app-group UserDefaults only reachable by same-team signed processes; request is decoded as a typed Codable and consumed once; `note`/`amountLiteral` are free strings, so the consumer must validate them (not audited end to end).
- Scripts: `scripts/*.sh` have no curl/wget/pipe-to-shell/sudo/eval.

## False-positive triage
- gitleaks history 27 and tree 164: all FP. 14 (+14) in `commit-governance-audit.html` (lines 176, 188) are random `data-map-key` ULID-style form ids; 1 in `Sources/LedgerAtlasMacUI/LedgerIntentBridge.swift:30` is the UserDefaults key name `"ledger-atlas.pending-intent.v1"`; 9 in `.agents/skills/*/references/*.md` are documentation placeholders (REDACTED rows, `curl -H Authorization` examples, a sample Firebase key pattern in firebase-apk-scanner docs); 135 in `graphify-out/cache/` are hashes in generated cache (ignored via .git/info/exclude, not tracked).
- trufflehog 15 (0 verified): JDBC/Postgres/SQLServer/Algolia/Gitlab/Gemini detectors matching connection-string and key examples in `.agents/skills/**` markdown docs (e.g. jdbc-setup.md, hyperdrive docs). Placeholders, unverified.
- semgrep 135 `.agents/` hits (dynamic urllib, non-literal regexp, file permissions, sqlalchemy raw query in third-party scripts, defused-xml, mutable action tags in templates): vendored, not shipped, not wired to untrusted input from this repo. Not First-party. Semgrep has no Swift coverage of consequence, so the Swift review above was manual.
- trivy secrets: 0. trivy misconfig: 1 Dockerfile inside `.agents` (F4).
- osv/trivy `.agents` lockfiles: real vulnerable versions but unreachable from the app; see F4.

## Committed personal data
No `.env`, key, db, backup or statement files tracked outside `.agents/` (git ls-files filter). `fixtures/synthetic/` is synthetic by name; docs reference screenshots and Money Manager backups only as local paths. `commit-governance-audit.html`, `status.html`, `spec*.html` are project/process documents. No account numbers observed. Exposure is limited by private visibility; I did not open user data files.

## Not verified
Full Swift app flow (App Intents handling of `note`/`amountLiteral`, backup encryption, Keychain accessibility class) was sampled, not exhaustively traced. Hardened runtime and notarization status depend on release settings not in the repo.
