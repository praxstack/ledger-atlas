# Ledger Atlas

Next.js application for ledger/accounting workflows. See `README.md` for development setup.

## Agent skills

### Issue tracker

GitHub Issues on `github.com/praxstack/ledger-atlas` (via `gh` CLI). See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout (`CONTEXT.md` + `docs/adr/` at repo root). See `docs/agents/domain.md`.

### Praxstack skills-and-personas

45 custom skills from [praxstack/skills-and-personas](https://github.com/praxstack/skills-and-personas). Install/refresh: `./scripts/install-praxstack-skills.sh`. See `docs/agents/praxstack-personas.md` and `docs/agents/high-end-operator.md`.

### Skill routing

| When | Invoke |
| --- | --- |
| New product idea | `/office-hours` |
| Cross-functional delivery | `/constellation-team` |
| Spec / ticket | `/spec` or `/speckit-specify` |
| Implementation plan (no code) | `/writing-plans` |
| Pre-landing review | `/review` |
| Security audit | `/cso` |
| Create PR | `/ship` |
| Architecture depth | `/kingmode` |
| Teaching | `/techtutor` or `/teach-pro-max` |

Full routing: `.cursor/rules/praxstack-skills.mdc`
