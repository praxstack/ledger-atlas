# Releasing Ledger Atlas

A release is a `v*` tag on a `main` commit. There are two ways to make one:

- **Run the workflow (works from a phone).** GitHub › Actions › **Mac app (DMG)** › **Run
  workflow**, branch `main`, release tag `v1.0.0-test.1`. The run builds the tip of `main` and
  creates the tag itself when it publishes. Use this when you can't push tags.
- **Push a tag**: `git tag v1.0.0-test.1 <sha> && git push origin v1.0.0-test.1`.

Either way, these run on that commit:

- **CI** (`.github/workflows/ci.yml`): Swift build and tests, Python and web checks.
- **Mac app (DMG)** (`.github/workflows/mac-app.yml`): builds and signs the DMG, opens it on a
  CI Mac, walks every screen, and imports a 7,500-entry made-up backup and reopens the result.
  It then **waits for the whole CI run on the same commit to pass**
  (`scripts/ci/wait-for-green-ci.sh`), and only then publishes the GitHub Release with the DMG, its `.sha256`, and the notes from
  `docs/releases/<tag>.md`.

The DMG is signed ad hoc (there is no paid Apple Developer account), so it is not notarized.
`docs/INSTALL.md` walks people through approving it once.

## Tag names

| Tag | Release type |
| --- | --- |
| `v1.0.0-test.1`, `v1.0.0-rc.1` (anything with a `-`) | Pre-release |
| `v1.0.0` | Full release, marked **Latest** |

Only a full release gets the Latest badge, and `docs/INSTALL.md` tells people to pick the newest
release, so ship `v1.0.0` as a full release.

## Checklist

Do these in order. Stop at the first one that fails.

1. **Pick the commit.** It is the tip of `main`, and both its **CI** run and its
   **Mac app (DMG)** run finished green. (Runs on `main` are never cancelled, so every commit
   on `main` has its own result.)
2. **Write the notes** in `docs/releases/<tag>.md` and merge them before tagging: what's new,
   what was fixed since the last release, known limits, how to install.
3. **Make a release candidate first** (`v1.0.0-rc.1`) from that commit, by running the
   workflow or pushing the tag (see above). Running the workflow builds the tip of `main`, so
   don't merge anything in between.
4. **Download it as a person would.** On macOS 15 and on macOS 26, download the DMG from the
   Releases page in a browser (so it carries the quarantine flag), check
   `shasum -a 256 -c LedgerAtlas-<version>.dmg.sha256`, and follow `docs/INSTALL.md` word for
   word: install, Open Anyway, first launch.
5. **Upgrade over the previous DMG.** With the previous release installed and a ledger open in
   it, install the new DMG over it. The ledger, passcode, receipt key and settings must all still
   work.
6. **Check the signature and sandbox**:
   `codesign -d --entitlements - "/Applications/Ledger Atlas.app"` shows the app sandbox and
   the expected entitlements (compare with `LedgerAtlas.entitlements`), and
   `codesign --verify --deep --strict` passes.
7. **Check the version.** About Ledger Atlas shows the tag's version without its suffix
   (`v1.0.0-rc.1` shows 1.0.0; `scripts/package-dmg.sh` sets it from the tag name), and the DMG
   file name carries the full tag version.
8. **Run the stress workflow** (Actions › Stress › Run workflow) on the release commit with the
   default filter, 25 runs. All runs pass.
9. **Update the truth files** for the release: `EVIDENCE.md`, `JOURNAL.md` and
   `docs/product-status.json` say what this release contains and what was checked.
10. **Make the release** (`v1.0.0`) from the same commit, the same way.
11. **Check the Releases page**: the release is marked Latest (not Pre-release), has the DMG and
    `.sha256`, and the notes from `docs/releases/v1.0.0.md`.

## If something goes wrong

- **The release step says CI did not pass:** look at the CI run for that commit, fix on `main`,
  and tag a new commit. Never move a published tag.
- **CI is still running when the DMG job waits:** it waits up to 45 minutes, then fails. Re-run
  the DMG job once CI has finished.
- **"Tag already exists" on Run workflow:** that version is taken; use the next number
  (`v1.0.0-test.2`).
- **A bad release went out:** mark it as a pre-release or delete it on the Releases page, then
  release a fixed version with a new tag.
