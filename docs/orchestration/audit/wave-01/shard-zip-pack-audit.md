# Wave 01 — Forensic and security audit of `files.zip`

Date: 2026-08-10  
Auditor: Codex subagent `zip_pack_audit`  
Source: `/Users/prax/Downloads/files.zip`  
Disposition: **QUARANTINE — safe to retain as inert evidence, not safe to install or run as supplied**

## Executive verdict

The archive itself is not encrypted, is structurally intact, and contains no path-traversal entries, links, or unexpected binary executables. It was safely extracted into a private temporary directory only after both archive member lists were checked. Every regular file was inspected. No script, hook, installer, or model command from the archive was executed.

The proposed harness is nevertheless **not an enforceable commit/review system**. It contains multiple critical fail-open paths, destructive installation guidance, an invalid inline hook configuration for the installed Codex version, commands that do not parse on that version, no bundled tests despite the claimed functional testing, and no provenance, signature, SBOM, or test transcript. The most important promise—“nothing commits without review and testing”—is not true of this pack.

Do not copy this archive into `~/.codex/skills`, do not merge its config, and do not run its smoke-test cleanup. Salvage only the high-level ideas after reimplementation and adversarial tests.

## Chain of custody and archive safety

### Outer archive

- Size: `39,954` bytes
- SHA-256: `99158b34b6460bc572055ac306757465c07c5d8bd9404110310df1f8c2252c1a`
- Filesystem timestamp observed: `2026-08-10T03:33:20+0530`
- Format: ZIP 2.0, deflate, one disk, four entries, no encryption, no archive comment
- `unzip -t`: all four CRC checks passed
- Path check: all four names are relative, contain no `..` component, and are regular files

| Outer member | Bytes | SHA-256 |
|---|---:|---|
| `codex-orchestrion-v1.tar.gz` | 23,880 | `f81c94c236e40866466cb6eb3453a6286ec6ec688eda52550be5d327c8c1d92a` |
| `codex-orchestrion-SKILL.md` | 16,979 | `624a3c23a30e2b5a9fdaef3e485ed0185a81ef624470b490fc7316a85a9a6d0c` |
| `codex-orchestrion-INSTALL.md` | 8,472 | `402448d55510a301ec6b18a9a08dd4364ca2910ebee90a360cc8fc7c89e67703` |
| `codex-surface-reference.md` | 8,390 | `5aa625c7e2eb58afae18b26bf12bf6313462dcd544ff0c4214173b56c53d1125` |

### Nested tarball

- Gzip SHA-256: `f81c94c236e40866466cb6eb3453a6286ec6ec688eda52550be5d327c8c1d92a`
- Uncompressed tar SHA-256: `081eb21cb26688bd5a4e39d21bfbf86072e092557ea401cf7d660bbd0a9ecd38`
- Uncompressed tar size: `81,920` bytes including tar padding
- Contents: 22 regular files totaling `59,187` bytes, plus directories
- Member safety: one relative top-level directory, no absolute paths, `..` components, symlinks, hardlinks, devices, FIFOs, or further nested archives
- Metadata: tar entries record owner/group as `root:root`; this is provenance metadata, not evidence of trusted authorship
- The three loose Markdown files are byte-identical to their corresponding files inside the tarball

The Claude reply says the tarball contains “17 files.” It actually contains **22 regular files**. There are seven executable shell scripts, five agent TOMLs, four prompt/schema files, three configuration examples, and three documentation/reference files.

| Nested member | Bytes | SHA-256 |
|---|---:|---|
| `INSTALL.md` | 8,472 | `402448d55510a301ec6b18a9a08dd4364ca2910ebee90a360cc8fc7c89e67703` |
| `SKILL.md` | 16,979 | `624a3c23a30e2b5a9fdaef3e485ed0185a81ef624470b490fc7316a85a9a6d0c` |
| `assets/agents/implementer.toml` | 1,318 | `35ca51543d8289d12fbdd4f0853a1b172e42b09578973c9c64227e117de5f9a4` |
| `assets/agents/red-team.toml` | 1,247 | `110989f141f65a0adbf472c2b501e8965a995b58efb61eaa8f749ca70513e89c` |
| `assets/agents/reviewer.toml` | 1,569 | `5cf7443a37f706cc695b8df9e1666a2df5d2547262b4c21f68f1fa7045e126c9` |
| `assets/agents/scout.toml` | 722 | `d68d76c879f49ccf6651760d26000092d1db955d4d20bec1f77328c231fcf90c` |
| `assets/agents/validator.toml` | 1,135 | `e1b32f29a7aa898fbcd8aa9e5887e6a63a5e21369d07ecd7605a7162a7b56ee8` |
| `assets/config.toml.example` | 1,616 | `895d061e53ed7764a76ad3adbfcc76e534d5fb3403a764f78e50e7a3a9f33087` |
| `assets/execpolicy.rules.example` | 543 | `17b1d0edb8950fa493da3eb865ec48d9acd9b69aa65ea8a080893310484f5412` |
| `assets/hooks.json.example` | 486 | `a0b455b631291c56e3fff2e1e79b35737eb62e4ebbd60fcd945edb3784891722` |
| `assets/prompts/atom.md` | 2,695 | `aa66733a9da6c15f08477a0f2d42a8ad7ffdeb7b08eca3c75860c0a66b515409` |
| `assets/prompts/prd.example.json` | 877 | `809bca1749839738e88bf3800c7f6216a10a3ad40dc7b822c714c239a4346abb` |
| `assets/prompts/prd.schema.json` | 1,021 | `946267eeab9fee3fb3cac8f6089bbbde10903726bb682df9d7646fb114a63c27` |
| `assets/prompts/spec-template.md` | 907 | `e2037163961645584e00e4a188433aa0d2c0dfc60115dd8e4e3746d94f1347b7` |
| `assets/scripts/batch-fanout.sh` | 1,769 | `f3cc39a7b40905e06532b9a104d1b73dad3a5504aceef03307e43b754f195617` |
| `assets/scripts/gate-commit.sh` | 1,794 | `4e2c3a4b5d2389690d366e7929560cff0a70a4fabaf4373fa76bd60895f4e0d6` |
| `assets/scripts/hook-pretool-guard.sh` | 1,372 | `78846d0cfb0a7eb32e966a8d4138ca269bc2f37459c3057eaa4fa1b1254989b7` |
| `assets/scripts/hook-session-start.sh` | 1,199 | `300bbf4f4cdad458e9b425856d418ebf7857b54ff61615f814daf338e5f01852` |
| `assets/scripts/hook-stop-gate.sh` | 2,288 | `2d34f7288f5205111688024da2a35068421cb66b2290f2f4cf4be03cfed4efb4` |
| `assets/scripts/orchestrion-loop.sh` | 1,326 | `2e69a7b701e96f708e361599207ea9e01e24aa8bb3de27f2d91f111e1864ac6b` |
| `assets/scripts/verify.sh` | 1,462 | `d1b28d13b6e22f90b465b2c6b40997a8d219e0bad738b677cce49e11b40bbd03` |
| `reference/codex-surface.md` | 8,390 | `5aa625c7e2eb58afae18b26bf12bf6313462dcd544ff0c4214173b56c53d1125` |

## Checks performed

1. ZIP metadata, entry names, types, CRCs, encryption state, comments, and hashes.
2. Tar member names, types, permissions, ownership metadata, nested-archive check, extraction into `/private/tmp/mm-zip-audit.xt0gKx` only, and per-file hashes.
3. Full manual inspection of every one of the 22 regular files.
4. Static `shellcheck -x` over all seven scripts: no ShellCheck diagnostics. This proves shell syntax/style only, not correct behavior or safety.
5. `jq empty` over the three JSON files: syntactically valid JSON.
6. Local Codex parser/config probes in isolated `CODEX_HOME` directories, using installed `codex-cli 0.147.0`. No archive hook or script was run.
7. Read-only comparison with the current repository shape. The repository has `pyproject.toml` and Python tests; it has none of the supplied Ledger binding's `Package.swift`, `Sources/`, `fixtures/`, `mmctl`, or existing `scripts/` assumptions.

One isolated Codex startup probe attempted its normal plugin/provider network initialization. Network access was restricted and failed; no archive code was involved and no successful external transfer was observed.

## Local Codex surface: what was and was not verified

Observed on `codex-cli 0.147.0`:

- `goals`, `hooks`, and `multi_agent` are reported as stable and enabled.
- `codex exec --ephemeral` exists.
- `--full-auto` is rejected as an unknown argument. That part of the Claude description is accurate for this binary.
- `codex exec --ask-for-approval never ...` and `codex exec -a never ...` are both rejected when the approval option is placed after the `exec` subcommand. The option parses when placed globally before `exec`. Every archive script places it after `exec`, so those invocations fail before a model run.
- The supplied inline TOML hook fragment fails config loading with: `invalid type: sequence, expected a string` at `[[hooks.SessionStart]]`. The loose `hooks.json` is valid JSON, but hook registration and event semantics were deliberately not exercised because that would execute archive hooks.
- `[features].codex_hooks = true` is accepted only as a deprecated alias and emits guidance to use `[features].hooks`.
- The archive's claimed execpolicy location and syntax were not proven. Existing local historical rules use `rules/default.rules` and `prefix_rule(...)`, whereas the pack proposes `.codex/execpolicy.rules` with `deny "..."`. Treat the supplied policy as non-enforcing until an exact 0.147 loader/deny test passes.

## Claim audit against the Claude reply

| Claim | Evidence-based result |
|---|---|
| “17 files” | False: the tarball contains 22 regular files. |
| “all syntax-checked” | Partially reproducible for shell and JSON, but the supplied inline hook TOML is rejected by Codex 0.147. |
| “hooks functionally tested” | No bundled test, transcript, fixture, expected-output file, or receipt supports this. The inline hook config does not load. |
| Stop gate blocks red and releases green | Not established by the archive. No test suite is included, and running untrusted hooks was outside this audit. |
| Iteration ceiling, kill switch, no-progress escalation tested | The code exists, but no evidence of those tests exists. Static inspection found malformed-state and stale-counter defects. |
| Guard truth table has eight passing cases | No truth table or test file is present. The case-insensitive regex change exists, but many bypasses remain. |
| `gate-commit.sh` is the only commit path | False. It is a convention, not a control. Direct `git commit` remains available and no local or remote enforcement requires a gate receipt. |
| P0 always gets cross-model review | False. P0 is caller-selected, batch fan-out omits `--p0`, and a missing `claude` binary silently skips the review. |
| Reviewer receives only diff and criterion | False as an isolation claim. The Codex review process can read the repository and loaded instructions; the Claude process receives the full staged diff. Neither is hermetic. |
| Sandbox + execpolicy make evidence immutable | False as supplied. `workspace-write` permits workspace writes; the hook admits it may miss non-shell writes; and the policy has not been shown to load. Checksums detect changes after the fact but do not prevent them. |
| Ledger Atlas binding is ready | False for this checkout. It assumes a Swift package, `mmctl`, fixtures, and tests that do not exist here. |

## Critical findings

### C-01 — All autonomous and reviewer Codex invocations use an invalid CLI option position

`batch-fanout.sh:20-24`, `gate-commit.sh:16-21`, and `orchestrion-loop.sh:16-20,29-30` call `codex exec ... --ask-for-approval never`. On local 0.147 this is rejected as an unexpected `exec` argument. The same defect appears in the documentation examples. The actual scripts therefore do not perform implementation, review, or validation on this installed CLI.

Recommendation: pin an exact supported CLI version and put globally scoped options before the subcommand, then make CLI-parser smoke tests part of CI.

### C-02 — The commit gate can pass without testing the staged changes it claims to inspect

`gate-commit.sh:7` runs verification **before** `git add -A` at line 9. `verify.sh:30-35` inspects only `git diff --cached` for skipped tests. In the documented workflow the implementer does not stage, so the skip-test check sees an empty staged diff; the files are staged only after verification and verification is not rerun. This is a direct bypass of the advertised test-integrity gate.

`verify.sh` also exits successfully when no recognized manifest or checksum file exists. A no-op green is possible.

Recommendation: require a clean baseline, stage an explicit atom allowlist, compute the staged-tree hash, then run both focused and full verification against that exact staged tree. Fail closed if no verification adapter is configured.

### C-03 — P0 review is optional in practice and the audit message can lie

`gate-commit.sh:25-31` performs cross-model review only if the caller passes `--p0` **and** `claude` is installed. If Claude is missing, the gate silently proceeds. `gate-commit.sh:39` still writes `+ cross-model` based only on the caller flag.

`batch-fanout.sh:27` invokes the gate without `--p0` for every atom, even if `prd.json` says `"p0": true`. Thus the advertised Ledger import/data-loss atoms skip cross-model review in the batch path.

Recommendation: derive P0 from validated task data, not a caller flag; fail closed when a required reviewer is unavailable; and store a signed/hashed review receipt before committing.

### C-04 — Reviewer verdict parsing is spoofable and is not schema-validated

`gate-commit.sh:33` accepts any output containing a case-insensitive substring like `"verdict": "pass"`. It does not require valid JSON, a single object, an exit code plus schema conformance, or the absence of a later fail verdict. A quoted example, issue description, malicious diff echo, or mixed output can satisfy the grep.

The process is described as a named reviewer subagent, but the script merely tells a generic `codex exec` prompt that it is the reviewer. It does not prove that `.codex/agents/reviewer.toml` was loaded.

Recommendation: use `--output-schema`, capture stdout separately from diagnostics, validate one exact JSON object with `jq -e`, reject unknown fields/multiple verdicts, bind the verdict to the staged-tree hash, and test adversarial outputs.

### C-05 — `git add -A` captures unrelated user work

`gate-commit.sh:9` stages every tracked, modified, deleted, and untracked path in the worktree. There is no initial dirty-tree snapshot or atom path allowlist. This can commit unrelated user work and secrets. On review failure, `git reset` unstages the user's pre-existing staging state.

Recommendation: refuse a non-clean baseline or record and preserve it exactly; stage only declared atom paths; never use whole-tree reset as gate cleanup.

### C-06 — The durable audit state is written after the commit

`gate-commit.sh:35-40` commits first and appends the `COMMIT` journal line afterward. `atom.md:39-41` tells the agent to mark `prd.json` done and append `ATOM_DONE` after the gate has committed. The evidence and task state are therefore left dirty and become candidates for an unrelated later `git add -A` commit.

Recommendation: create the review/verification receipt and task-state transition before the commit; stage them with the atom; make the commit atomic; verify the resulting commit tree hash.

### C-07 — Installation and smoke-test instructions can overwrite or destroy user work

`INSTALL.md:28-44` copies scripts, agent files, and templates over existing project paths without a preflight, manifest comparison, backup, or refusal on collision. Installation is not idempotent and appends duplicate `.gitignore` entries.

More seriously, `INSTALL.md:95` cleans up the smoke test with `git checkout .`, which discards all tracked unstaged work in the repository, not only the synthetic test mutation. This violates the user's dirty-work preservation requirement.

Recommendation: install into a disposable clone first; use a manifest-driven patch with collision checks; clean only an exact synthetic file after verifying its pre-test hash; never use repo-wide checkout/reset cleanup.

### C-08 — Global hooks run project-relative scripts and can trap unrelated work

The installation recommends user-global `~/.codex/hooks.json`, while every hook command is `./scripts/...` and all matchers are `*`. In unwired repositories the scripts do not exist. In wired repositories every Stop event runs full verification even when no orchestrion task is active. A red suite can force up to 25 continuations on an ordinary session.

Recommendation: use project-scoped hooks, an explicit active-run sentinel with a run ID, a default-off posture, validated bounded counters, and a fail-safe release when the harness is absent or unhealthy.

### C-09 — External reviewers receive the entire staged diff without a data-governance gate

For P0, `gate-commit.sh:25-29` sends `.orchestrion/atom.diff` to the Claude CLI. The Codex reviewer also sends the diff to the configured model provider. The pack has no secret scan, repository classification, user opt-in, redaction, maximum size, binary handling, provider policy, or audit of what left the machine.

Recommendation: classify data first, scan/redact, prohibit binary/secret-bearing diffs, require explicit provider authorization per repository, and support a local/offline reviewer path.

## High-severity findings

### H-01 — The supplied inline hook TOML is invalid on the installed Codex

`assets/config.toml.example:35-50` uses `[[hooks.SessionStart]]`-style arrays. In an isolated `CODEX_HOME`, Codex 0.147 rejects it with `invalid type: sequence, expected a string`. This makes the primary merge example unusable. The JSON alternative was not functionally exercised.

### H-02 — The “immutable evidence” guard is trivially bypassable

`hook-pretool-guard.sh:14-16` allows the entire payload whenever it contains tokens such as `cat `, `ls `, `shasum`, `mode=ro`, or `--dry-run`. A destructive command followed by `; ls ` can bypass that check. The regex inspects raw hook JSON rather than a parsed command field and misses redirections, alternate tools, interpreters, `find -delete`, `truncate`, `rsync --delete`, encoded paths, `apply_patch`, and MCP writes.

The test deletion guard covers only `rm` and `mv` shapes. The Git guard misses `git -C`, aliases, `push -f`, multiple spaces, and other history-rewrite forms. No included eight-case truth table exists.

### H-03 — `workspace-write` cannot make in-workspace evidence immutable

The pack repeatedly treats the sandbox as one of three independent evidence-immutability controls. A normal workspace-write sandbox authorizes writes within the workspace. If execpolicy or the Bash hook does not observe a non-shell write, fixtures remain writable. A checksum is detection, not prevention.

Put source evidence outside writable roots, mount/copy it read-only, or use OS permissions/immutable snapshots plus a verified working copy. Keep checksums as an additional detection layer.

### H-04 — Untrusted output is promoted into future model instructions

`hook-stop-gate.sh:33-45` writes raw verification output into `JOURNAL.md` and then into a Stop continuation reason. `hook-session-start.sh:20-23` injects the raw journal tail into every new model context. Test output, filenames, fixture content, and compiler messages can therefore become prompt injection with system-like persistence.

Treat tool output as inert data, escape/control delimiters, store full logs outside prompt context, inject only a typed summary generated by trusted code, and cap size.

### H-05 — Sequential loop references a file the installer never copies

`orchestrion-loop.sh:20` reads `assets/prompts/atom.md` relative to the project. The installer copies agents and scripts, plus individual SPEC/PRD templates, but never creates project `assets/prompts/atom.md`. The unattended loop therefore starts with a missing prompt even after following the documented install steps.

### H-06 — Loop progress and final success are not enforced

`orchestrion-loop.sh:23` considers **any** commit with a timestamp in the last two minutes evidence that the iteration committed. It is not bound to the current branch, atom, starting HEAD, or run ID. It ignores per-iteration success, proceeds after failed model invocations, and runs a final validator even after hitting the ceiling with unfinished atoms. Validator output is appended but not parsed into a blocking verdict.

### H-07 — Batch fan-out hides failures and does not validate task input

`batch-fanout.sh` does not validate `prd.json` against its schema, atom ID safety, uniqueness, dependency existence, cycles, or `MAXJOBS`. It word-splits atom IDs, builds sibling-directory/log paths from them, creates branches/worktrees outside the repo, and has no cleanup or cancellation protocol. A failed `codex exec` still reaches the “finished” message; background failures are not reliably aggregated into a nonzero batch result.

Parallel worktrees also begin with separate copies of `prd.json` and `JOURNAL.md`, inviting state conflicts on merge.

### H-08 — Counter/state files are unvalidated and stale across successful runs

`hook-stop-gate.sh` reads arithmetic values directly from workspace files without validating them as bounded decimal integers. A malformed or hostile value can break comparisons/arithmetic. A green verify resets only `iters`, not `last_sig` or `same_count`, so a future run can be misclassified as a third identical failure based on stale history.

### H-09 — There is no actual “only commit path” enforcement

Nothing denies ordinary `git commit`, requires a gate receipt in a commit hook, or enforces checks at the remote branch. Even a perfect `gate-commit.sh` would be bypassable. Hard guarantees require server-side branch protection/required CI plus local convenience gates; local hooks alone can be bypassed with `--no-verify`.

### H-10 — Autonomous capability installation violates its own pinning rule

`SKILL.md:263-275` instructs the agent to install missing tools and even run `codex update`, while recommending `npx skills@latest`. That is both unpinned and globally mutating, contradicting “pin the version.” It also expands scope and supply-chain risk without a specific allowlist, review, checksum, lockfile, or approval boundary.

## Medium findings and completeness gaps

- No LICENSE, author identity, source repository, release tag, signing key, detached signature, SBOM, dependency lock, build recipe, or reproducible archive instructions are present.
- The reference's “138 repos / over 20%,” Uber budget, and “2026 consensus” claims have no citations or underlying data.
- The PRD schema does not set `additionalProperties: false`, require `deps`, enforce unique atom IDs, validate dependency references, prohibit cycles, or require evidence for done/parked states. The runtime scripts do not invoke the schema at all.
- Agent TOMLs specify effort but no pinned model/version. “Smart subagents” is a prompt role, not a reproducible capability contract.
- Review independence is overstated. Review processes can load user/project config, skills, AGENTS instructions, and repository content; `--ignore-user-config` is not used and no hermetic reviewer workspace is created.
- Passing the whole diff in a command-line argument can exceed OS argument limits and exposes content to process inspection. Use a bounded file/stdin protocol.
- `verify.sh` checks only a small set of skip markers. It does not detect deleted assertions, narrowed fixtures, test rewrites, disabled suites, coverage loss, or a test command changed to pass trivially.
- The pack calls the sub-90-second gate sufficient for commit but supplies no `verify-full.sh` or mandatory pre-commit full suite. That does not meet the user's “extensive review and testing” requirement.
- The Stop hook can repeatedly run an expensive suite and append unbounded logs. There is no wall-clock, token, dollar, disk, API-rate, or per-batch cap.
- `.orchestrion/` is globally ignored, so key loop logs and diffs are excluded from Git even while the design calls them durable evidence.
- No signal handling cleans up child processes or worktrees after interruption.
- No concurrency lock protects the gate, PRD, journal, iteration counters, or branch operations.
- The current repository is Python-based. The claimed Ledger binding is a future Swift sketch, not a tested binding to this checkout.

## What is worth salvaging

These concepts are useful after reimplementation:

- Keep constitution/instructions separate from changing project context.
- Decompose work into small acceptance-criterion atoms with explicit dependencies.
- Use read-only scouts in parallel and isolated worktrees for independent writes.
- Keep implementation, review, red-team, and final validation as distinct roles.
- Bind completion to observable verification evidence rather than model confidence.
- Use explicit iteration, no-progress, and kill-switch controls.
- Preserve unknown financial data rather than silently dropping it.

None of those design ideas requires trusting the supplied scripts.

## Required redesign before installation

1. **Pin and probe the host.** Declare a supported Codex range; run strict config, CLI parser, feature, hooks trust, agent schema, and execpolicy tests in a disposable fixture repo.
2. **Default to autonomous-without-commit.** Agents may research, implement, and verify; commit requires a valid gate receipt and the policy chosen by the user. Never infer push/merge/release authority.
3. **Use exact-scope staging.** Record baseline HEAD/status/index, reject or preserve unrelated dirty state, stage only declared paths, and bind every receipt to the staged-tree SHA-256/Git tree.
4. **Verify after staging.** Run focused checks plus a full pre-commit suite; fail when no adapter is configured; include fixture integrity, import reconciliation, loss accounting, migrations, security, and UI gates as the project grows.
5. **Make review machine-verifiable.** Use output schemas, exact JSON validation, independent/hardened review contexts, adversarial tests, and fail-closed P0 routing. Do not grep prose.
6. **Make state atomic.** Include PRD transition, journal summary, verification receipt, and review receipt in the same commit or a tamper-evident external ledger.
7. **Move hard enforcement outside model choice.** Use protected branches and required CI checks. Use local hooks/wrappers for ergonomics, not as the sole guarantee.
8. **Protect evidence physically.** Keep originals outside writable roots, access read-only, work on hashed copies, and verify hashes before and after every importer test.
9. **Contain prompts and logs.** Treat diffs, backups, test output, and journals as untrusted data; never inject raw output as instructions; redact secrets and cap size.
10. **Govern external calls and installs.** Require repository-level provider policy, secret scanning, explicit allowlists, pinned versions, hashes/signatures, and recorded approval for global mutation.
11. **Bound autonomy.** Enforce per-run wall-clock, iteration, token/cost, concurrency, and disk caps; support safe cancellation and resumable state.
12. **Use project reality.** Start with this repository's Python verification commands and current evidence corpus. Do not introduce Swift or `mmctl` gates until those artifacts actually exist.

## Minimum adversarial test matrix for a replacement

The replacement should ship tests and receipts for at least:

- archive path traversal, absolute paths, symlinks, hardlinks, duplicate paths, Unicode normalization, nested archives, decompression limits;
- strict config load, hook discovery/trust, every hook event, hooks disabled, missing hook executable, and unsupported versions;
- Stop green/red, missing verifier, malformed/negative/huge counters, ceiling, kill switch, stale signature reset, concurrent Stops, and verifier timeout;
- guard attempts via Bash, `apply_patch`, interpreters, redirection, MCP, encoded/absolute paths, `git -C`, aliases, and command chaining;
- gate with dirty baseline/index, unrelated untracked files, no-op verifier, deleted/weakened tests, invalid/multiple/contradictory reviewer JSON, reviewer crash, missing required cross-model reviewer, secret/binary/huge diff, commit-hook failure, and interrupted commit;
- P0 auto-detection from task metadata and changed paths, never caller memory;
- fan-out invalid IDs, bad dependency graph, duplicate IDs, partial job failure, cancellation, worktree collision, merge conflict, and log containment;
- state-machine crash points before/after verification, review, receipt, commit, PRD transition, and journal update;
- direct-commit bypass attempts and remote required-check enforcement.

## Final recommendation

Treat `files.zip` as a useful requirements sketch and negative test corpus, not an installable harness. Rebuild the Codex-native orchestration layer in this repository, preserve the original archive hash in the source ledger, and require the redesigned harness to fail all of the bypasses above before any user-level installation or autonomous commit path is enabled.
