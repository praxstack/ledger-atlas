# High-end operator workflow goals

Paste prompts from the vendored `prompts/high-end-operator/` tree in `vendor/skills-repos/skills-and-personas/`. These are **prompts that invoke installed skills** — they do not copy skill bodies.

## Steady loop

```
/spec → /plan (or writing-plans) → /build (one failing test) → /review → /ship
```

One tree, one turn. Do not load every skill every session.

## Workflow trees

| Tree | Path in vendor clone | Job |
| --- | --- | --- |
| Router | `prompts/high-end-operator/00-router/` | Short always-on routing (under 200 lines) |
| Think | `01-think/` | Office hours, brainstorm, align |
| Plan | `02-plan/` | Spec, writing-plans, OpenSpec |
| Build | `03-build/` | One TDD slice, then stop |
| Review | `04-review/` | Diff review, design, CSO |
| Test | `05-test/` | qa-only, qa, health |
| Ship | `06-ship/` | Ship, land-and-deploy |
| Reflect | `07-reflect/` | Retro, learn |
| Debug | `08-debug/` | Investigate, systematic-debugging |
| Browser | `09-browser/` | scrape → skillify, browse |
| Research | `10-research/` | deep-research, last30days |
| Session gates | `11-session/` | Host `/plan`, `/context`, `/compact`, `/security-review` |

Full catalog: `vendor/skills-repos/skills-and-personas/prompts/high-end-operator/CATALOG.md`

## Skill routing (always-on)

This block is also in `CLAUDE.md` and `.cursor/rules/praxstack-skills.mdc`.

| When | Invoke |
| --- | --- |
| New product idea | `/office-hours` |
| Lost the thread | wait-what + blank-stare; see project-alignment prompts |
| Spec / ticket | `/spec` or `/speckit-specify` |
| Implementation plan (no code) | `/writing-plans` |
| One TDD slice | `/tdd` or test-driven-development |
| Pre-landing review | `/review` |
| Live UI polish | `/design-review` |
| Security audit | `/cso` |
| Report-only QA | `/qa-only` |
| Find and fix QA | `/qa` |
| Create PR | `/ship` |
| Broken / unexpected | `/investigate` or `/systematic-debugging` |
| Cross-functional delivery | `/constellation-team` |
| Architecture depth | `/kingmode` or `/backend-system-design-expert` |
| Teaching / mentoring | `/techtutor` or `/teach-pro-max` |

## Project alignment prompts

For reconstructing a project after a long break:

| Prompt file | Use when |
| --- | --- |
| `prompts/project-alignment/ALIGN-INSTALL-QA.md` | Reconstruct + install packs + report-only QA |
| `prompts/project-alignment/ALIGN-ONLY.md` | Alignment only |
| `prompts/project-alignment/INSTALL-SKILLS.md` | Install named packs only |

## Hard rules

- Do not hand-copy gstack, Superpowers, or Matt Pocock skill files into this repo.
- Use `/browse` or `/agent-browser` for live pages — not ad-hoc browser MCP tools when gstack browse exists.
- Official host gates (`/plan`, `/context`, `/compact`, `/code-review`, `/security-review`) are host built-ins.
- Praxstack custom skills (`kingmode`, `constellation-team`, etc.) extend — not replace — gstack and Superpowers workflows.
