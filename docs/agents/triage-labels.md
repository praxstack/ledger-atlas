# Ledger Atlas triage labels

Use this closed vocabulary in GitHub and Linear.

| Label | Meaning |
|---|---|
| `needs-triage` | Scope, priority, dependency, or acceptance criteria are not yet settled. |
| `needs-info` | Progress requires a specific owner decision or missing evidence. |
| `ready-for-agent` | Blockers are closed, scope is bounded, and acceptance criteria can be executed safely by an agent. |
| `ready-for-human` | The next action needs human-supervised authority, judgment, credentials, or an irreversible/external gate. |
| `wontfix` | Deliberately declined; the close reason must explain why. |

Exactly one readiness label should be active. Ticket 01 starts as `ready-for-human` because it changes the controls that govern autonomous work. Downstream tickets remain `needs-info` or `needs-triage` until their declared blockers close; dependency order alone does not confer authority.
