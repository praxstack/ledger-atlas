# Cloud development and DMG builds

Ledger Atlas can be developed without a Mac at hand. Code changes happen anywhere
(Claude Code on the web, Codespaces, any laptop); GitHub Actions macOS runners do the
Swift build, the tests, and the DMG.

```
  edit (cloud session / any machine)
        │  git push / pull request
        ▼
  CI ─────────────── checks  (Linux)  npm lint/typecheck/test/build, ruff, pytest
   │                 swift   (macOS)  swift build, swift test, mmctl
   ▼
  Mac app (DMG) ──── xcodebuild Release → sign → DMG → launch smoke test
        │
        ▼
  Artifact on the run (main, manual runs, PRs labelled build-dmg)
  GitHub Release      (tags v*)
        │
        ▼
  download → open DMG → drag Ledger Atlas to Applications
```

## What runs where

| Workflow | Trigger | Runner | What it proves |
|---|---|---|---|
| `CI` / Web + Python checks | every PR, push to main | ubuntu | web demo and orchestration tooling are green |
| `CI` / Swift build + test | PRs touching Swift/Xcode/scripts, push to main | macos-26 | `swift build`, `swift test`, `mmctl` |
| `Mac app (DMG)` | push to main, `v*` tags, manual, PRs labelled `build-dmg` | macos-26 | the Xcode app builds, signs, packages, and launches |

The cloud container itself is Linux, so it cannot build the Swift targets (they link
AppKit, Security, WidgetKit, and friends). It can run the web and Python checks
locally: `npm ci && npm run lint && npm run typecheck && npm test` and
`uv sync --frozen && .venv/bin/ruff check scripts .codex/hooks tests/orchestration && .venv/bin/pytest tests/orchestration`.
Swift feedback comes from the `CI` workflow on the pull request.

## Getting a DMG onto your Mac

1. Open the repository's **Actions** tab and pick the latest green **Mac app (DMG)** run
   (or click **Run workflow** to build any branch).
2. Download the `LedgerAtlas-<version>-<mode>` artifact and unzip it.
3. Open the DMG and drag **Ledger Atlas** to **Applications**.
4. Ad-hoc builds are not notarized. The first launch is blocked; open
   **System Settings › Privacy & Security** and click **Open Anyway** (once per build).
   Alternatively: `xattr -dr com.apple.quarantine "/Applications/Ledger Atlas.app"`.

For a tagged release: `git tag v0.2.0 && git push origin v0.2.0` publishes a GitHub
Release (marked pre-release) with the DMG and its SHA-256.

The same script works on a Mac: `./scripts/package-dmg.sh` writes `dist/LedgerAtlas-<version>.dmg`.

## Signing modes

**Ad-hoc (default, no secrets).** The app and widget are signed with `codesign -s -`
and their entitlements. Good for personal installs and testing. Not accepted by
Gatekeeper without the manual approval above. The sandbox is active, so the
entitlements (including the LA-005 bookmark and loopback-server ones) are exercised.

**Developer ID + notarization (when secrets exist).** Add these repository secrets
(Settings › Secrets and variables › Actions). The workflow switches mode automatically.

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE_P12` | base64 of the exported *Developer ID Application* certificate + key (`base64 -i cert.p12 \| pbcopy`) |
| `MACOS_CERTIFICATE_PASSWORD` | password chosen when exporting the .p12 |
| `MACOS_SIGN_IDENTITY` | e.g. `Developer ID Application: Your Name (57GGJTRSFG)` |
| `APPLE_NOTARY_KEY_P8` | base64 of an App Store Connect API key (.p8) with Developer access |
| `APPLE_NOTARY_KEY_ID` | that key's ID |
| `APPLE_NOTARY_ISSUER_ID` | the issuer ID shown on the App Store Connect keys page |
| `MACOS_APP_PROFILE` / `MACOS_WIDGET_PROFILE` | optional: base64 Developer ID provisioning profiles, needed if the `group.` app-group entitlement must be honoured without a prompt |

The signed path has not run yet; expect the first signed run to need small fixes.

## Choosing the Xcode version

`scripts/ci/select-xcode.sh` picks the newest non-beta Xcode on the runner. To pin one,
set the repository **variable** `XCODE_VERSION` (e.g. `26.1`).

## Cost note

The repository is public, so GitHub-hosted runners (including macOS) are free and
unlimited. Ad-hoc signing needs no Apple Developer account. The whole pipeline costs
nothing. Newer pushes still cancel older runs, and PR DMG builds still need the
`build-dmg` label, to keep feedback fast.
