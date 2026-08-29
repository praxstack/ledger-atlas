#!/usr/bin/env bash
# Idempotent project-local agent skills installer for ledger-atlas.
# Cloud Agents load .agents/skills/ only — not ~/.cursor/skills/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SKILLS_DIR="$ROOT/.agents/skills"
LOCK="$ROOT/skills-lock.json"
FAILED=()

log() { echo "==> $*"; }
warn() { echo "warning: $*" >&2; }

skill_present() {
  [ -f "$SKILLS_DIR/$1/SKILL.md" ]
}

lock_has_source() {
  local pack="$1"
  [ -f "$LOCK" ] && grep -q "\"source\": \"$pack\"" "$LOCK"
}

skills_add() {
  local repo="$1"
  shift
  log "skills add $repo $*"
  if ! npx skills add "$repo" --agent cursor -y --copy "$@"; then
    FAILED+=("$repo")
    warn "failed: $repo"
    return 1
  fi
}

install_if_missing() {
  local name="$1"
  local repo="$2"
  shift 2
  if skill_present "$name"; then
    log "skip (present): $name"
    return 0
  fi
  skills_add "$repo" "$@"
}

mkdir -p "$SKILLS_DIR"

# --- Core packs (skip when lockfile already records the source) ---
install_if_missing find-skills vercel-labs/skills --skill find-skills
install_if_missing agent-browser vercel-labs/agent-browser --skill agent-browser
install_if_missing improve shadcn/improve --skill improve

if ! ls "$SKILLS_DIR"/ce-* >/dev/null 2>&1; then
  skills_add EveryInc/compound-engineering-plugin
else
  log "skip (present): compound-engineering (ce-*)"
fi

for pack in \
  trailofbits/skills \
  vercel-labs/agent-skills \
  anthropics/skills \
  cloudflare/skills \
  stripe/ai \
  supabase/agent-skills \
  github/awesome-copilot \
  mattpocock/skills \
  obra/superpowers; do
  if lock_has_source "$pack"; then
    log "skip (lockfile): $pack"
  else
    skills_add "$pack" || true
  fi
done

# pstack — copy from cursor/plugins when missing
if ! skill_present poteto-mode; then
  VENDOR_PLUGINS="$ROOT/vendor/skills-repos/plugins"
  if [ ! -d "$VENDOR_PLUGINS/.git" ]; then
    mkdir -p "$(dirname "$VENDOR_PLUGINS")"
    git clone --depth 1 https://github.com/cursor/plugins.git "$VENDOR_PLUGINS"
  fi
  if [ -d "$VENDOR_PLUGINS/pstack/skills" ]; then
    for skill_dir in "$VENDOR_PLUGINS/pstack/skills"/*/; do
      name="$(basename "$skill_dir")"
      if ! skill_present "$name"; then
        mkdir -p "$SKILLS_DIR/$name"
        cp -R "$skill_dir"/* "$SKILLS_DIR/$name/"
        log "installed pstack skill: $name"
      fi
    done
  else
    warn "pstack skills not found under vendor/plugins"
    FAILED+=("cursor/plugins/pstack")
  fi
else
  log "skip (present): pstack (poteto-mode)"
fi

# Microsoft — selective only (avoid full 175+ pack)
for ms_skill in skill-creator mcp-builder github-issue-creator frontend-design-review microsoft-docs; do
  install_if_missing "$ms_skill" microsoft/skills --skill "$ms_skill" || true
done

if lock_has_source "aws/agent-toolkit-for-aws"; then
  log "skip (lockfile): aws/agent-toolkit-for-aws"
else
  skills_add aws/agent-toolkit-for-aws || true
fi

# --- 2026 curated additions ---
install_if_missing hallmark nutlope/hallmark --skill hallmark
install_if_missing last30days mvanhorn/last30days-skill --skill last30days
install_if_missing deep-research 24601/agent-deep-research --skill deep-research

for nv_skill in rag-blueprint aiq-research accelerated-computing-cudf cuopt-developer; do
  install_if_missing "$nv_skill" nvidia/skills --skill "$nv_skill" || true
done

for rem_skill in remotion-best-practices remotion-create remotion-render; do
  install_if_missing "$rem_skill" remotion-dev/skills --skill "$rem_skill" || true
done

# gstack — short slash-command names (/review, /qa, /ship, …)
if [ -x "$ROOT/scripts/sync-gstack-skills.sh" ]; then
  log "syncing gstack skills"
  "$ROOT/scripts/sync-gstack-skills.sh"
else
  warn "sync-gstack-skills.sh not found — skipping gstack sync"
fi

# praxstack/skills-and-personas — custom portfolio (45 skills)
if [ -x "$ROOT/scripts/install-praxstack-skills.sh" ]; then
  log "installing praxstack skills-and-personas"
  "$ROOT/scripts/install-praxstack-skills.sh"
else
  warn "install-praxstack-skills.sh not found — skipping praxstack sync"
fi

# OpenSpec — repo tooling (Node >= 20.19)
node_major="$(node -p "process.versions.node.split('.').map(Number)[0]")"
node_minor="$(node -p "process.versions.node.split('.').map(Number)[1]")"
if [ "$node_major" -gt 20 ] || { [ "$node_major" -eq 20 ] && [ "$node_minor" -ge 19 ]; }; then
  if [ ! -d "$ROOT/openspec" ]; then
    log "initializing OpenSpec"
    npx @fission-ai/openspec init -y 2>/dev/null || npx @fission-ai/openspec init || warn "openspec init failed (non-fatal)"
  else
    log "skip (present): openspec/"
  fi
else
  warn "Node $(node -v) < 20.19 — skipping openspec init"
fi

count="$(find "$SKILLS_DIR" -maxdepth 2 -name SKILL.md | wc -l | tr -d ' ')"
log "installed skill count: $count"

if [ "${#FAILED[@]}" -gt 0 ]; then
  warn "packs with install errors: ${FAILED[*]}"
  exit 1
fi

log "done"
