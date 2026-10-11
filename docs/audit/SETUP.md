# Ledger Atlas - Mac setup (verified 2026-10-04, Xcode 27.0, swift 6.4, node 24)

Repo: <repo root> (HEAD d2c2ba3, clean tree). Two tracks: Next.js web ledger + native SwiftPM/Xcode macOS app.
No env vars required. No secrets needed. Web app writes `data/transactions.json` (gitignored) under the cwd.

## Web (Next.js 15)
```sh
cd <repo root>
npm ci                      # ok
npm run lint                # pass
npm run typecheck           # pass
npm test                    # vitest: 3 files, 15 tests pass, 0 fail/skip
npm run build               # pass (routes: /, /_not-found, /api/transactions)
npx next start --hostname 127.0.0.1 --port 3917   # NOTE: package.json "start"/"dev" bind 0.0.0.0:3000 (all interfaces)
curl 127.0.0.1:3917/                     # 200, <title>Ledger Atlas
curl 127.0.0.1:3917/api/transactions     # 200 {"transactions":[],"balance":0}
curl -X POST -H 'content-type: application/json' -d '{"description":"x","amount":12.5}' 127.0.0.1:3917/api/transactions  # 201
curl -X POST ... -d '{"description":"","amount":"x"}'   # 400 validation error
```
Smoke done and server stopped; `data/` removed afterwards.

## Python orchestration tooling
```sh
uv sync --frozen            # ok (scripts/bootstrap.sh does this)
.venv/bin/pytest tests/orchestration   # 11 pass
.venv/bin/ruff check scripts .codex/hooks tests/orchestration   # FAIL: 4 errors, all in scripts/check-sync-gstack-skills.py
.venv/bin/ruff format --check ...       # FAIL: same file would be reformatted
```
Because ruff fails, `./scripts/verify.sh` (set -e) aborts before Swift steps on this tree. Run Swift steps directly.

## Native (SwiftPM)
```sh
swift build                 # pass (~30s cold)
swift test                  # 502 pass, 1 FAIL (see below); ~2 min, use a long timeout
swift run mmctl             # prints "mmctl schema=11 importer=11", exit 0
```
Known failure: MMImportTests "a public client cannot compile a caller-selected proof token"
(tests/MMImportTests/Reconciliation/LossReportTests.swift:34, helper publicClientTypechecks at :528-568) throws `.io`.
Root cause: helper walks `.build` for a `module.modulemap` whose path contains `CSQLite.build` (:540-541). With the
Xcode 27 SwiftPM build system the layout is `.build/out/...`, and the map is `.build/out/Intermediates.noindex/GeneratedModuleMaps/CSQLite.modulemap`,
so `moduleMap` is nil -> `.io` (:546). Test-harness layout assumption, not a product defect. Confidence: high.

## Xcode app
```sh
cd <repo root>
xcodebuild -list -project LedgerAtlas.xcodeproj    # schemes: LedgerAtlas, LedgerAtlasMac, LedgerAtlasMacUI, LedgerAtlasWidget
xcodebuild build -project LedgerAtlas.xcodeproj -scheme LedgerAtlas -destination 'platform=macOS' \
  -derivedDataPath <audit dir>/DerivedData \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO      # BUILD SUCCEEDED
open .../DerivedData/Build/Products/Debug/LedgerAtlas.app
```
- `CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO` alone FAILS: both targets "require a provisioning profile" (entitlements + DEVELOPMENT_TEAM 57GGJTRSFG in project.yml). Use `CODE_SIGNING_ALLOWED=NO`.
- Scheme LedgerAtlasMacUI has no test action (`xcodebuild test` errors); tests run via `swift test` only.
- App launched 6s via `open`, process alive, quit cleanly via osascript, no crash report. Unsigned build lacks entitlements, so widget/App Intents/sandbox features are not exercised.
- Not run: `swift build -c release` (verify.sh --full), `xcodegen generate` (xcodeproj is tracked).

## Notes
- README says http://localhost:3000 via `npm run dev` (0.0.0.0 bind).
- Prepass secret scans: gitleaks hits are mostly graphify-out/cache and .agents/skills docs; one hit at Sources/LedgerAtlasMacUI/LedgerIntentBridge.swift:30 (generic-api-key, likely false positive, unverified).
- Logs in this dir: npm-ci.log lint.log tsc.log vitest.log swift-build.log swift-test.log mmctl.log next-build.log xcb-LedgerAtlas.log.
