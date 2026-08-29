# Agent Skills — Super-Pro Developer Workflow

This repository ships a curated, project-local skill library under `.agents/skills/` so Cloud Agents and local Cursor sessions share the same workflows.

## Layered architecture (2026 stack)

Three layers stack together: **skills** (committed workflows), **repo tools** (OpenSpec, Spec Kit), and an optional **MCP** layer (live docs, code intelligence, graph memory). Cloud Agents load project `.agents/skills/` only — not `~/.cursor/skills/`.

```mermaid
flowchart TB
  subgraph skills ["Layer 1 — Skills (.agents/skills/)"]
    D[Discover] --> I[Interrogate / Spec]
    I --> P[Plan]
    P --> M[Implement]
    M --> R[Review]
    R --> S[Security]
    S --> Q[Browser QA]
    Q --> H[Ship]
    H --> L[Learn]
  end

  subgraph tools ["Layer 2 — Repo tools"]
    OS[OpenSpec openspec/]
    SK[Spec Kit .specify/]
    IS[install-skills.sh]
    GS[sync-gstack-skills.sh]
  end

  subgraph mcp ["Layer 3 — Optional MCP (user keys)"]
    C7[Context7 — live library docs]
    SE[Serena — LSP / symbol graph]
    GF[Graphify — code graph memory]
  end

  skills --> tools
  tools -.->|optional| mcp
```

| Layer | Purpose | Key skills / tools |
| --- | --- | --- |
| **Discover** | Find the right skill or pattern | `/find-skills`, `/improve quick`, `/last30days` |
| **Interrogate / Spec** | Align requirements before coding | `/grill-me`, `/grill-with-docs`, `/to-spec`, `/interrogate`, OpenSpec `/openspec-propose` |
| **Plan** | Design and break down work | `/brainstorming`, `/writing-plans`, `/ce-plan`, `/poteto-mode`, `/hallmark` |
| **Implement** | Build with rigor | `/poteto-mode`, `/tdd`, `/implement`, `/ce-work`, Remotion skills |
| **Review** | Catch issues before merge | `/review`, `/code-review`, `/ce-code-review`, `/interrogate` |
| **Security** | Audit sensitive paths | Trail of Bits skills, `/semgrep`, `/codeql`, `/cso` |
| **Browser QA** | Prove changes in the real app | `/qa`, `/agent-browser`, `/ce-test-browser`, `/webapp-testing` |
| **Ship** | Land the PR | `/ship`, `/ce-commit-push-pr`, `/ce-babysit-pr` |
| **Learn** | Compound knowledge for next time | `/ce-compound`, `/continual-learning`, `/deep-research` |

### Optional MCP layer

These are **not** installed by default — they need user API keys or local services. Add them in Cursor Settings → MCP when you want live docs or code-graph context:

| MCP | Purpose | Keys / setup |
| --- | --- | --- |
| **Context7** | Up-to-date library documentation via MCP | [context7.com](https://context7.com) API key |
| **Serena** | Language-server symbol search and refactoring | `uvx` launch; no cloud key for local LSP |
| **Graphify** | Persistent code-graph memory across sessions | User-provided Graphify endpoint / key |

Skills such as `ce-plan` and `ce-compound` reference Context7 when the MCP server is connected; they fall back to web search otherwise.

## Core 10 (daily driver)

These ten commands cover most non-trivial work:

1. `/find-skills` — discover the right skill for any task
2. `/poteto-mode` — rigorous engineering playbook (feature, bug-fix, refactor)
3. `/grill-with-docs` — align on requirements before coding
4. `/brainstorming` + `/writing-plans` — design exploration and implementation plans
5. `/tdd` — test-driven development for bug fixes
6. `/review` or `/interrogate` — code review before PR
7. `/agent-browser` or `/qa` — browser QA against the running app
8. `/ship` — land the PR with checks
9. `/ce-compound` — capture learnings after shipping
10. `/improve quick` — periodic codebase health audit

## Installed ecosystems

| Ecosystem | Source | Skills | Primary use |
| --- | --- | --- | --- |
| **pstack** | [cursor/plugins/pstack](https://github.com/cursor/plugins/tree/main/pstack) | 40+ | Rigorous engineering playbooks (`/poteto-mode`, `/how`, `/why`, `/tdd`) |
| **gstack** | [garrytan/gstack](https://github.com/garrytan/gstack) | 50+ | Virtual eng team: `/review`, `/qa`, `/ship`, `/office-hours` |
| **Superpowers** | [obra/superpowers](https://github.com/obra/superpowers) | 14 | TDD, brainstorming, plans, git worktrees, verification |
| **Matt Pocock** | [mattpocock/skills](https://github.com/mattpocock/skills) | 37 | `/grill-me`, `/triage`, `/implement`, `/to-spec`, `/code-review` |
| **improve** | [shadcn/improve](https://github.com/shadcn/improve) | 1 | Read-only codebase audit → executable plans in `plans/` |
| **Vercel** | [vercel-labs/agent-skills](https://github.com/vercel-labs/agent-skills) | 9 | React/Next best practices, deploy, web design guidelines |
| **Anthropic** | [anthropics/skills](https://github.com/anthropics/skills) | 20 | Frontend design, MCP builder, document skills, skill-creator |
| **Cloudflare** | [cloudflare/skills](https://github.com/cloudflare/skills) | 13 | Workers, Wrangler, Durable Objects, Agents SDK |
| **Stripe** | [stripe/ai](https://github.com/stripe/ai) | 8 | Payments integration best practices |
| **Trail of Bits** | [trailofbits/skills](https://github.com/trailofbits/skills) | 12 | Security review, vulnerability triage, static analysis |
| **Cursor plugins** | [cursor/plugins](https://github.com/cursor/plugins) | varies | team-kit, orchestrate, continual-learning, ralph-loop |

### Newly installed (super-pro layer)

| Ecosystem | Source | Skills added | Primary use |
| --- | --- | --- | --- |
| **find-skills** | [vercel-labs/skills](https://github.com/vercel-labs/skills) | 1 | Skill discovery across the registry |
| **agent-browser** | [vercel-labs/agent-browser](https://github.com/vercel-labs/agent-browser) | 1 | Headless browser automation for QA |
| **Compound Engineering** | [EveryInc/compound-engineering-plugin](https://github.com/EveryInc/compound-engineering-plugin) | 34 | Plan → work → review → ship → compound learnings |
| **Awesome Copilot** | [github/awesome-copilot](https://github.com/github/awesome-copilot) | 417 | Broad toolbox: specs, testing, Azure, GitHub, docs |
| **Microsoft** | [microsoft/skills](https://github.com/microsoft/skills) | 9 (selective) | MCP builder, docs, frontend review, issue creation |
| **Supabase** | [supabase/agent-skills](https://github.com/supabase/agent-skills) | 2 | Postgres best practices, Supabase patterns |
| **AWS Agent Toolkit** | [aws/agent-toolkit-for-aws](https://github.com/aws/agent-toolkit-for-aws) | 55 | Bedrock, CDK, IAM, serverless, security agents, data lake |
| **Spec Kit** | [github/spec-kit](https://github.com/github/spec-kit) | 10 | Spec-driven dev: `/speckit-specify`, `/speckit-plan`, `/speckit-implement` (in `.cursor/skills/`) |
| **Hallmark** | [nutlope/hallmark](https://github.com/nutlope/hallmark) | 1 | Anti-AI-slop design: `/hallmark`, audit, redesign |
| **Last 30 Days** | [mvanhorn/last30days-skill](https://github.com/mvanhorn/last30days-skill) | 1 | Research what changed in a domain over the last month |
| **Deep Research** | [24601/agent-deep-research](https://github.com/24601/agent-deep-research) | 1 | Multi-step research with citations |
| **NVIDIA** | [nvidia/skills](https://github.com/nvidia/skills) | 4 (selective) | RAG blueprint, AIQ research, cuDF, cuOpt |
| **Remotion** | [remotion-dev/skills](https://github.com/remotion-dev/skills) | 3 | Video creation: best practices, create, render |
| **OpenSpec** | [@fission-ai/openspec](https://github.com/Fission-AI/OpenSpec) | 6 | Spec-driven changes in `openspec/` |

**Total:** ~830 skills in `.agents/skills/` plus Spec Kit skills in `.cursor/skills/`.

### Already present (skipped on re-install)

- trailofbits/skills
- vercel-labs/agent-skills
- anthropics/skills
- cloudflare/skills
- stripe/ai

## Quick start

### 1. One-time project setup

```bash
# Matt Pocock — configure issue tracker + docs paths (done)
# See docs/agents/issue-tracker.md, triage-labels.md, domain.md

# pstack — choose models per role (done)
# See ~/.cursor/rules/pstack-models.mdc
```

### 2. Daily workflow commands

| When | Command |
| --- | --- |
| Find the right skill | `/find-skills <describe task>` |
| Any non-trivial task | `/poteto-mode <describe the task>` |
| Need alignment before coding | `/grill-me` or `/grill-with-docs` |
| Audit codebase for improvements | `/improve` or `/improve quick` |
| Plan a feature rigorously | `/brainstorming` then `/writing-plans` |
| Code review before PR | `/review` (gstack) or `/interrogate` (pstack) |
| Browser QA | `/agent-browser` or `/qa https://localhost:3000` |
| Ship with QA | `/ship` or `/ce-commit-push-pr` |
| Debug systematically | `/systematic-debugging` or `/poteto-mode` bug-fix playbook |
| TDD bug fix | `/tdd` |
| Capture learnings | `/ce-compound` |

### 3. Recommended stacks by task

**Feature development**
1. `/find-skills` — pick the right workflow
2. `/grill-with-docs` — align on requirements
3. `/brainstorming` — design exploration (Superpowers)
4. `/poteto-mode` feature playbook — implement with rigor
5. `/review` — gstack code review
6. `/agent-browser` — browser QA
7. `/ship` — land the PR
8. `/ce-compound` — capture learnings

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

**One command** (idempotent — skips packs already in `skills-lock.json`):

```bash
./scripts/install-skills.sh
```

This script installs curated packs, syncs gstack short names, and runs `openspec init` when Node ≥ 20.19.

Individual packs can still be added with the [skills CLI](https://github.com/vercel-labs/skills):

```bash
# Skill discovery (install first in any new repo)
npx skills add vercel-labs/skills --skill find-skills --agent cursor -y --copy

# Browser QA
npx skills add vercel-labs/agent-browser --skill agent-browser --agent cursor -y --copy

# Compound engineering lifecycle
npx skills add EveryInc/compound-engineering-plugin --agent cursor -y --copy

# Broad toolbox
npx skills add github/awesome-copilot --agent cursor -y --copy

# Microsoft (selective — avoid installing all 175+)
npx skills add microsoft/skills \
  --skill skill-creator --skill mcp-builder --skill github-issue-creator \
  --skill frontend-design-review --skill microsoft-docs \
  --agent cursor -y --copy

# Supabase / Postgres
npx skills add supabase/agent-skills --agent cursor -y --copy

# AWS development patterns (full toolkit)
npx skills add aws/agent-toolkit-for-aws --agent cursor -y --copy

# GitHub Spec Kit (spec-driven development — also installs .specify/ templates)
uv tool install specify-cli
specify init --here --integration cursor-agent --force

# 2026 curated additions
npx skills add nutlope/hallmark --skill hallmark --agent cursor -y --copy
npx skills add mvanhorn/last30days-skill --skill last30days --agent cursor -y --copy
npx skills add 24601/agent-deep-research --skill deep-research --agent cursor -y --copy
npx skills add nvidia/skills --skill rag-blueprint --skill aiq-research --agent cursor -y --copy
npx skills add remotion-dev/skills --skill remotion-best-practices --agent cursor -y --copy

# OpenSpec (Node >= 20.19) — creates openspec/ in repo
npx @fission-ai/openspec init -y

# gstack short slash names (required for Cloud Agents)
./scripts/sync-gstack-skills.sh

# Add a new ecosystem
npx skills add owner/repo --agent cursor -y --copy

# List installed
npx skills list

# Update all
npx skills update -y

# Search the registry
npx skills find "react performance"
```

### Optional stack-specific packs

```bash
# Sentry error monitoring
npx skills add getsentry/sentry-skills --agent cursor -y --copy

# Expo / React Native
npx skills add expo/skills --agent cursor -y --copy
```

Browse the public index at [skills.sh](https://skills.sh).

### gstack (virtual eng team)

gstack's `./setup --host cursor` installs skills under `~/.cursor/skills/gstack-*` (prefixed folder names). Slash commands like `/plan-ceo-review` and `/review` need **short folder names** (`plan-ceo-review/`, `review/`, …). Cloud Agents only load project `.agents/skills/` — not global `~/.cursor/skills/`.

After cloning or updating the vendor repo:

```bash
# One-time / refresh — copies 50 gstack skills with short names to .agents/skills/ (and ~/.cursor/skills/ when present)
./scripts/sync-gstack-skills.sh
```

Vendor clone (gitignored): `vendor/skills-repos/gstack`. Runtime binaries live under `.agents/skills/gstack/` (symlinks into the vendor tree).

**Key slash commands:**

| Command | Purpose |
| --- | --- |
| `/office-hours` | Product interrogation — start here for new ideas |
| `/plan-ceo-review` | CEO/founder strategic plan review |
| `/plan-eng-review` | Engineering architecture plan review |
| `/plan-design-review` | Design plan review |
| `/review` | Pre-landing PR / diff review |
| `/qa` | Browser QA on a staging URL |
| `/ship` | Land the PR with checks |
| `/investigate` | Root-cause debugging |
| `/autoplan` | End-to-end planning workflow |
| `/cso` | Security audit (OWASP + STRIDE) |
| `/gstack-upgrade` | Update gstack install |

Note: `--host cursor` does not apply `--no-prefix` today (generated `.cursor/skills/gstack-*` trees keep the prefix). Use `sync-gstack-skills.sh` for short names in this repo.

If another skill already owns a name (e.g. this repo's session `/retro` from continual-learning), the sync script skips the gstack skill and prints a warning.

## Project agent configuration

Matt Pocock skills read from:

| File | Purpose |
| --- | --- |
| `docs/agents/issue-tracker.md` | GitHub Issues on `praxstack/ledger-atlas` |
| `docs/agents/triage-labels.md` | Default five-role triage vocabulary |
| `docs/agents/domain.md` | Single-context domain doc layout |
| `CLAUDE.md` | Agent skills summary block |

pstack model overrides: `~/.cursor/rules/pstack-models.mdc`

### Verification skill (optional)

For project-local browser verification harnesses, run `/create-verification-skill` after setup. This generates a `verify-*` skill tailored to the app's real UI flows.

## Directory layout

```
.agents/skills/          # Project skills (committed — works in Cloud Agents)
  find-skills/
  agent-browser/
  poteto-mode/
  ce-work/
  plan-ceo-review/       # gstack (short slash names)
  review/
  qa/
  ship/
  ...
.cursor/skills/          # Spec Kit + OpenSpec workflow skills
.openspec/               # OpenSpec config, specs, changes (after init)
.specify/                # Spec Kit templates, scripts, constitution
docs/agents/             # Per-repo agent configuration
  praxstack-personas.md
  high-end-operator.md
scripts/
  install-skills.sh          # Full project skills installer
  install-praxstack-skills.sh # Praxstack skills-and-personas only
  sync-gstack-skills.sh      # gstack → short slash-command names
vendor/skills-repos/     # Git clones for reference (gitignored)
  skills-and-personas/   # praxstack/skills-and-personas
.cursor/rules/
  praxstack-skills.mdc   # Always-on skill routing
.cursor/environment.json # Cloud Agent environment config
CLAUDE.md                # Agent skills entry point
```

## Notes

- Project skills in `.agents/skills/` are loaded by Cursor automatically ([docs](https://cursor.com/docs/skills)).
- Global skills in `~/.cursor/skills/` are **not** copied to Cloud Agents — keep workflows in the repo (run `./scripts/sync-gstack-skills.sh` to mirror gstack into `.agents/skills/` with short slash names).
- `agent-browser` CLI: install with `npm install -g agent-browser --prefix ~/.npm-global` then `agent-browser install`.
- gstack's browse binary is installed globally; browser QA skills need Playwright/Chrome.
- Review skill security assessments at [skills.sh](https://skills.sh) before enabling in sensitive repos.
- Microsoft skills: only 5 of 175+ installed selectively to avoid context rot. Install more on demand with `--skill <name>`.
- **Not installed** (context rot): full `microsoft/skills`, full `wshobson` 94-plugin pack, global `everything-claude-code`.
- NVIDIA: only 4 of 340+ skills installed. Add more with `--skill <name>` on demand.
