# Agent Skills — Pro Developer Workflow

This repository ships a curated, project-local skill library under `.agents/skills/` so Cloud Agents and local Cursor sessions share the same workflows.

## Installed ecosystems

| Ecosystem | Source | Skills | Primary use |
| --- | --- | --- | --- |
| **pstack** | [cursor/plugins/pstack](https://github.com/cursor/plugins/tree/main/pstack) | 40+ | Rigorous engineering playbooks (`/poteto-mode`, `/how`, `/why`, `/tdd`, principles) |
| **gstack** | [garrytan/gstack](https://github.com/garrytan/gstack) | 50+ | Virtual eng team: `/review`, `/qa`, `/ship`, `/office-hours`, `/cso` |
| **Superpowers** | [obra/superpowers](https://github.com/obra/superpowers) | 14 | TDD, brainstorming, plans, git worktrees, verification |
| **Matt Pocock** | [mattpocock/skills](https://github.com/mattpocock/skills) | 37 | `/grill-me`, `/triage`, `/implement`, `/to-spec`, `/code-review` |
| **improve** | [shadcn/improve](https://github.com/shadcn/improve) | 1 | Read-only codebase audit → executable plans in `plans/` |
| **Vercel** | [vercel-labs/agent-skills](https://github.com/vercel-labs/agent-skills) | 9 | React/Next best practices, deploy, web design guidelines |
| **Anthropic** | [anthropics/skills](https://github.com/anthropics/skills) | 20 | Frontend design, MCP builder, document skills, skill-creator |
| **Cloudflare** | [cloudflare/skills](https://github.com/cloudflare/skills) | 13 | Workers, Wrangler, Durable Objects, Agents SDK |
| **Stripe** | [stripe/ai](https://github.com/stripe/ai) | 8 | Payments integration best practices |
| **Trail of Bits** | [trailofbits/skills](https://github.com/trailofbits/skills) | 12 | Security review, vulnerability triage, static analysis |
| **Cursor plugins** | [cursor/plugins](https://github.com/cursor/plugins) | varies | team-kit, orchestrate, continual-learning, ralph-loop |

**Total:** ~180 skills installed in `.agents/skills/`.

## Quick start

### 1. One-time project setup

```bash
# Matt Pocock — configure issue tracker + docs paths
/setup-matt-pocock-skills

# pstack — choose models per role
/setup-pstack
```

### 2. Daily workflow commands

| When | Command |
| --- | --- |
| Any non-trivial task | `/poteto-mode <describe the task>` |
| Need alignment before coding | `/grill-me` or `/grill-with-docs` |
| Audit codebase for improvements | `/improve` or `/improve quick` |
| Plan a feature rigorously | `/brainstorming` then `/writing-plans` |
| Code review before PR | `/review` (gstack) or `/interrogate` (pstack) |
| Ship with QA | `/qa https://localhost:3000` |
| Debug systematically | `/systematic-debugging` or `/poteto-mode` bug-fix playbook |
| TDD bug fix | `/tdd` |

### 3. Recommended stacks by task

**Feature development**
1. `/grill-with-docs` — align on requirements
2. `/brainstorming` — design exploration (Superpowers)
3. `/poteto-mode` feature playbook — implement with rigor
4. `/review` — gstack code review
5. `/ship` — land the PR

**Codebase health**
1. `/improve quick` — audit and prioritize
2. Pick findings → plans land in `plans/`
3. `/improve execute 001` — dispatch executor

**Ledger Atlas (this repo)**
```bash
npm ci
npm run dev          # http://localhost:3000
npm test
npm run typecheck
npm run lint
npm run build
```

## Install / update skills

Skills are managed with the [skills CLI](https://github.com/vercel-labs/skills):

```bash
# Add a new ecosystem
npx skills add owner/repo --agent cursor -y --copy

# List installed
npx skills list

# Update all
npx skills update -y

# Search the registry
npx skills find "react performance"
```

Browse the public index at [skills.sh](https://skills.sh).

## More credible ecosystems to add

These are widely used and worth installing when relevant to your stack:

| Repo | Why install |
| --- | --- |
| [supabase/agent-skills](https://github.com/supabase/agent-skills) | Postgres, auth, RLS, Supabase CLI |
| [sentry-skills](https://github.com/getsentry/sentry-skills) | Error monitoring integration patterns |
| [expo/skills](https://github.com/expo/skills) | React Native / Expo development |
| [wondelai/skills](https://github.com/wondelai/skills) | Architecture & product frameworks |
| [heilcheng/awesome-agent-skills](https://github.com/heilcheng/awesome-agent-skills) | Curated index of 200+ skills |
| [top-agent-skills.com](https://top-agent-skills.com/) | Verified directory with quality scores |
| [cursor/plugins](https://github.com/cursor/plugins) | Official Cursor plugins (CodeRabbit, Vercel, Slack, etc.) |

Install any of them with:

```bash
npx skills add <owner/repo> --agent cursor -y --copy
```

## Directory layout

```
.agents/skills/          # Project skills (committed — works in Cloud Agents)
  poteto-mode/
  improve/
  brainstorming/
  gstack-review/
  ...
vendor/skills-repos/     # Git clones for reference (gitignored)
.cursor/environment.json # Cloud Agent environment config
```

## Notes

- Project skills in `.agents/skills/` are loaded by Cursor automatically ([docs](https://cursor.com/docs/skills)).
- Global skills in `~/.cursor/skills/` are **not** copied to Cloud Agents — keep workflows in the repo.
- gstack's browse binary is installed globally; browser QA skills need Playwright/Chrome (installed during gstack setup).
- Review skill security assessments at [skills.sh](https://skills.sh) before enabling in sensitive repos.
