# Ledger Atlas triage labels

Use this closed vocabulary in GitHub and Linear.

| Label | Meaning |
|---|---|
| `needs-triage` | Scope, priority, dependency, or acceptance criteria are not yet settled. |
| `needs-info` | Progress requires a specific owner decision or missing evidence. |
| `ready-for-agent` | Blockers are closed, scope is bounded, and acceptance criteria can be executed safely by an agent. |
| `ready-for-human` | The next action needs human-supervised authority, judgment, credentials, or an irreversible/external gate. |
| `wontfix` | Deliberately declined; the close reason must explain why. |

Exactly one readiness label should be active. Dependency order alone does not prove
readiness; the named blocker, acceptance criteria, and required evidence must be clear.
