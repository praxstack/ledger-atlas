# Ledger Atlas

A lightweight ledger for tracking credits and debits. Built with Next.js and TypeScript.

## Development

```bash
npm ci
npm run dev
```

Open [http://localhost:3000](http://localhost:3000).

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
