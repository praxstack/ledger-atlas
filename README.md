# Ledger Atlas

Ledger Atlas is a local-first personal-finance app for macOS. It imports
Money Manager (Realbyte) Android v19 backups losslessly into a canonical
ledger, and every import is checked against a certificate. Data stays on your
Mac, inside the app's sandbox.

**Installing the Mac app:** see [docs/INSTALL.md](docs/INSTALL.md) (download, first launch,
where your ledgers live, backups and updates).

## Development

```sh
./scripts/bootstrap.sh
./scripts/verify.sh --full
swift run mmctl
```

`mmctl` offers redacted `inspect`, `coverage`, `stage`, `reconcile` and
`certify` commands. See
[docs/compatibility/money-manager-v19-import-certificate.md](docs/compatibility/money-manager-v19-import-certificate.md)
for what a certificate proves.

The Next.js web demo that used to live in `app/` and `lib/` was removed (#199).
Its last version is commit `0ea0ba4` on `main`.

## Cloud development and DMG builds

CI runs the Python checks on every pull request, and the Swift checks on
pull requests that touch Swift, Xcode, or scripts. The `Mac app (DMG)` workflow
builds an installable DMG on GitHub's macOS runners. See
[docs/development/cloud-and-dmg.md](docs/development/cloud-and-dmg.md).

## Agent skills

This repo ships 818+ project-local agent skills under `.agents/skills/` plus Spec Kit workflows in `.cursor/skills/`. See [docs/agent-skills-setup.md](docs/agent-skills-setup.md) for the full layered pipeline, core 10 commands, and install/update instructions.

## Cloud Agent environment

Repository-managed environment configuration lives in `.cursor/environment.json`. The install script at `.cursor/scripts/install.sh` sets up the Python tooling after checkout.

Native development also follows `AGENTS.md`, `CONTEXT.md`, `SPEC.md`, and
`docs/orchestration/RUNBOOK.md`. Real financial evidence stays in the separate
read-only research repository described by `EVIDENCE.md`.

## License

GPL-3.0-only. See [LICENSE](LICENSE). Anyone who distributes a modified version must also release its source under GPL-3.0. The app icon source is `Assets/Brand/ledger-atlas-app-icon.svg`;
`Assets/AppIcon.xcassets` holds the rendered macOS sizes. Brand guidelines: `docs/brand/BRAND.md`.
