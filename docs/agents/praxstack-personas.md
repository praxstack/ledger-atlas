# Praxstack personas and team roles

Persona source material lives in the vendored clone at `vendor/skills-repos/skills-and-personas/` (gitignored). Installed skills in `.agents/skills/` are the canonical runtime form.

## Constellation team workflow

Cross-functional delivery workflow coordinated by `/constellation-team`:

```
Product Manager → Principal Engineer (Checkpoint 1) → Backend + Frontend
  → QA/Security → Principal Engineer (Checkpoint 2) → DevOps/SRE
```

| Role | Skill | Slash command |
| --- | --- | --- |
| Product Manager | `product-manager` | `/product-manager` |
| Principal Engineer | `principal-engineer` | `/principal-engineer` |
| Backend system design | `backend-system-design-expert` | `/backend-system-design-expert` |
| Frontend UI/UX | `frontend-uiux-designer` | `/frontend-uiux-designer` |
| QA / Security | `qa-security-engineer` | `/qa-security-engineer` |
| DevOps / SRE | `devops-sre-engineer` | `/devops-sre-engineer` |
| Full team orchestration | `constellation-team` | `/constellation-team` |

Source personas: `vendor/skills-repos/skills-and-personas/team-personas/constellation-team/` and `md-personas/CONSTELLATION-TEAM.md`.

## Architecture and deep reasoning

| Persona | Skill | When to use |
| --- | --- | --- |
| Kingmode | `kingmode` | Architecture, security, reliability, system design depth |
| Super Mode | `super-mode-core` | Cross-domain reasoning, production-grade delivery |
| Apex autonomous | `apex-autonomous-mode` | High-autonomy execution with guardrails |
| Orchestrion router | `orchestrion-universal-agent-router` | Route tasks to the right specialist skill |

## Backend language specialists

| Skill | Language / stack |
| --- | --- |
| `backend-pe` | General backend principles |
| `backend-pe-typescript` | TypeScript |
| `backend-pe-javascript` | JavaScript |
| `backend-pe-nodejs` | Node.js |
| `backend-pe-python` | Python |
| `backend-pe-python-ml` | Python ML |
| `backend-pe-java` | Java |
| `backend-pe-cpp` | C++ |
| `backend-architecture-standards` | Cross-language architecture standards |

## Frontend and design

| Skill | Purpose |
| --- | --- |
| `frontend-pe` | Frontend engineering principles |
| `frontend-design-excellence` | Visual design and polish |
| `frontend-excellence-standards` | Frontend quality standards |
| `ultrathink-frontend` | Deep frontend reasoning |
| `svg-logo-designer` | Logo and icon design |

## Learning and mentoring personas

| Skill | Persona |
| --- | --- |
| `techtutor` | Adaptive technical teaching |
| `teach-pro-max` | Evidence-oriented teaching system (public distribution) |
| `gabriel-petersson-topdown-mentor` | Top-down learning mentor |
| `lecture-alchemist` | Transform lectures into learning artifacts |
| `professor-alex-interview` | Technical interview preparation |

## Personal intelligence

| Skill | Purpose |
| --- | --- |
| `chronicle` | Personal journal intelligence |
| `idea-capturer` | Capture and organize ideas |
| `concept-cartographer` | Map concepts and relationships |
| `baron-von-markup` | Structured document authoring |

## Document production

| Skill | Purpose |
| --- | --- |
| `blueprint-creator` | Technical blueprints |
| `spec-creator` | Specification documents |
| `transcript-pipeline` | Multi-stage transcript processing |
| `transcribe-refiner` | Transcript refinement |

## Agent operations

| Skill | Purpose |
| --- | --- |
| `coding-agent-leadership-principles` | Evidence, ownership, scoped authority |
| `cross-agent-handoff` | Privacy-safe transfers across agents |
| `superimprove` | Bounded audit-fix-review-verify loop |
| `autonomous-orchestrion` | Multi-agent orchestration |
| `obsidian-cli` | Obsidian vault automation |

## Mental health (scoped)

`mental-health-screening-companion` provides screening instrument guidance with crisis resources. See `vendor/skills-repos/skills-and-personas/SAFETY.md` for scope and attribution.

## Source material layout

| Path in vendor clone | Contents |
| --- | --- |
| `new-skills/` | Canonical portfolio (installed to `.agents/skills/`) |
| `skills/` | Extended skills including `teach-pro-max`, `superimprove`, etc. |
| `personas/` | Multi-file persona packs (Teach Pro Max, Chronicle, etc.) |
| `md-personas/` | Single-file Markdown persona prompts |
| `team-personas/` | Constellation team role definitions |
| `knowledge-packs/` | Reference material (ATLAS, Gabriel Petersson) |
| `prompts/high-end-operator/` | Lifecycle paste-prompt family (see `high-end-operator.md`) |
| `prompts/project-alignment/` | Project alignment and install prompts |
