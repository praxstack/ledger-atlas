#!/usr/bin/env bash
# =============================================================================
# cloud-skill-setup.sh  v2.0.1
# Skills and tools for Claude Code cloud sessions (claude.ai/code environments).
#
# Runs with no agent and no questions. Every source is pinned. Downloads run in
# parallel under one time budget, so the run stays under the ~5 minute limit that
# lets Anthropic cache the environment. Every failure is logged and skipped.
# The script always exits 0, so it can never stop a session from starting.
#
# Packs, in priority order (the first pack to claim a skill name wins):
#   gstack       garrytan/gstack (MIT). Runs its own ./setup (needs bun).
#   tstack       Theo's skills incl. council. praxstack/agent-skills/tstack when
#                reachable, else t3dotgg/tstack (MIT).
#   pstack       praxstack/cursor-plugins/pstack (MIT).
#   superpowers  obra/superpowers (MIT). Skills only, no hook.
#   matt         mattpocock/skills (MIT): engineering, productivity, misc.
#   personas     praxstack/skills-and-personas: new-skills/, chosen skills/, agents.
#   openspec     OpenSpec CLI (npm) + openspec-* skills (Fission-AI/OpenSpec, MIT).
#   speckit      GitHub Spec Kit `specify` CLI (uv tool, MIT).
#   graphify     graphify CLI (uv tool) + its /graphify skill (Apache-2.0).
#   hyperframes  heygen-com/hyperframes video skills (Apache-2.0) + npm cache warm.
#   uizze        uizze/uizze UI design skills (MIT / Apache-2.0), free ones only.
#   community    vetted gap-fillers: find-skills, find-docs (Context7), playwright-cli.
#   anthropic    anthropics/skills, Apache-2.0 ones. OFF by default: the claude.ai
#                account already ships them as anthropic-skills:*.
#   research     deep-research, local-deep-research (praxstack/agent-skills).
#   extras       hand-picked list from praxstack/agent-skills (EXTRA_SKILLS).
#
# Not installed on purpose: llm-council-plus is a web app that needs OpenRouter
# keys, not a skill. tstack's `council` skill covers multi-model review.
#
# Use:
#   A) Paste this file into claude.ai/code > environment settings > Setup script.
#   B) Or run it in a session:  bash scripts/cloud-skill-setup.sh
#   Dry run (changes nothing):  SKILL_SETUP_DRY_RUN=1 bash scripts/cloud-skill-setup.sh
#
# Private repos: a setup script runs before the environment's variables, network
# secrets and GitHub proxy exist, so praxstack/agent-skills (private) cannot be read
# there. The script tries once, fails fast, and falls back. In a running session,
# or locally, set SKILL_SETUP_GH_TOKEN (read-only token) and re-run to add it.
# The token goes to git through GIT_CONFIG_* variables, never argv or the log,
# and only for https://github.com/praxstack/.
#
# Output:  ~/.claude/skill-setup/report.md   (read this first)
#          ~/.claude/skill-setup/report.json (machine readable)
#          ~/.claude/skill-setup/resolved.txt (every source and its exact commit)
#          ~/.claude/skill-setup/setup.log
#
# Override any setting with an environment variable or by editing the defaults:
#   SKILL_PACKS="tstack matt" SKILL_PROFILE=broad bash cloud-skill-setup.sh
# =============================================================================

if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "[skill-setup] needs bash 4 or newer (macOS: brew install bash); nothing installed" >&2
  exit 0
fi

SETUP_VERSION="2.0.1"

# ---------- settings ----------------------------------------------------------

SKILL_PACKS="${SKILL_PACKS:-gstack tstack pstack superpowers matt personas openspec speckit graphify hyperframes uizze community research extras}"

# core = curated lists (recommended). broad = also every skill in agent-skills and
# skills-and-personas/skills. Hundreds of skills crowd Claude's skill list.
SKILL_PROFILE="${SKILL_PROFILE:-core}"

# Skill names never to install, from any pack (space separated). Account skills
# sync into the container after this script runs, so it cannot see them; list
# here any local copy you don't want next to an account skill.
SKIP_SKILLS="${SKIP_SKILLS:-}"

# Skip Superpowers / Matt Pocock when their account plugin is visible (re-runs).
SKIP_IF_ON_ACCOUNT="${SKIP_IF_ON_ACCOUNT:-1}"

INSTALL_OPENSPEC_CLI="${INSTALL_OPENSPEC_CLI:-1}"
INSTALL_SPECKIT_CLI="${INSTALL_SPECKIT_CLI:-1}"
INSTALL_GRAPHIFY="${INSTALL_GRAPHIFY:-1}"
WARM_HYPERFRAMES_CLI="${WARM_HYPERFRAMES_CLI:-1}"
INSTALL_COMMUNITY_CLIS="${INSTALL_COMMUNITY_CLIS:-1}"

# Downloads still running after this many seconds are stopped and reported.
# Keep it under 300 so the environment cache can build.
SETUP_BUDGET_SECS="${SETUP_BUDGET_SECS:-240}"

# Skill listing budget, as a fraction of the context window (Claude Code default
# is 0.01). Written to ~/.claude/settings.json only when that key is not set yet.
# With ~200 skills the 1% default drops descriptions. Set empty to leave alone.
SKILL_LISTING_BUDGET_FRACTION="${SKILL_LISTING_BUDGET_FRACTION:-0.03}"

SKILL_COUNT_WARN="${SKILL_COUNT_WARN:-200}"
MIN_FREE_MB="${MIN_FREE_MB:-1500}"
SKILL_SETUP_DRY_RUN="${SKILL_SETUP_DRY_RUN:-0}"

# ---- pins: third-party. To update: read upstream changes, bump, re-test. ----
GSTACK_REF="${GSTACK_REF:-c1900088d55d7c9e11037b0df98133559af9a1a3}"
TSTACK_UPSTREAM_REF="${TSTACK_UPSTREAM_REF:-1085050f3baed1ac724caa4a8166145fb2ac88af}"
SUPERPOWERS_REF="${SUPERPOWERS_REF:-2ce8aa15d05bd57213e6f746f953aafb7ded7a8b}"
MATT_REF="${MATT_REF:-4ae2317ddb22b046e26455e4f9c9b3aaaf62212d}"
OPENSPEC_REF="${OPENSPEC_REF:-27c0515724decc633818c735ee596481eec78a8b}"
OPENSPEC_VERSION="${OPENSPEC_VERSION:-1.16.0}"
SPECKIT_TAG="${SPECKIT_TAG:-v1.2.5}"
GRAPHIFY_VERSION="${GRAPHIFY_VERSION:-0.9.100}"
HYPERFRAMES_REF="${HYPERFRAMES_REF:-af0d68d612ebd9c419f27d9ebc8068512667bae4}"
HYPERFRAMES_VERSION="${HYPERFRAMES_VERSION:-0.8.226}"
UIZZE_REF="${UIZZE_REF:-fc401e9e654cbafe427b0c98142fc8bccd0c4e7e}"
ANTHROPIC_SKILLS_REF="${ANTHROPIC_SKILLS_REF:-ca45fc496a3436251f191354091d557da31c15b5}"

# ---- pins: Prax's repos. Pinned for repeatable builds; `main` follows the branch. ----
PSTACK_REF="${PSTACK_REF:-465182b4ddffe141eeca774ee2c22d72f684553c}"
PERSONAS_REF="${PERSONAS_REF:-b47380c9b254ab26c655ef04dd69b9795b2bccfa}"
AGENT_SKILLS_REF="${AGENT_SKILLS_REF:-main}"   # private, so it cannot be pre-resolved

# ---- curated lists ----
EXTRA_SKILLS="${EXTRA_SKILLS:-api-design api-and-interface-design accessibility animation
  webapp-testing e2e-testing playwright-generate-test react-patterns react-performance
  react-testing vercel-react-best-practices security-review performance-optimization
  anti-slop frontend-design-pro hallmark ui-ux-pro-max svg-principal-engineer godplans last30days}"

PERSONA_SKILLS="${PERSONA_SKILLS:-teacher teach-pro-max superimprove coding-agent-leadership-principles
  cross-agent-handoff ultra-reasoning-operator measure-before-you-fix resolve-before-asking
  data-loss-gate repo-architecture testing fact-check}"

RESEARCH_SKILLS="${RESEARCH_SKILLS:-deep-research local-deep-research}"

HYPERFRAMES_SKILLS="${HYPERFRAMES_SKILLS:-hyperframes hyperframes-cli hyperframes-registry media-use
  remotion-to-hyperframes reverse-any-video slideshow figma}"

# uizze-ui is left out: it needs a paid hosted MCP.
UIZZE_SKILLS="${UIZZE_SKILLS:-anti-ui-slop ui-design ui-radar image-to-ui}"

# Apache-2.0 only. docx/pdf/pptx/xlsx are source-available, not open source.
ANTHROPIC_SKILLS="${ANTHROPIC_SKILLS:-skill-creator mcp-builder webapp-testing frontend-design
  web-artifacts-builder doc-coauthoring}"

# Community sources, one per line:  label|owner/repo|full-commit-sha|skills-parent-dir|skill names
# An empty "skill names" field links every skill under the parent dir.
# More vetted candidates (opt-in) are listed in docs/agents/cloud-skill-setup.md.
COMMUNITY_SOURCES="${COMMUNITY_SOURCES:-
findskills|vercel-labs/skills|92a9a34ac3bf88e695e468b90c7bf32f163d32c8|skills|find-skills
context7|upstash/context7|7836c583918374fbecffacf866afb7594b919466|skills|find-docs
playwright|microsoft/playwright-cli|0a808078d96496cf2a8fa725143c870354f63cda|skills|playwright-cli
}"
# Global npm CLIs those skills call. Pinned.
COMMUNITY_NPM="${COMMUNITY_NPM:-ctx7@0.8.2 @playwright/cli@0.1.23}"

# ---------- paths -------------------------------------------------------------

HOME="${HOME:-/root}"
CLAUDE_DIR="$HOME/.claude"
SKILLS_DIR="$CLAUDE_DIR/skills"
AGENTS_SKILLS_DIR="$HOME/.agents/skills"   # tstack's babysit-pr calls scripts by this path
AGENTS_DIR="$CLAUDE_DIR/agents"
STATE_DIR="$CLAUDE_DIR/skill-setup"
STORE="$STATE_DIR/src"
JOBS="$STATE_DIR/jobs"
LOG="$STATE_DIR/setup.log"
REPORT="$STATE_DIR/report.md"
REPORT_JSON="$STATE_DIR/report.json"
RESOLVED="$STATE_DIR/resolved.txt"
MANIFEST="$STATE_DIR/links.txt"
NEW_MANIFEST="$STATE_DIR/links.new"
LOCK="$STATE_DIR/lock"

# =============================================================================
main() {
set -u -o pipefail
umask 022

mkdir -p "$SKILLS_DIR" "$AGENTS_SKILLS_DIR" "$AGENTS_DIR" "$STORE" || {
  echo "[skill-setup] cannot create folders under $HOME; nothing installed" >&2
  return 0
}

export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false SSH_ASKPASS=/bin/false GCM_INTERACTIVE=never
export GIT_LFS_SKIP_SMUDGE=1 GIT_ADVICE=0 CI=1 DEBIAN_FRONTEND=noninteractive
export NPM_CONFIG_FUND=false NPM_CONFIG_AUDIT=false NPM_CONFIG_UPDATE_NOTIFIER=false
export UV_NO_PROGRESS=1 PIP_DISABLE_PIP_VERSION_CHECK=1
export OPENSPEC_TELEMETRY=0 DO_NOT_TRACK=1 DISABLE_TELEMETRY=1
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"

STATUS=(); SKIPPED=(); JSON_PACKS=()
declare -gA CLAIMED=() ACCOUNT=() SKIPSET=()
FAILED_ANY=0
START_EPOCH="$(date +%s)"
DRY=0; [ "$SKILL_SETUP_DRY_RUN" = 1 ] && DRY=1
for s in $SKIP_SKILLS; do SKIPSET["$s"]=1; done

HAVE_TOKEN=0
if [ -n "${SKILL_SETUP_GH_TOKEN:-}" ]; then
  _b64="$(printf 'x-access-token:%s' "$SKILL_SETUP_GH_TOKEN" | base64 | tr -d '\n')"
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0="http.https://github.com/praxstack/.extraheader"
  export GIT_CONFIG_VALUE_0="Authorization: Basic $_b64"
  unset _b64
  HAVE_TOKEN=1
fi

# ---------- helpers -----------------------------------------------------------

log()     { printf '[skill-setup] %s\n' "$*" | tee -a "$LOG" >&2; }
have()    { command -v "$1" >/dev/null 2>&1; }
elapsed() { echo $(( $(date +%s) - START_EPOCH )); }
pin()     { printf '%-20s %-40s %s\n' "$1" "$2" "$3" >>"$RESOLVED"; }
jesc()    { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "${s//$'\n'/ }"; }
wants()   { case " $SKILL_PACKS " in *" $1 "*) return 0 ;; esac; return 1; }
words()   { printf '%s ' $1; }   # normalise a multi-line list to one line

note() {  # note PACK RESULT SOURCE
  local secs=""
  [ -f "$JOBS/$1.secs" ] && secs="$(cat "$JOBS/$1.secs")s"
  STATUS+=("| $1 | $2 | $3 | $secs |")
  JSON_PACKS+=("{\"pack\":\"$(jesc "$1")\",\"result\":\"$(jesc "$2")\",\"source\":\"$(jesc "$3")\",\"secs\":\"$secs\"}")
  log "$1: $2 ($3)"
}
failed() { FAILED_ANY=1; note "$@"; }

run_for() {
  local secs="$1"; shift
  if have timeout; then timeout -k 10 "$secs" "$@"
  elif have gtimeout; then gtimeout -k 10 "$secs" "$@"
  else "$@"; fi
}

# retry CMD...: up to 3 tries (waits 2s, 4s) for network errors. Returns 3 at once
# for auth / not-found / bad-version errors, which a retry cannot fix.
retry() {
  local n=0 wait=2 out
  out="$(mktemp "$STATE_DIR/out.XXXXXX")"
  until "$@" >"$out" 2>&1; do
    cat "$out" >>"$LOG"
    if grep -qiE "could not read Username|Authentication failed|Repository not found|returned error: 40[34]|E404|ETARGET|No matching distribution|not found in the package registry|couldn't find remote ref|not our ref|unadvertised object|No solution found" "$out"; then
      rm -f "$out"; return 3
    fi
    n=$((n + 1))
    if [ "$n" -ge 3 ]; then rm -f "$out"; return 1; fi
    log "retry $n after ${wait}s: $(basename "$1") ${2:-} ${3:-}"
    sleep "$wait"; wait=$((wait * 2))
  done
  cat "$out" >>"$LOG"; rm -f "$out"
  return 0
}

free_mb() { df -Pm "$HOME" 2>/dev/null | awk 'NR==2 {print $4}'; }
enough_disk() {
  local free; free="$(free_mb)"
  [ -z "$free" ] && return 0
  [ "$free" -ge "$MIN_FREE_MB" ] && return 0
  log "only ${free} MB free, need ${MIN_FREE_MB} MB"; return 1
}
repo_slug() { local s="${1#https://github.com/}"; printf "%s" "${s%.git}"; }
real_dir() { (cd -P "$1" 2>/dev/null && pwd); }

# fetch_repo URL DEST REF [SPARSE_PATH...]
# Shallow, blob-less fetch of one ref (branch or full SHA) with optional sparse
# checkout. Reuses DEST when it already sits on the pinned SHA. Builds in a temp
# dir and swaps it in, so a failed fetch never leaves a half-broken copy.
fetch_repo() {
  local url="$1" dest="$2" ref="$3"; shift 3
  local tmp="$dest.tmp.$$" head rc
  if [ -d "$dest/.git" ] && [[ "$ref" =~ ^[0-9a-f]{40}$ ]] &&
     [ "$(git -C "$dest" rev-parse HEAD 2>/dev/null)" = "$ref" ]; then
    [ "$#" -gt 0 ] && git -C "$dest" sparse-checkout set "$@" >>"$LOG" 2>&1
    pin "$(basename "$dest")" "$(repo_slug "$url")" "$ref"
    return 0
  fi
  rm -rf "$tmp"
  git init -q "$tmp" >>"$LOG" 2>&1 || return 1
  git -C "$tmp" remote add origin "$url"
  if [ "$#" -gt 0 ]; then
    { git -C "$tmp" sparse-checkout init --cone && git -C "$tmp" sparse-checkout set "$@"; } >>"$LOG" 2>&1 ||
      { rm -rf "$tmp"; return 1; }
  fi
  retry run_for 180 git -C "$tmp" fetch -q --depth 1 --filter=blob:none origin "$ref"; rc=$?
  if [ "$rc" -ne 0 ]; then
    [ "$rc" = 3 ] && log "no access to $url @ $ref (private, missing, or bad ref); not retried"
    rm -rf "$tmp"; return 1
  fi
  if ! run_for 180 git -C "$tmp" -c advice.detachedHead=false checkout -q FETCH_HEAD >>"$LOG" 2>&1; then
    rm -rf "$tmp"; return 1
  fi
  head="$(git -C "$tmp" rev-parse HEAD)"
  rm -rf "$dest" && mv "$tmp" "$dest"
  pin "$(basename "$dest")" "$(repo_slug "$url")" "$head"
}

fm_field() {  # fm_field DIR KEY: a front-matter value from DIR/SKILL.md
  local f="$1/SKILL.md" key="$2"
  [ -s "$f" ] || return 0
  head -n 1 "$f" | tr -d '\r' | grep -qx -- '---' || return 0
  awk -v k="$key" 'NR>1 && /^---/ {exit}
    NR>1 && index($0, k":") == 1 {sub("^"k":[ \t]*", ""); gsub(/["\047\r]/, ""); print; exit}' "$f"
}

load_account_names() {
  local d
  for d in "$SKILLS_DIR"/synced/*/*/ "$CLAUDE_DIR"/plugins/synced/*/*/skills/*/; do
    [ -f "$d/SKILL.md" ] && ACCOUNT["$(basename "$d")"]=1
  done
  log "account skills visible now: ${#ACCOUNT[@]} (they normally sync after this script)"
}
account_has() { [ -n "${ACCOUNT[$1]:-}" ]; }

ours() {  # is PATH a link that this script made?
  local p="$1" t
  [ -L "$p" ] || return 1
  t="$(readlink "$p")"
  case "$t" in "$STORE"/*|"$SKILLS_DIR/gstack"/*) return 0 ;; esac
  [ -f "$MANIFEST" ] && grep -qxF "$p" "$MANIFEST"
}

# link_skill DIR LABEL: validate DIR, then link it into ~/.claude/skills and ~/.agents/skills.
link_skill() {
  local src="$1" label="$2" name dir target
  [ -e "$src" ] || { SKIPPED+=("$(basename "$src") ($label): broken link"); return 0; }
  dir="$(real_dir "$src")" || return 0
  name="$(fm_field "$dir" name)"
  if [ -z "$name" ]; then SKIPPED+=("$(basename "$src") ($label): no valid SKILL.md"); return 0; fi
  if ! [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]]; then
    SKIPPED+=("$name ($label): not a valid skill name"); return 0
  fi
  if ! grep -q '^description:' "$dir/SKILL.md"; then
    SKIPPED+=("$name ($label): no description"); return 0
  fi
  if [ -n "${SKIPSET[$name]:-}" ]; then SKIPPED+=("$name ($label): in SKIP_SKILLS"); return 0; fi
  if account_has "$name"; then SKIPPED+=("$name ($label): already on your account"); return 0; fi
  if [ -n "${CLAIMED[$name]:-}" ]; then
    SKIPPED+=("$name ($label): already taken by ${CLAIMED[$name]}"); return 0
  fi
  for target in "$SKILLS_DIR/$name" "$AGENTS_SKILLS_DIR/$name"; do
    if [ -e "$target" ] || [ -L "$target" ]; then
      if ours "$target"; then
        rm -f "$target"
      elif [ "$(real_dir "$target")" = "$dir" ]; then
        echo "$target" >>"$NEW_MANIFEST"; continue
      else
        [ "$target" = "$SKILLS_DIR/$name" ] && {
          SKIPPED+=("$name ($label): $target exists and is not ours"); return 0; }
        continue
      fi
    fi
    ln -s "$dir" "$target" && echo "$target" >>"$NEW_MANIFEST"
  done
  CLAIMED["$name"]="$label"
}

COUNT=0
link_all_under() {  # sets COUNT
  local parent="$1" label="$2" d
  COUNT=0
  [ -d "$parent" ] || return 0
  for d in "$parent"/*/; do
    [ -f "$d/SKILL.md" ] || continue
    link_skill "${d%/}" "$label"; COUNT=$((COUNT + 1))
  done
}
link_named() {  # sets COUNT
  local parent="$1" label="$2" n; shift 2
  COUNT=0
  for n in "$@"; do
    if [ -e "$parent/$n/SKILL.md" ]; then
      link_skill "$parent/$n" "$label"; COUNT=$((COUNT + 1))
    else
      SKIPPED+=("$n ($label): not found in source")
    fi
  done
}

# ---------- background jobs ---------------------------------------------------
# Phase 1 runs every download and install as a background job. Each job writes
# its own log, its exit code (JOB.rc), a short message (JOB.msg) and its time.
# Phase 2 links skills one pack at a time, in priority order.

declare -gA JOB_PID=()
bg() {  # bg NAME FUNCTION
  local name="$1" fn="$2"
  (
    exec 9>&-   # do not pass the run lock to jobs; a leftover daemon would hold it
    LOG="$JOBS/$name.log"; : >"$LOG"
    t0="$(date +%s)"
    "$fn"; rc=$?
    echo $(( $(date +%s) - t0 )) >"$JOBS/$name.secs"
    echo "$rc" >"$JOBS/$name.rc"
  ) </dev/null &
  JOB_PID["$name"]=$!
}
job_ok()  { [ "$(cat "$JOBS/$1.rc" 2>/dev/null)" = 0 ]; }
job_msg() { cat "$JOBS/$1.msg" 2>/dev/null; }
say()     { printf '%s' "$*" >"$JOBS/$CURRENT_JOB.msg"; }

kill_tree() {
  local p="$1" c
  for c in $(pgrep -P "$p" 2>/dev/null); do kill_tree "$c"; done
  kill -TERM "$p" 2>/dev/null
}

wait_all() {
  local name left
  while :; do
    left=0
    for name in "${!JOB_PID[@]}"; do kill -0 "${JOB_PID[$name]}" 2>/dev/null && left=$((left + 1)); done
    [ "$left" -eq 0 ] && break
    if [ "$(elapsed)" -ge "$SETUP_BUDGET_SECS" ]; then
      for name in "${!JOB_PID[@]}"; do
        if kill -0 "${JOB_PID[$name]}" 2>/dev/null; then
          log "$name: still running at the ${SETUP_BUDGET_SECS}s budget; stopped"
          kill_tree "${JOB_PID[$name]}"
          echo 124 >"$JOBS/$name.rc"; printf 'stopped at time budget' >"$JOBS/$name.msg"
        fi
      done
      sleep 2; break
    fi
    sleep 1
  done
  wait 2>/dev/null
  for name in $(printf '%s\n' "${!JOB_PID[@]}" | sort); do
    { echo "----- job: $name -----"; cat "$JOBS/$name.log" 2>/dev/null; } >>"$LOG"
  done
}

# ---- job bodies (no shared state: they only write files) ----

AGENT_SKILLS="$STORE/agent-skills"
job_agent_skills() {
  CURRENT_JOB=agent_skills
  if [ "$SKILL_PROFILE" = broad ]; then
    enough_disk || return 1
    fetch_repo https://github.com/praxstack/agent-skills.git "$AGENT_SKILLS" "$AGENT_SKILLS_REF"
  else
    # shellcheck disable=SC2046
    fetch_repo https://github.com/praxstack/agent-skills.git "$AGENT_SKILLS" "$AGENT_SKILLS_REF" \
      tstack $(words "$RESEARCH_SKILLS") $(words "$EXTRA_SKILLS")
  fi
}

job_gstack() {
  CURRENT_JOB=gstack
  local dir="$SKILLS_DIR/gstack"
  if [ -f "$dir/.skill-setup-$GSTACK_REF" ]; then
    pin gstack garrytan/gstack "$GSTACK_REF"; say "already installed"; return 0
  fi
  enough_disk || { say "not enough disk"; return 1; }
  if ! have bun && have npm; then
    log "bun missing; trying npm install -g bun"
    run_for 120 npm install -g bun >>"$LOG" 2>&1 || true
    hash -r
  fi
  have bun || { say "bun is not installed"; return 1; }
  fetch_repo https://github.com/garrytan/gstack.git "$dir" "$GSTACK_REF" || { say "clone failed"; return 1; }
  if (cd "$dir" && run_for 200 ./setup --host claude --prefix --no-team --no-browser \
        --no-plan-tune-hooks --no-timeline-stop-hook </dev/null >>"$LOG" 2>&1); then
    touch "$dir/.skill-setup-$GSTACK_REF"; say "installed"
  else
    say "./setup failed"; return 1
  fi
}

job_tstack()      { CURRENT_JOB=tstack; fetch_repo https://github.com/t3dotgg/tstack.git "$STORE/t3-tstack" "$TSTACK_UPSTREAM_REF" skills; }
job_pstack()      { CURRENT_JOB=pstack; fetch_repo https://github.com/praxstack/cursor-plugins.git "$STORE/cursor-plugins" "$PSTACK_REF" pstack; }
job_superpowers() { CURRENT_JOB=superpowers; fetch_repo https://github.com/obra/superpowers.git "$STORE/superpowers" "$SUPERPOWERS_REF" skills; }
job_matt()        { CURRENT_JOB=matt; fetch_repo https://github.com/mattpocock/skills.git "$STORE/matt" "$MATT_REF" skills/engineering skills/productivity skills/misc; }

job_personas() {
  CURRENT_JOB=personas
  local s paths=(new-skills .claude/agents)
  if [ "$SKILL_PROFILE" = broad ]; then paths+=(skills); else for s in $PERSONA_SKILLS; do paths+=("skills/$s"); done; fi
  enough_disk || return 1
  fetch_repo https://github.com/praxstack/skills-and-personas.git "$STORE/skills-and-personas" "$PERSONAS_REF" "${paths[@]}"
}

node_major() { node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0; }

npm_global() {  # npm_global PKG@VERSION BIN
  local spec="$1" bin="$2" want="${1##*@}"
  if have "$bin" && npm ls -g --depth=0 "${spec%@*}" 2>/dev/null | grep -q "@$want"; then return 0; fi
  have npm || return 2
  [ "$(node_major)" -ge 20 ] 2>/dev/null || return 5
  retry run_for 150 npm install -g --no-audit --no-fund "$spec"
}

job_openspec_cli() {
  CURRENT_JOB=openspec_cli
  pin openspec-cli "npm:@fission-ai/openspec" "$OPENSPEC_VERSION"
  [ "$INSTALL_OPENSPEC_CLI" = 1 ] || { say "CLI off"; return 0; }
  npm_global "@fission-ai/openspec@$OPENSPEC_VERSION" openspec
  case $? in 0) say "CLI $OPENSPEC_VERSION" ;; 2) say "npm missing"; return 1 ;;
    5) say "CLI needs Node 20+"; return 1 ;; *) say "CLI install failed"; return 1 ;; esac
}
job_openspec() { CURRENT_JOB=openspec; fetch_repo https://github.com/Fission-AI/OpenSpec.git "$STORE/openspec" "$OPENSPEC_REF" skills; }

ensure_uv() {
  have uv && return 0
  have python3 || return 1
  log "uv missing; installing it with pip --user"
  run_for 120 python3 -m pip install --user -q uv >>"$LOG" 2>&1 ||
    run_for 120 python3 -m pip install --user -q --break-system-packages uv >>"$LOG" 2>&1
  hash -r; have uv
}

job_speckit() {
  CURRENT_JOB=speckit
  pin speckit github/spec-kit "$SPECKIT_TAG"
  if have specify && specify version 2>/dev/null | grep -qF "${SPECKIT_TAG#v}"; then say "CLI $SPECKIT_TAG (already)"; return 0; fi
  ensure_uv || { say "uv and pip unavailable"; return 1; }
  if retry run_for 200 uv tool install --force "specify-cli @ git+https://github.com/github/spec-kit.git@$SPECKIT_TAG"; then
    say "CLI $SPECKIT_TAG"
  else
    say "uv tool install failed"; return 1
  fi
}

job_graphify() {
  CURRENT_JOB=graphify
  pin graphify pypi:graphifyy "$GRAPHIFY_VERSION"
  if ! { have graphify && uv tool list 2>/dev/null | grep -qF "graphifyy v$GRAPHIFY_VERSION"; }; then
    ensure_uv || { say "uv and pip unavailable"; return 1; }
    retry run_for 200 uv tool install --force "graphifyy==$GRAPHIFY_VERSION" || { say "uv tool install failed"; return 1; }
    hash -r
  fi
  # Writes ~/.claude/skills/graphify/ and a short block in ~/.claude/CLAUDE.md.
  if run_for 60 graphify install --platform claude </dev/null >>"$LOG" 2>&1 && [ -f "$SKILLS_DIR/graphify/SKILL.md" ]; then
    say "CLI + skill $GRAPHIFY_VERSION"
  else
    say "CLI ok, 'graphify install' failed"; return 1
  fi
}

job_hyperframes() {
  CURRENT_JOB=hyperframes
  local s paths=()
  for s in $HYPERFRAMES_SKILLS; do paths+=("skills/$s"); done
  fetch_repo https://github.com/heygen-com/hyperframes.git "$STORE/hyperframes" "$HYPERFRAMES_REF" "${paths[@]}"
}
job_hyperframes_cli() {
  CURRENT_JOB=hyperframes_cli
  pin hyperframes-cli npm:hyperframes "$HYPERFRAMES_VERSION"
  have npm || { say "npm missing"; return 1; }
  if retry run_for 150 npm cache add "hyperframes@$HYPERFRAMES_VERSION"; then say "npx cache warm"; else say "npx cache warm failed"; return 1; fi
}

job_uizze() {
  CURRENT_JOB=uizze
  local s paths=()
  for s in $UIZZE_SKILLS; do paths+=("skills/$s"); done
  fetch_repo https://github.com/uizze/uizze.git "$STORE/uizze" "$UIZZE_REF" "${paths[@]}"
}

job_anthropic() {
  CURRENT_JOB=anthropic
  local s paths=()
  for s in $ANTHROPIC_SKILLS; do paths+=("skills/$s"); done
  fetch_repo https://github.com/anthropics/skills.git "$STORE/anthropic-skills" "$ANTHROPIC_SKILLS_REF" "${paths[@]}"
}

# community lines, parsed once: label|repo|sha|parent|names
community_lines() {
  local line
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    [ -n "$line" ] && [ "${line:0:1}" != "#" ] && printf '%s\n' "$line"
  done <<<"$COMMUNITY_SOURCES"
}
job_community() {
  CURRENT_JOB=community
  local label repo ref parent names n bad=0
  while IFS='|' read -r label repo ref parent names; do
    if ! [[ "$ref" =~ ^[0-9a-f]{40}$ ]] || ! [[ "$label" =~ ^[a-z0-9-]+$ ]]; then
      log "community $label: needs a lowercase label and a full commit SHA"; bad=$((bad + 1)); continue
    fi
    local paths=()
    if [ -n "${names// /}" ]; then for n in $names; do paths+=("$parent/$n"); done; else paths=("$parent"); fi
    fetch_repo "https://github.com/$repo.git" "$STORE/community-$label" "$ref" "${paths[@]}" || bad=$((bad + 1))
  done < <(community_lines)
  [ "$bad" -eq 0 ]
}
job_community_cli() {
  CURRENT_JOB=community_cli
  local spec bad=0 ok=""
  for spec in $COMMUNITY_NPM; do
    pin "${spec%@*}" "npm" "${spec##*@}"
    if npm_global "$spec" "$(basename "${spec%@*}")"; then ok="$ok ${spec}"; else bad=$((bad + 1)); fi
  done
  say "npm:${ok:- none}${bad:+, $bad failed}"
  [ "$bad" -eq 0 ]
}

# ---------- lock: never two runs at once --------------------------------------

if have flock; then
  exec 9>"$LOCK"
  if ! flock -w 600 9; then echo "[skill-setup] another run holds the lock; stopping" >&2; return 0; fi
else
  if ! mkdir "$LOCK.d" 2>/dev/null; then
    if [ -n "$(find "$LOCK.d" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
      rm -rf "$LOCK.d" && mkdir "$LOCK.d"
    else
      echo "[skill-setup] another run holds the lock; stopping" >&2; return 0
    fi
  fi
  trap 'rm -rf "$LOCK.d"' EXIT
fi

: >"$LOG"; : >"$RESOLVED"; : >"$NEW_MANIFEST"
rm -rf "$JOBS"; mkdir -p "$JOBS"

# ---------- preflight ---------------------------------------------------------

log "v$SETUP_VERSION start $(date -u +%Y-%m-%dT%H:%M:%SZ) profile=$SKILL_PROFILE dry=$DRY token=$HAVE_TOKEN budget=${SETUP_BUDGET_SECS}s"
log "packs: $SKILL_PACKS"
if ! have git; then log "git is missing; nothing can be installed"; return 0; fi
GIT_V="$(git --version | awk '{print $3}')"
if [ "$(printf '%s\n2.31.0\n' "$GIT_V" | sort -V | head -n 1)" != "2.31.0" ]; then
  log "git $GIT_V is older than 2.31; sparse checkout and token passing may fail"
fi
load_account_names

if [ "$DRY" = 1 ]; then
  log "dry run: would install packs [$SKILL_PACKS]; pins:"
  set | grep -E '^[A-Z_]+_(REF|VERSION|TAG)=' | sed 's/^/[skill-setup]   /' >&2
  community_lines | sed 's/^/[skill-setup]   community: /' >&2
  return 0
fi

# ---------- phase 1: downloads and installs, in parallel ----------------------

wants_agent_skills=0
if wants tstack || wants research || wants extras; then wants_agent_skills=1; bg agent_skills job_agent_skills; fi
wants gstack      && bg gstack job_gstack
wants tstack      && bg tstack job_tstack
wants pstack      && bg pstack job_pstack
wants superpowers && bg superpowers job_superpowers
wants matt        && bg matt job_matt
wants personas    && bg personas job_personas
wants openspec    && { bg openspec job_openspec; bg openspec_cli job_openspec_cli; }
wants speckit     && [ "$INSTALL_SPECKIT_CLI" = 1 ] && bg speckit job_speckit
wants graphify    && [ "$INSTALL_GRAPHIFY" = 1 ] && bg graphify job_graphify
wants hyperframes && { bg hyperframes job_hyperframes; [ "$WARM_HYPERFRAMES_CLI" = 1 ] && bg hyperframes_cli job_hyperframes_cli; }
wants uizze       && bg uizze job_uizze
wants anthropic   && bg anthropic job_anthropic
wants community   && { bg community job_community; [ "$INSTALL_COMMUNITY_CLIS" = 1 ] && bg community_cli job_community_cli; }
log "phase 1: ${#JOB_PID[@]} jobs started"
wait_all
hash -r
log "phase 1 done at $(elapsed)s"

AGENT_SKILLS_OK=0
[ "$wants_agent_skills" = 1 ] && job_ok agent_skills && AGENT_SKILLS_OK=1
[ "$wants_agent_skills" = 1 ] && [ "$AGENT_SKILLS_OK" = 0 ] &&
  log "praxstack/agent-skills not reachable (private; expected inside a setup script). Fallbacks used."

# ---------- phase 2: link skills in priority order ----------------------------

if wants gstack; then
  gdir="$(real_dir "$SKILLS_DIR/gstack" 2>/dev/null || true)"
  if job_ok gstack; then note gstack "$(job_msg gstack)" "garrytan/gstack ${GSTACK_REF:0:7}"
  else failed gstack "failed: $(job_msg gstack)" "see log"; fi
  if [ -n "$gdir" ]; then   # gstack links its own skills; claim those names
    for d in "$SKILLS_DIR"/*/; do
      case "$(real_dir "$d")" in "$gdir"|"$gdir"/*) CLAIMED["$(basename "$d")"]=gstack ;; esac
    done
  fi
fi

if wants tstack; then
  if [ "$AGENT_SKILLS_OK" = 1 ] && [ -d "$AGENT_SKILLS/tstack" ]; then
    link_all_under "$AGENT_SKILLS/tstack" tstack; note tstack "linked $COUNT" "praxstack/agent-skills (Prax's edits)"
  elif job_ok tstack; then
    link_all_under "$STORE/t3-tstack/skills" tstack; note tstack "linked $COUNT" "t3dotgg/tstack ${TSTACK_UPSTREAM_REF:0:7}"
  else failed tstack "failed" "neither source reachable"; fi
fi

if wants pstack; then
  if job_ok pstack; then link_all_under "$STORE/cursor-plugins/pstack/skills" pstack
    note pstack "linked $COUNT" "praxstack/cursor-plugins ${PSTACK_REF:0:7}"
  else failed pstack "failed" "clone failed, see log"; fi
fi

if wants superpowers; then
  if [ "$SKIP_IF_ON_ACCOUNT" = 1 ] && account_has using-superpowers; then note superpowers "skipped" "account plugin already on"
  elif job_ok superpowers; then link_all_under "$STORE/superpowers/skills" superpowers
    note superpowers "linked $COUNT" "obra/superpowers ${SUPERPOWERS_REF:0:7} (skills only)"
  else failed superpowers "failed" "clone failed, see log"; fi
fi

if wants matt; then
  if [ "$SKIP_IF_ON_ACCOUNT" = 1 ] && account_has setup-matt-pocock-skills; then note matt "skipped" "account plugin already on"
  elif job_ok matt; then
    n=0; for g in engineering productivity misc; do link_all_under "$STORE/matt/skills/$g" matt; n=$((n + COUNT)); done
    note matt "linked $n" "mattpocock/skills ${MATT_REF:0:7}"
  else failed matt "failed" "clone failed, see log"; fi
fi

if wants personas; then
  P="$STORE/skills-and-personas"
  if job_ok personas; then
    link_all_under "$P/new-skills" personas; n=$COUNT
    if [ "$SKILL_PROFILE" = broad ]; then link_all_under "$P/skills" personas
    else
      # shellcheck disable=SC2046
      link_named "$P/skills" personas $(words "$PERSONA_SKILLS")
    fi
    m=$COUNT; a=0
    for f in "$P"/.claude/agents/*.md; do
      [ -f "$f" ] || continue
      t="$AGENTS_DIR/$(basename "$f")"
      if [ -e "$t" ] && ! ours "$t"; then continue; fi
      rm -f "$t"; ln -s "$f" "$t" && echo "$t" >>"$NEW_MANIFEST" && a=$((a + 1))
    done
    note personas "linked $((n + m)) skills, $a agents" "praxstack/skills-and-personas ${PERSONAS_REF:0:7}"
  else failed personas "failed" "clone failed or not enough disk"; fi
fi

if wants openspec; then
  cli="$(job_msg openspec_cli)"; job_ok openspec_cli || FAILED_ANY=1
  if job_ok openspec; then link_all_under "$STORE/openspec/skills" openspec
    note openspec "$cli, skills $COUNT" "Fission-AI/OpenSpec ${OPENSPEC_REF:0:7}"
  else failed openspec "$cli, skills failed" "clone failed, see log"; fi
fi

if wants speckit && [ "$INSTALL_SPECKIT_CLI" = 1 ]; then
  if job_ok speckit; then note speckit "$(job_msg speckit)" "github/spec-kit (per repo: specify init --here --integration claude)"
  else failed speckit "failed: $(job_msg speckit)" "see log"; fi
fi

if wants graphify && [ "$INSTALL_GRAPHIFY" = 1 ]; then
  if job_ok graphify; then
    if [ -n "${SKIPSET[graphify]:-}" ]; then rm -rf "$SKILLS_DIR/graphify"; note graphify "CLI only" "graphify in SKIP_SKILLS"
    else CLAIMED[graphify]=graphify; note graphify "$(job_msg graphify)" "pypi graphifyy (Apache-2.0)"; fi
  else failed graphify "failed: $(job_msg graphify)" "see log"; fi
fi

if wants hyperframes; then
  if job_ok hyperframes; then
    # shellcheck disable=SC2046
    link_named "$STORE/hyperframes/skills" hyperframes $(words "$HYPERFRAMES_SKILLS")
    extra=""; [ "$WARM_HYPERFRAMES_CLI" = 1 ] && extra=", $(job_msg hyperframes_cli)"
    have ffmpeg || extra="$extra, ffmpeg missing (render needs it)"
    note hyperframes "linked $COUNT$extra" "heygen-com/hyperframes ${HYPERFRAMES_REF:0:7}"
  else failed hyperframes "failed" "clone failed, see log"; fi
fi

if wants uizze; then
  if job_ok uizze; then
    # shellcheck disable=SC2046
    link_named "$STORE/uizze/skills" uizze $(words "$UIZZE_SKILLS")
    note uizze "linked $COUNT" "uizze/uizze ${UIZZE_REF:0:7} (free skills)"
  else failed uizze "failed" "clone failed, see log"; fi
fi

if wants community; then
  total=0; srcs=""
  while IFS='|' read -r label repo ref parent names; do
    d="$STORE/community-$label/$parent"
    [ -d "$d" ] && [ "$(git -C "$STORE/community-$label" rev-parse HEAD 2>/dev/null)" = "$ref" ] || {
      SKIPPED+=("$label (community): not fetched"); continue; }
    if [ -n "${names// /}" ]; then
      # shellcheck disable=SC2086
      link_named "$d" "$label" $names
    else link_all_under "$d" "$label"; fi
    total=$((total + COUNT)); srcs="$srcs $repo@${ref:0:7}"
  done < <(community_lines)
  res="linked $total"; job_ok community || { FAILED_ANY=1; res="$res (some sources failed, see log)"; }
  [ "$INSTALL_COMMUNITY_CLIS" = 1 ] && { res="$res, $(job_msg community_cli)"; job_ok community_cli || FAILED_ANY=1; }
  note community "$res" "${srcs# }"
fi

if wants anthropic; then
  if job_ok anthropic; then
    # shellcheck disable=SC2046
    link_named "$STORE/anthropic-skills/skills" anthropic $(words "$ANTHROPIC_SKILLS")
    note anthropic "linked $COUNT" "anthropics/skills ${ANTHROPIC_SKILLS_REF:0:7} (Apache-2.0 only)"
  else failed anthropic "failed" "clone failed, see log"; fi
fi

if wants research; then
  if [ "$AGENT_SKILLS_OK" = 1 ]; then
    # shellcheck disable=SC2046
    link_named "$AGENT_SKILLS" research $(words "$RESEARCH_SKILLS"); note research "linked $COUNT" "praxstack/agent-skills"
  else note research "skipped" "praxstack/agent-skills is private; re-run in a session with SKILL_SETUP_GH_TOKEN"; fi
fi

if wants extras; then
  if [ "$AGENT_SKILLS_OK" != 1 ]; then
    note extras "skipped" "praxstack/agent-skills is private; re-run in a session with SKILL_SETUP_GH_TOKEN"
  elif [ "$SKILL_PROFILE" = broad ]; then
    link_all_under "$AGENT_SKILLS" agent-skills; note extras "linked $COUNT (broad)" "all of praxstack/agent-skills"
  else
    # shellcheck disable=SC2046
    link_named "$AGENT_SKILLS" extras $(words "$EXTRA_SKILLS"); note extras "linked $COUNT" "EXTRA_SKILLS list"
  fi
fi

# ---------- cleanup -----------------------------------------------------------
# Remove links an earlier run made that this run no longer wants. If anything
# failed, keep old links that still resolve, so a flaky network never removes skills.

if [ -f "$MANIFEST" ]; then
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    grep -qxF "$p" "$NEW_MANIFEST" && continue
    if [ "$FAILED_ANY" = 1 ] && [ -e "$p" ]; then echo "$p" >>"$NEW_MANIFEST"; continue; fi
    [ -L "$p" ] && rm -f "$p" && log "removed stale link $p"
  done <"$MANIFEST"
fi
sort -u "$NEW_MANIFEST" -o "$NEW_MANIFEST" && mv "$NEW_MANIFEST" "$MANIFEST"
for p in "$SKILLS_DIR"/* "$AGENTS_SKILLS_DIR"/* "$AGENTS_DIR"/*; do
  [ -L "$p" ] && [ ! -e "$p" ] && ours "$p" && rm -f "$p" && log "removed dangling link $p"
done

# ---------- environment for sessions ------------------------------------------

PROFILE_SNIPPET="$HOME/.skill-setup-env"
cat >"$PROFILE_SNIPPET" <<'EOF'
# Written by cloud-skill-setup.sh
export OPENSPEC_TELEMETRY=0
for _p in "$HOME/.local/bin" "$HOME/.bun/bin"; do
  case ":$PATH:" in *":$_p:"*) ;; *) [ -d "$_p" ] && PATH="$_p:$PATH" ;; esac
done
unset _p; export PATH
EOF
for rc in "$HOME/.bashrc" "$HOME/.profile"; do
  [ -f "$rc" ] || touch "$rc"
  grep -qF ".skill-setup-env" "$rc" || echo "[ -f \"$PROFILE_SNIPPET\" ] && . \"$PROFILE_SNIPPET\"" >>"$rc"
done

# Raise the skill listing budget, only if the user has not set it.
if [ -n "$SKILL_LISTING_BUDGET_FRACTION" ] && have python3; then
  python3 - "$CLAUDE_DIR/settings.json" "$SKILL_LISTING_BUDGET_FRACTION" >>"$LOG" 2>&1 <<'PY' || log "could not update settings.json"
import json, os, sys
path, frac = sys.argv[1], float(sys.argv[2])
data = {}
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)          # invalid JSON: raise and leave the file alone
if "skillListingBudgetFraction" not in data:
    data["skillListingBudgetFraction"] = frac
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2); f.write("\n")
    os.replace(tmp, path)
    print(f"settings.json: skillListingBudgetFraction={frac}")
PY
fi

# ---------- verify and report -------------------------------------------------

tools=""
for t in git node npm bun python3 uv gh openspec specify graphify ctx7 playwright-cli ffmpeg; do
  if have "$t"; then tools="$tools $t:yes"; else tools="$tools $t:no"; fi
done
total_skills=0; broken=0; desc_chars=0
for p in "$SKILLS_DIR"/*/; do
  [ "$p" = "$SKILLS_DIR/synced/" ] && continue
  if [ -f "$p/SKILL.md" ]; then
    total_skills=$((total_skills + 1))
    desc_chars=$((desc_chars + $(fm_field "${p%/}" description | wc -c)))
  else broken=$((broken + 1)); fi
done
warn=""
[ "$total_skills" -gt "$SKILL_COUNT_WARN" ] &&
  warn="Warning: $total_skills skills. Past ~$SKILL_COUNT_WARN Claude picks skills less reliably; trim packs or use SKIP_SKILLS."

{
  echo "# Skill setup report"
  echo
  echo "Run $(date -u +%Y-%m-%dT%H:%M:%SZ) · v$SETUP_VERSION · profile $SKILL_PROFILE · took $(elapsed)s (budget ${SETUP_BUDGET_SECS}s)"
  echo
  echo "Skills linked this run: ${#CLAIMED[@]} · skill folders in ~/.claude/skills: $total_skills · empty folders: $broken · description text: ~$desc_chars chars"
  [ "$FAILED_ANY" = 1 ] && echo && echo "Some steps failed. Look for 'failed' below and in the log."
  [ -n "$warn" ] && { echo; echo "$warn"; }
  echo
  echo "| Pack | Result | Source | Time |"
  echo "|---|---|---|---|"
  printf '%s\n' "${STATUS[@]}"
  echo
  echo "Tools:$tools"
  echo
  echo "## Pinned sources"
  echo
  echo '```'
  sort -u "$RESOLVED"
  echo '```'
  echo
  echo "## Skipped (${#SKIPPED[@]})"
  echo
  if [ "${#SKIPPED[@]}" -gt 0 ]; then printf -- '- %s\n' "${SKIPPED[@]}"; else echo "None."; fi
  echo
  echo "Full log: $LOG"
} >"$REPORT"

{
  printf '{"version":"%s","time":"%s","profile":"%s","seconds":%s,"skills_linked":%s,"skills_total":%s,"any_failed":%s,"packs":[' \
    "$SETUP_VERSION" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SKILL_PROFILE" "$(elapsed)" "${#CLAIMED[@]}" "$total_skills" "$FAILED_ANY"
  local i
  for i in "${!JSON_PACKS[@]}"; do [ "$i" -gt 0 ] && printf ','; printf '%s' "${JSON_PACKS[$i]}"; done
  printf '],"skipped":%s}\n' "${#SKIPPED[@]}"
} >"$REPORT_JSON"

log "done in $(elapsed)s: ${#CLAIMED[@]} skills linked, ${#SKIPPED[@]} skipped, any_failed=$FAILED_ANY. Report: $REPORT"
return 0
}

# Everything runs in a subshell, so nothing inside (an unset variable, a crashed
# pack) can fail the environment build. The script always exits 0.
( main "$@" )
rc=$?
[ "$rc" -ne 0 ] && echo "[skill-setup] stopped early (rc=$rc); see $LOG" >&2
exit 0
