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

## Cloud Agent environment

Repository-managed environment configuration lives in `.cursor/environment.json`. The install script at `.cursor/scripts/install.sh` runs `npm ci` after checkout.
