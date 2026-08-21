# Wave 01 — source requirements and contradiction audit

**Status:** source audit complete  
**Scope:** the five textual artifacts assigned to this shard; `files.zip` was deliberately not inspected here.  
**Method:** every source was read in full. HTML body text, presentation metadata, and embedded scripts were inspected separately. Claims below are either direct source requirements or explicit audit conclusions; they are not a validation of the current Codex installation.

## Source inventory

| ID | Absolute source | SHA-256 | Size / shape | Role in this audit |
|---|---|---:|---:|---|
| S1 | `/Users/prax/Documents/Codex/2026-08-10/referenced-chatgpt-conversation-this-is-an/outputs/vibe-engineering-field-guide.md` | `4e7319cf925f92bac293352521dcc5bed3fe4ea92079e69950ab0581204632c4` | 92,599 bytes; 1,343 lines | Newer, evidence-labelled research guide; strongest textual source for general process design. |
| S2 | `/Users/prax/Documents/Codex/2026-08-10/referenced-chatgpt-conversation-this-is-an/outputs/vibe-engineering-field-guide.html` | `25fdb235900843694e4a408c6f1f2c2fb2e3a1ce73f12aa2fad945200580f1c5` | 159,300 bytes; 2,166 lines | Browser presentation of S1, plus search/filter/theme/copy/print behavior; contains stale hero counters. |
| S3 | `/Users/prax/Downloads/ledger-atlas-harness-pack.md` | `b2b1d3fba0eebe9ef32387b846dc584df0f1980c0b8457faf2342dd21571696f` | 14,626 bytes; 348 lines | Ledger Atlas-specific proposed constitution, Claude hook, ADRs, loop, certification matrix, and work order. It is a design proposal, not an installed or tested harness. |
| S4 | `/Users/prax/Downloads/vibe-engineering-field-manual_1.html` | `709b976894d696b42780907ce33269c365e959b761c04e732d5751b13f81f835` | 168,115 bytes; 1,905 lines | Older/broader research manual (`Rev. 2`, 20 systems, 6 harnesses, about 45 sources). Useful for ideas, but materially stale against S1/S2. |
| S5 | `/Users/prax/.codex/attachments/ba62d81a-dced-4a25-90cd-4e3f4639f980/pasted-text.txt` | `36223284db193db1154c4e1dbe354115e3e99e708e79022663e88e5c46d54d7d` | 7,960 bytes; 61 lines | Rationale that led to S3. It contains useful framing but also project assertions and guesses without locators. |

## Duplicate and variant findings

1. **S1 and S2 are companion formats, not byte duplicates.** Their content structure and substantive guide text match, while S2 adds a responsive UI, theme persistence, full-text/filter controls, code-copy buttons, print rules, reduced-motion handling, and TOC observation. S2's hero reports **84 source records / 67 claims** at lines 227–228, while its own body reports **89 / 74** at line 1973, matching S1 line 1254. The browser header is stale; S1's canonical body numbers should win.
2. **S4 is not an HTML rendering of S1.** It describes 20 systems, 6 harnesses, 10 primitives, 5 playbooks and about 45 sources (`S4:264–269`), while S1/S2 describe 16 system profiles, 11 harness surfaces and 89/74 research counts. It also carries older installation/version guidance. Treat S4 as an earlier editorial branch, not a second source of current truth.
3. **S3 and S5 are tightly related but not duplicates.** S5 supplies the argument and project framing; S3 turns much of it into proposed files/contracts. Repetition between them is corroboration of authorship, not independent evidence.

## Requirements that survive synthesis

### 1. One owner for each process layer

Adopt one delivery/specification lifecycle, a small repository contract, selectively loaded specialist procedures, deterministic verification, independent review, and human-controlled irreversible actions. Do not install multiple full workflow owners. This is stated directly in S1 (`S1:7`, `S1:40–42`, `S1:57`) and S4 (`S4:392`).

For Ledger Atlas, the sources converge on this division:

| Layer | Proposed owner | Required boundary |
|---|---|---|
| Product and compatibility truth | Versioned evidence ledger, certified-profile matrix, ADRs | No universal compatibility claim; gaps remain visible. |
| Per-change contract | One lightweight spec/change system or plain reviewed change contract | Do not let a second system create a competing plan/task truth. |
| Execution | Codex goal/task loop plus narrow reusable skills | Only machine-checkable tasks can run autonomously. |
| Coordination | Bounded subagents and worktrees | One writer per file/module; explicit ownership; bounded nesting/concurrency. |
| Verification | Repository `verify` entry point, conformance corpus, focused/full tests | The model's “done” statement is not evidence. |
| Integration | Independent diff reviews and a commit/merge gate | Reviewers receive a fixed contract and final diff; merge/deploy remain human/platform gated. |

Evidence: goal contract and human gates (`S1:809–853`), loop rules (`S1:855–875`), parallel-worker and concurrency requirements (`S1:877–910`), deterministic CI and agent-system evals (`S1:930–953`), long-running autonomy boundary (`S1:1158–1162`).

### 2. Autonomy is conditional, budgeted, and test-shaped

Every autonomous loop needs a fixed accepted goal, explicit scope, allowed tools/data, iteration/time/cost limits, a no-progress threshold, machine-checkable success, and a completion receipt. It must stop for ambiguous product judgment, repeated identical failure, flaky/non-reproducible tests, credentials, external actions, destructive changes, or exhausted budget.

S3 proposes one importer loop only: maximum 3 subagents per tick, 25 iterations and `$10`; success requires zero silently dropped items, passing Swift tests, and unchanged fixture hashes; three identical failures block (`S3:259–284`). S1 supports the shape but is more precise about stop conditions (`S1:809–875`).

**Do not loop UI taste or parity decisions.** The UI may use bounded implementation batches after a human-approved screen contract, but visual/product acceptance remains human/multimodal review. S3 explicitly excludes `App/` and the 98-screen surface from its autonomous importer loop (`S3:284–287`).

### 3. Delegation is a graph, not a crowd

Subagents should be used only for independent research questions, disjoint modules, platform variants or separate review lenses. Each receives an owned file/module set, accepted goal/evidence, output schema, separate worktree for writes, budget and stop condition. Reviewers must not modify the implementation they review. Cross-cutting design is resolved before implementation is parallelized (`S1:877–910`).

The durable minimum state per work item is: ID, owner, dependencies, base commit/worktree, acceptance checks, status, review receipt, and blockers. A task database is optional until a checked-in task list stops scaling.

### 4. Nothing commits merely because tests are green

The sources require both specification-driven and test-driven evidence. A commit gate should require:

1. accepted, immutable-for-review change contract;
2. clean or explicitly baselined starting state;
3. focused checks plus the full deterministic gate;
4. generated-file consistency, static/type/lint, unit/property/integration/conformance tests, security/secret/dependency checks, and packaging/install smoke as applicable;
5. fresh-context specification-compliance review;
6. separate architecture/quality and security/privacy review for risky diffs;
7. resolved decision-critical findings or an explicit human waiver;
8. a completion receipt recording exact commands, exit status, evidence, residual risk and actions not taken.

S1 enumerates the deterministic gate and agent eval corpus at `S1:930–945`, human gates at `S1:947–953`, and the completion receipt at `S1:955–966`. S4 correctly notes that final tests alone can miss architecture and product constraints (`S4:1299–1306`). **Cross-vendor review is optional defense-in-depth, not a proved requirement:** S4 and S3 assert that same-model review necessarily shares blind spots (`S4:1177`, `S3:301`), while S1 says a fresh context and fixed artifact boundary matter more and the same model family can fill the roles (`S1:895–900`).

### 5. Installation is a reviewed supply-chain event

Before installing any skill/plugin/tool: verify the current upstream release and license, inspect the manifest and every executable/instruction file, use an isolated profile/repository, pin a revision, record generated diffs and paths, inspect hooks/MCP/network/telemetry/credentials, test uninstall/update/discovery, then run one representative task and one denial-path test (`S1:1240–1248`; `S4:1661–1667`). A mutable `latest`, raw remote shell pipe, GitHub star count, or prose claim is not sufficient approval.

## Ledger Atlas product and compatibility contract extracted from S3/S5

### Strong requirements

- **Clean-room implementation:** behavioral and data compatibility only; do not copy/decompile vendor code or reuse proprietary assets, artwork, strings or a pixel-for-pixel interface (`S3:27–29`). Feature coverage can be exhaustive while the visual language remains original.
- **Source immutability:** source backups/evidence are never modified and are opened read-only; record pre/post hashes (`S3:24–26`). The actual enforcement must work for Codex and operating-system paths, not only Claude.
- **Lossless-or-loud import invariant:** every source row and field is canonically mapped, preserved verbatim with provenance, or reported; `dropped_silently == 0` is a release gate (`S3:30–33`; `S5:39`).
- **Evidence taxonomy:** behavior interpretations carry O (observed), D (documented), B (data-backed), or U (unknown); U cannot ship without a linked reviewed decision record (`S3:34–35`, `S3:83–121`; `S5:49`).
- **Certified profiles instead of universal promises:** compatibility means a named format/schema/build profile with a passing suite and reviewed loss report. Uncertified inputs are best-effort and must be lossless-or-loud; they are not guaranteed (`S3:36–38`, `S3:309–328`; `S5:29–31`).
- **Architecture seam:** canonical ledger logic contains no vendor concepts; vendor parsing/sidecars/loss reports live in an adapter; a headless CLI provides import/reconcile/diff/loss-report checks; UI remains thin (`S3:53–73`; `S5:41–47`).
- **Initial product wedge:** macOS, local file, import/browse/edit/reports before accounts, sync, iOS, Android, cloud, sharing or PC Manager (`S3:44–51`; `S5:37`). This is a proposed sequencing decision, not a permanent product limitation.

### Ledger Atlas opening atoms found in the assigned sources

The assigned text does not contain the `ORC-001` name from the quoted Claude reply; that may exist only in `files.zip`, which this shard was instructed not to inspect. The Ledger-specific opening sequence actually present is S3's order at lines 335–348:

1. **Preserve photo sidecars:** copy the Android photo directory to a controlled, hashed, read-only evidence location before device loss or cleanup.
2. **Land the operating boundary:** short human-authored repository contract, real path controls, source manifest/checksums and one `verify` command.
3. **Run corpus differentials:** analyze type `7`, `PERIOD_TYPE=6`, transfer fees, card settlement, reset semantics and unresolved linkage fields; write provisional ADRs with row/query evidence.
4. **Build the verifier before the importer:** package skeleton, `mmctl`, reconciliation and loss-report contracts.
5. **Reach L3 for the observed Android v19 profile:** field coverage, canonical reconciliation and lossless sidecar/loss reporting before claiming certification.
6. **Build the UI by evidence family:** O/D-backed screens first; U-backed behavior waits for a decision record. Do not place UI taste inside an unattended loop.
7. **Dogfood locally:** use the macOS build on the synthetic/redacted test profile first, then a controlled migration of the owner's data outside repository/test/prompt artifacts.
8. **Friend migration pilot:** only named certified profiles, readable loss reports, backup/rollback, and explicit unsupported-profile messaging.
9. **Treat sync as a later product:** separate threat model, account/key/recovery design and cross-platform contract; do not hide its complexity in the importer architecture.

## Contradictions and unsafe details to resolve before adoption

| Finding | Evidence | Required correction |
|---|---|---|
| S3 says real financial data must never enter the repo/tests/logs/prompts, then instructs an agent to analyze `fixtures/money_android.sqlite` and cite real row IDs. | Privacy rule `S3:39–41`; corpus prompt `S3:240–253`. | Keep real source data outside Git and agent prompts. Run a local redacting inspector that emits bounded structural/statistical evidence, or use an explicitly user-authorized private analysis path with scrubbed logs. `fixtures/` should remain synthetic. |
| The proposed “physical” immutability control is Claude-only and string-based. It is not a Codex control and is bypassable/overblocking. | `.claude/settings.json` and grep hook `S3:128–186`; stronger structured-payload rules in `S1:769–787`. | Implement OS/filesystem read-only placement plus Codex sandbox/exec policy after local capability verification. Parse structured arguments, resolve canonical paths, deny writes independent of keyword exceptions, and test allow/deny fixtures. Hash checks detect mutation but do not prevent it. |
| The post-edit formatter hides every failure with `2>/dev/null || true` and assumes `$FILE`. | `S3:149–151`. | Use the actual hook payload, preserve exit codes/output, and keep formatting separate from policy. Do not silently turn red into green. |
| S3's certification example pre-marks L1/L2/L3 as passed before the described skeleton/importer work exists. | Table `S3:315–321`; order says build verifier/importer later at `S3:340–342`. | Start all unverified levels as pending; populate checkmarks only from stored test receipts. |
| “Uncertified files are still accepted” overpromises formats/wrappers the parser may not even open. | `S3:323–328`. | Say “detected and rejected losslessly/loudly unless a parser can safely unwrap it”; never promise preservation of bytes/fields that were never parsed, except preserving the original input file itself. |
| The type-7 provisional decision excludes rows from all balances/reports before the proposed included-vs-excluded reconciliation experiment is run. | Decision `S3:214–225`; experiment `S3:240–253`. | Defer aggregation semantics until data-backed reconciliation. Preserve and surface the rows meanwhile; do not silently choose a total. |
| `Decimal in minor units` is underspecified, and instant+timezone can destroy date-only/vendor raw semantics. | `S3:71–73`. | Specify integer minor-unit or arbitrary-precision decimal semantics per currency, rounding rules and scale. Preserve raw date/time text/value, source timezone/locale, semantic kind (instant/local date) and parsed canonical value. |
| S5 says the missing semantics oracle is “small,” then says only round-trip and unseen-version quirks are genuinely oracle-bound. That is too strong for a parity claim. | `S5:17–19`, `S5:29–31`. | Corpus analysis can reduce unknowns, not prove vendor intent, ordering, restore behavior, error handling, hidden settings or cross-version quirks. Keep each as U until observed/documented/data-proved or intentionally diverged by ADR. |
| S5 says every missing screen/state can be generated from standards. | `S5:25`. | Standards can generate a coherent replacement UI, accessibility behavior and defensive states; they cannot prove one-to-one vendor parity or hidden functionality. Label generated states as product decisions, not observations. |
| Absence of type 7 from XLSX is treated as evidence the exporter has “no mapping.” | `S3:207–209`; similar inference in `S5:27`. | Absence only proves absence in this export. Filtering, deletion state, configuration, build logic and exporter omission remain competing hypotheses. |
| The manual and guide disagree on current integrations and commands. Examples include Superpowers Codex installation, OpenSpec versions/adapters, Beads architecture/setup and GStack host handling. | Older S4 examples `S4:495–505`, `S4:578–604`, `S4:869–898`; newer S1 profiles `S1:133–167`, `S1:195–224`, `S1:445–476`. | Prefer current local capability probes and primary upstream docs. Never install from S4's copied command without revalidation. |
| S4 claims Codex lifecycle hooks (`SessionStart`, `PreToolUse`, `PostToolUse`) and a native `/goal` without source-local proof. | `S4:1153`, `S4:1391`, `S4:1436`. | Treat these as hypotheses until the installed Codex CLI/app and official OpenAI documentation confirm exact syntax, payload, blocking semantics and surface availability. Do not port Claude hook JSON or Stop exit codes by analogy. |
| S1/S2 contradict themselves on HTML research counts. | `S2:227–228` versus `S2:1973`; S1 `S1:1254`. | Regenerate the browser artifact from the canonical Markdown or update the hero counters; add an artifact-consistency test. |

## Unsupported or weakly supported assertions

These may be useful leads, but the five artifacts do not independently prove them:

- Project corpus counts and relationships: 7,026 rows, 8 type-7 rows, 1,478 photo paths, byte-identical `.mmbak`/SQLite, 27 added and 1 edited transaction (`S5:15–17`, `S5:27`, `S5:35`). They require direct database/query/hash evidence in the repository's evidence ledger.
- “Most of the six resolve to B” / “four of six” / “two of six” are guesses (`S3:253–255`; `S5:27`, `S5:59`), not estimates with a sampling method.
- “Same-model review shares blind spots by construction” and mandatory cross-vendor review (`S3:301`; `S4:1177`) overstate evidence. Independence of context, rubric and contract is required; model diversity is a risk-based addition.
- S4's precise adoption, star, productivity, token-reduction, cost, prompt-approval and benchmark figures are not evidence-linked at the individual-claim level in the HTML. S4 itself concedes that no complete methodology has independent academic evaluation (`S4:1654–1659`).
- Current Codex hook, policy, plugin, model and `/goal` semantics are drift-prone and must be live-verified. S1 explicitly says catalog/feature claims and installers were not executed and can change (`S1:1270–1278`).

## Recommended adjudication

Use **S1 Markdown as the canonical general operating reference**, regenerate S2 from it, retain S4 only as an idea/source index, and treat S3/S5 as an untrusted proposal to be rewritten against verified local Codex primitives and direct corpus evidence.

The resulting Codex-native design should preserve five non-negotiable properties:

1. one accepted source of truth per layer;
2. lossless-or-loud vendor import with named certification profiles;
3. bounded worktree-isolated delegation with explicit ownership;
4. deterministic verification plus fresh independent review before any commit path;
5. autonomous continuation only for objective checks, with iteration/no-progress/cost stops and no merge/deploy/destructive authority.

