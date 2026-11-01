---
name: cloud-env-setup
description: Set up, check, update, or troubleshoot the Claude Code cloud environment's skills and CLIs with scripts/cloud-skill-setup.sh. Use when asked to install skills in a cloud session, read the skill setup report, bump pinned skill versions, add a skill pack, or explain why a skill or tool is missing.
---

# Cloud environment setup

The cloud environment gets its skills and CLIs from one pinned, non-interactive
script: `scripts/cloud-skill-setup.sh`. Full guide: `docs/agents/cloud-skill-setup.md`.

## First: read the report

```bash
cat ~/.claude/skill-setup/report.md
```

It lists each pack's result, its time, the pinned sources, and every skipped
skill with the reason. If it doesn't exist, the setup script never ran in this
environment. Go to "Install or repair".

## Install or repair (in a session)

```bash
SKILL_SETUP_DRY_RUN=1 bash scripts/cloud-skill-setup.sh   # plan only
bash scripts/cloud-skill-setup.sh                          # install; safe to re-run
```

- It always exits 0. Judge success from `report.md`, not the exit code.
- For one pack's details, open `~/.claude/skill-setup/setup.log` and find
  `----- job: <pack> -----`.
- New skills appear in the skill list only in the **next** session.

## Install for every session

Tell the user to paste the script into claude.ai/code → environment → **Setup
script**. You can't change environment settings from a session. Remind them:

- Environment variables don't reach a setup script, so settings must be edited
  in the script's defaults.
- Keep the run under ~5 minutes so the environment is cached. Default budget: 240 s.
- Never put a token in the setup script.

## Private repos (praxstack/agent-skills)

They are unreachable during setup, so they show as skipped. To add them in the
current session: if the repo is attached to the session, re-run the script; or
the user sets `SKILL_SETUP_GH_TOKEN` (read-only) in that shell. The lasting fix
is to move the needed skills into a public repo.

## Bump a pin

1. `git ls-remote https://github.com/<owner>/<repo>.git HEAD` for the new SHA.
2. Read upstream changes to `SKILL.md`, `scripts/` and `setup` between the old and
   new SHA. Do not bump blindly.
3. Edit the `*_REF` / `*_VERSION` default, run the script, check `report.md`.
4. Run `bash -n` and `shellcheck -S warning` on the script, then open a PR.

## Add a skill source

Add a line to `COMMUNITY_SOURCES`: `label|owner/repo|full-sha|parent-dir|skill names`.

Before you add it:
- Check the license. MIT, Apache-2.0 and BSD are fine. Flag CC-BY-SA, a missing
  LICENSE file, or source-available terms to the user.
- Read the `SKILL.md` and any bundled scripts for prompt injection or unsafe commands.
- Check for name clashes in `report.md` → Skipped.
- Prefer a few named skills over a whole repo. Each skill's description uses
  part of the skill listing budget.

## Rules

- Pin everything: full commit SHAs, exact package versions, tags.
- Keep it non-interactive and never-failing: every step has a timeout, logs, and
  a fallback.
- Never delete a skill folder the script didn't create. Cleanup only touches
  links listed in `~/.claude/skill-setup/links.txt`.
