# Ledger Atlas

Ledger Atlas contains the lightweight Next.js ledger surface and the macOS-first,
local-first personal-finance product track. The native track includes a Money
Manager compatibility boundary, a versioned canonical-ledger backend, and an
early SwiftUI shell. Both tracks are kept in this repository; neither implies a
universal compatibility or release claim.

## Development

```bash
npm ci
npm run dev
```

Open [http://localhost:3000](http://localhost:3000).

For the native track:

```sh
./scripts/bootstrap.sh
./scripts/verify.sh --full
swift run mmctl
```

The native `mmctl` surface is redacted `inspect`, `coverage`, `stage`, and
`reconcile`. The positive import cell is a named synthetic text-only v19 subset;
real Android v19 SQLite and `.mmbak` inputs remain classification-only.

## Scripts

| Command | Description |
| --- | --- |
| `npm run dev` | Start the development server |
| `npm run build` | Create a production build |
| `npm run start` | Run the production server |
| `npm run lint` | Run ESLint |
| `npm run typecheck` | Run TypeScript checks |
| `npm test` | Run unit tests |

## API

- `GET /api/transactions` — list transactions and current balance
- `POST /api/transactions` — add a transaction (`description`, `amount`)

## Agent skills

This repo ships 818+ project-local agent skills under `.agents/skills/` plus Spec Kit workflows in `.cursor/skills/`. See [docs/agent-skills-setup.md](docs/agent-skills-setup.md) for the full layered pipeline, core 10 commands, and install/update instructions.

## Cloud Agent environment

Repository-managed environment configuration lives in `.cursor/environment.json`. The install script at `.cursor/scripts/install.sh` runs `npm ci` after checkout.

Native development also follows `AGENTS.md`, `CONTEXT.md`, `SPEC.md`, and
`docs/orchestration/RUNBOOK.md`. Real financial evidence stays in the separate
read-only research repository described by `EVIDENCE.md`.
