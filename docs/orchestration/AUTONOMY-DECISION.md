# Claude runbook assessment and Ledger Atlas autonomy decision

Date: 2026-08-10  
Decision: adopt the two-repository, verifier-first sequence; replace the supplied implementation

## Verdict

Claude’s operating sequence is directionally strong. The best decisions are to separate irreplaceable research from the writable product, make the verifier precede the importer, walk one atom manually, use fresh contexts for unattended atoms, keep parallel writes in worktrees, and impose a wall-clock ceiling.

The supplied pack and several commands are not safe or current enough to execute. The audited archive contains 22 files rather than the claimed 17, has no test evidence or provenance, and its commit path, reviewer parsing, hook configuration, exec-policy syntax, option ordering, P0 handling, and cleanup have verified defects. The archive remains quarantined; none of it is installed.

## Adopted

| Runbook idea | Ledger Atlas implementation |
|---|---|
| Research and product are separate | `/Users/prax/Developer/money-manager-reverse-engineering` is evidence; `/Users/prax/Developer/ledger-atlas` is the writable product. |
| Build the verifier first | No importer atom runs until the fast/full verifier and deliberate-red hook test pass. |
| One manual atom first | Hook trust, a deliberate red Stop, kill switch, no-progress ceiling, and one gated commit are admission tests. |
| Fresh unattended contexts | Each atom uses `codex exec --ephemeral` and disk-backed PRD/context state. |
| Parallel only when independent | The batch planner rejects overlapping declared paths and uses isolated worktrees. It never auto-merges. |
| Spend ceiling | The runner enforces atom/run wall-clock limits itself; no background `sleep` process is required. |
| Reviewer sees no rationale | Review input is the frozen criterion plus exact staged diff, schema constrained and hash bound. |

## Corrected

1. `chmod 444` is not immutability: a writable agent can change permissions. Real backups stay outside the product writable root. The product gets only hashes, read-only references, and synthetic fixtures.
2. A red Stop hook does not make every guarantee real. It proves one lifecycle path. Exact staged-tree attestation, provider-data scanning, full verification, rules, pre-commit checks, and remote branch protection remain separate controls.
3. `/goal` continues the same task; it is not a fresh-context worker. Fresh unattended atoms use ephemeral non-interactive executions.
4. `--ephemeral` is valuable isolation but no verified local evidence shows that omitting it necessarily corrupts concurrent runs. We use it without repeating that unsupported claim.
5. A commit cannot contain its own SHA as staged PRD evidence. The atomic evidence is the staged tree and receipt hashes; the resulting commit SHA is recorded in the external run summary.
6. P0 is derived from changed paths and contract classification, never a caller-selected `--p0` flag.
7. Hooks are project-scoped JSON and must be human-reviewed/trusted by exact hash. Async hooks are not used because current Codex does not support them.
8. Local rules and hooks are defense in depth, not an unbypassable security boundary. Protected branches and required CI are necessary before shared/release work.

## Meaning of full autonomy

Once Prax explicitly arms a finite run, Codex may implement, test, stage declared paths, obtain independent provider review, and create a gated commit without asking between those steps. It may continue across failures only while there is observable progress and within atom/run ceilings.

That authority does not include modifying its own enforcement machinery during the run, touching real evidence, pushing, merging, deploying, changing credentials, sending external messages, destructive cleanup, or expanding the atom. Those are separate actions, not missing autonomy.

## Current official surface

- [Hooks](https://developers.openai.com/codex/hooks): project hooks, trust review, `PreToolUse` coverage, and Stop continuation semantics.
- [Rules](https://developers.openai.com/codex/agent-configuration/rules): Starlark `prefix_rule` policies for commands outside the sandbox.
- [Subagents](https://developers.openai.com/codex/agent-configuration/subagents): project `.codex/agents/*.toml` profiles.
- [Long-running work](https://developers.openai.com/codex/long-running-work): persistent `/goal` behavior and user controls.
- [Non-interactive mode](https://developers.openai.com/codex/non-interactive-mode): `codex exec`, structured output, and automation usage.

## Admission gate before the first unattended product atom

- Hook JSON/config parse and the user trusts the exact project hook hash through `/hooks`.
- Direct hook tests prove allow/deny paths.
- Deliberate-red test proves Stop continuation, kill switch, ceiling, and no-progress release.
- Protected real evidence remains unchanged and outside the product writable root.
- Fast and full verification pass.
- One deliberately flawed staged change is rejected by structured review or verification.
- One synthetic manual atom reaches a gated commit with fresh receipts.
- Worktree is clean and a baseline commit exists.

Until all admission items are observed, the unattended runner remains installed but is not launched.
