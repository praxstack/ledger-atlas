# Cloud skill setup (`scripts/cloud-skill-setup.sh`)

One script that gives every Claude Code cloud session the same skills and CLIs,
with no agent involved. Paste it into the environment's **Setup script** box, or
run it by hand. It is pinned, parallel, logged, and always exits 0.

## How it works

```
 claude.ai/code starts a new cloud session
                │
                ▼
 ┌─────────────────────────── setup script (root, before Claude starts) ───────────────────────────┐
 │                                                                                                  │
 │  Phase 1: every download in parallel, one shared time budget (240 s default)                     │
 │  ┌────────┐ ┌────────┐ ┌────────┐ ┌──────┐ ┌──────────┐ ┌──────────┐ ┌─────────┐ ┌───────────┐   │
 │  │ gstack │ │ tstack │ │ pstack │ │ matt │ │ personas │ │ openspec │ │ speckit │ │ graphify  │…  │
 │  │clone + │ │ clone  │ │ clone  │ │clone │ │  clone   │ │clone+npm │ │ uv tool │ │uv + install│   │
 │  │ setup  │ └────────┘ └────────┘ └──────┘ └──────────┘ └──────────┘ └─────────┘ └───────────┘   │
 │  └────────┘    each job: own log, exit code, time; network errors retried, auth errors not        │
 │                                                                                                  │
 │  Phase 2: link skills in priority order (first pack to claim a name wins)                        │
 │     gstack → tstack → pstack → superpowers → matt → personas → openspec → graphify →             │
 │     hyperframes → uizze → community → anthropic → research → extras                              │
 │                                                                                                  │
 │  Phase 3: cleanup stale links · PATH snippet · skill listing budget · report                      │
 └──────────────────────────────────────────────────────────────────────────────────────────────────┘
                │  finished in < ~5 min  →  Anthropic snapshots the disk (environment cache)
                ▼
 later sessions start from the snapshot: skills already on disk, setup script skipped
 (the cache rebuilds when the script or network settings change, or after ~7 days)
```

Measured in a cloud container on 2026-11-01: **49 s** from an empty home folder,
**16 s** on a re-run, **36 s** with GitHub unreachable (every pack reported as
failed, exit code still 0).

## Set it up

1. Open claude.ai/code → your environment → **Setup script**.
2. Paste the whole of `scripts/cloud-skill-setup.sh` (about 40 KB; the box takes
   up to 64 KB) or choose the file. Save.
3. Start a new session and ask Claude to read `~/.claude/skill-setup/report.md`.

To change what it installs, edit the defaults at the top of the script before
pasting. Environment variables set in the environment's settings do **not**
reach the setup script (the docs say they are applied after it runs), so the
values have to live in the script itself. Environment variables do work when
you run the script by hand:

```bash
SKILL_PACKS="tstack matt openspec" bash scripts/cloud-skill-setup.sh
SKILL_SETUP_DRY_RUN=1 bash scripts/cloud-skill-setup.sh    # prints the plan, changes nothing
```

## What gets installed

| Pack | Source | License | What you get | Needs |
|---|---|---|---|---|
| gstack | garrytan/gstack | MIT | ~60 `gstack-*` skills: review, QA, ship, CSO, office hours | bun (pre-installed) |
| tstack | t3dotgg/tstack (or praxstack/agent-skills/tstack) | MIT | council, babysit-pr, file-pr, full-send, takeover, sol-loop… | python3, gh |
| pstack | praxstack/cursor-plugins | MIT | 45 pstack skills (architect, arena, blast-radius, principles…) | — |
| superpowers | obra/superpowers | MIT | brainstorming, TDD, systematic debugging, writing/executing plans | — |
| matt | mattpocock/skills | MIT | grilling, to-spec, to-tickets, diagnosing-bugs, codebase-design… | — |
| personas | praxstack/skills-and-personas | MIT | new-skills portfolio + chosen skills + 7 team agents | — |
| openspec | Fission-AI/OpenSpec | MIT | `openspec` CLI 1.16.0 + 12 `openspec-*` skills | Node 20+ |
| speckit | github/spec-kit | MIT | `specify` CLI v1.2.5 | uv |
| graphify | Graphify-Labs/graphify (PyPI `graphifyy`) | Apache-2.0 | `graphify` CLI + `/graphify` skill (codebase knowledge graph) | uv, Python 3.10+ |
| hyperframes | heygen-com/hyperframes | Apache-2.0 | 8 video skills, `npx hyperframes` pre-cached | Node 22, ffmpeg, Chrome (all pre-installed) |
| uizze | uizze/uizze | MIT + Apache-2.0 | anti-ui-slop, ui-design, ui-radar, image-to-ui | — |
| community | vercel-labs/skills, upstash/context7, microsoft/playwright-cli | MIT, MIT, Apache-2.0 | find-skills, find-docs (`ctx7`), playwright-cli | npm CLIs installed by the script |
| anthropic *(off)* | anthropics/skills | Apache-2.0 (only these) | skill-creator, mcp-builder, webapp-testing… | — |
| research, extras | praxstack/agent-skills (private) | — | deep-research, local-deep-research, your EXTRA_SKILLS list | a token, see below |

Every source is pinned to a full commit SHA, tag, or exact package version. The
exact list for a run is in `~/.claude/skill-setup/resolved.txt`.

## Decisions and why

| Topic | Decision | Why |
|---|---|---|
| Spec Kit vs OpenSpec | Install both CLIs. Use **OpenSpec** for this repo (it already has `openspec/`). Use Spec Kit for greenfield projects. | OpenSpec's delta specs fit brownfield change. Spec Kit's constitution and specify → plan → tasks loop fits new projects. Spec Kit writes into a repo, so the script only installs the CLI; run `specify init --here --integration claude` yourself in a repo that wants it. |
| llm-council-plus | **Not installed** | It's a web app (FastAPI + React) that needs OpenRouter API keys, not a skill. tstack's `council` skill does multi-model review inside Claude. |
| uizze-ui | Left out | It needs a paid hosted Uizze MCP. The four free uizze skills are installed. |
| anthropics/skills | Off by default | Your claude.ai account already ships them as `anthropic-skills:*`. `docx`, `pdf`, `pptx` and `xlsx` there are source-available, not open source, so the script never installs them. |
| remotion-dev/skills | Not installed | No LICENSE file, so all rights are reserved. hyperframes covers video. |
| Private `agent-skills` | Tried once, fails fast, falls back | See next section. |
| Skill count | Raises `skillListingBudgetFraction` to 0.03 (only if unset) | ~230 skills means ~57,000 characters of descriptions. The default budget is 1% of the context window, and past it Claude Code drops descriptions of the skills you use least, so it stops picking them automatically. |

## Private repos (praxstack/agent-skills)

A setup script runs **before** the environment's variables, network secrets and
the GitHub proxy are active, so it cannot read a private repo. The script tries
once, sees the auth error, skips the retries, and uses the public fallback
(t3dotgg/tstack for tstack). The research and extras packs are reported as
skipped.

To get them anyway, pick one:

1. **Make the skills public.** Move the skills you want into a public repo
   (for example skills-and-personas) and add them to `PERSONA_SKILLS`. This is the
   simplest option and stays deterministic.
2. **Re-run inside a session.** Add `praxstack/agent-skills` to the project's
   repositories, then ask Claude to run `bash scripts/cloud-skill-setup.sh`. Or
   set `SKILL_SETUP_GH_TOKEN` to a fine-grained, read-only token in that shell.
   The token is passed to git through `GIT_CONFIG_*` variables, scoped to
   `https://github.com/praxstack/`, and never written to the log. This only lasts
   for that session.

Don't paste a token into the setup script: anyone who can use the environment can
read the script, and the token would be saved in the cache snapshot.

## Opt-in candidates (researched, pinned, not on by default)

Add a line to `COMMUNITY_SOURCES` to turn one on (`label|repo|sha|parent|skill names`):

```
addy|addyosmani/agent-skills|8bfcc1f9916f2eea55494d8c1fa7f4bde867dd9e|skills|incremental-implementation documentation-and-adrs observability-and-instrumentation
vercel|vercel-labs/agent-skills|1a2c79d4e6c4a2283dc2c614b6538cbe1ed5ca62|skills|web-design-guidelines composition-patterns react-view-transitions
tob|trailofbits/skills|2be6433b39e009cd2b6fd3be1895f6b1faa5af9a|plugins/property-based-testing/skills|property-based-testing
```

| Repo | License | Why not on by default |
|---|---|---|
| addyosmani/agent-skills (112k★) | MIT | Overlaps heavily with superpowers and matt. Its `test-driven-development` would clash with superpowers'. |
| vercel-labs/agent-skills (33k★) | Says MIT, but there is no LICENSE file | Check the license before you depend on it. Your private extras list already carries `vercel-react-best-practices`. |
| trailofbits/skills (8k★) | CC-BY-SA-4.0 | Strong security-audit skills, but share-alike terms. Skills live under `plugins/<name>/skills/`. |
| getsentry/skills | Apache-2.0 | Its `code-review` and `security-review` would replace Claude Code's built-in commands of the same name. |
| nextlevelbuilder/ui-ux-pro-max-skill (143k★) | MIT | Your private extras list already has `ui-ux-pro-max`. |

Before you add anything: read its `SKILL.md` and any `scripts/` folder. Skills
run with your permissions, and a 2026 audit of public skill registries found
malicious skills that used prompt injection. Always pin a full commit SHA.

## Updating pins

1. Check upstream changes since the current pin, for example `git log <old>..<new>`
   on the upstream repo, and read anything that touches `SKILL.md`, `scripts/` or `setup`.
2. Update the `*_REF` / `*_VERSION` default at the top of the script.
3. Run `bash scripts/cloud-skill-setup.sh` in a session, then read
   `~/.claude/skill-setup/report.md`.
4. Paste the new script into the environment. The cache rebuilds on the next session.

## Troubleshooting

| Symptom | Check |
|---|---|
| A skill is missing | `report.md` → *Skipped*. Common reasons: another pack already claimed the name, it's in `SKIP_SKILLS`, or it's on your account. |
| A pack shows `failed` | `~/.claude/skill-setup/setup.log`. Look for the `----- job: <pack> -----` section. |
| `stopped at time budget` | Raise `SETUP_BUDGET_SECS`, but keep the whole run under ~300 s or the environment won't be cached. |
| A first session and a re-run differ | Account skills sync after the setup script, so only a re-run can see them and skip duplicates. To skip names on the first run too, use `SKIP_SKILLS`. |
| Claude doesn't pick a skill | Run `/doctor` or `/context` to see the skill listing size. Trim packs, or set rarely used skills to `"name-only"` in `skillOverrides`. |
| `graphify` changed `~/.claude/CLAUDE.md` | Expected. `graphify install` adds a 3-line pointer to its skill. Set `INSTALL_GRAPHIFY=0` to avoid it. |

## Files the script writes

| Path | What |
|---|---|
| `~/.claude/skills/<name>` and `~/.agents/skills/<name>` | Links to the pinned sources |
| `~/.claude/skills/gstack/` | gstack checkout (gstack requires this path) |
| `~/.claude/agents/*.md` | Team agents from skills-and-personas |
| `~/.claude/skill-setup/` | `src/` clones, `jobs/` logs, `report.md`, `report.json`, `resolved.txt`, `links.txt` |
| `~/.skill-setup-env` | PATH and telemetry defaults, sourced from `~/.bashrc` and `~/.profile` |
| `~/.claude/settings.json` | `skillListingBudgetFraction`, only if not already set |
