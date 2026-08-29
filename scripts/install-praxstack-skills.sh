#!/usr/bin/env bash
# Install praxstack/skills-and-personas into .agents/skills/ with slash-command folder names.
# Canonical portfolio: new-skills/ (41 skills). Additional public skills: skills/ (4 skills).
# Vendor clone (gitignored): vendor/skills-repos/skills-and-personas
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="${PRAX_SKILLS_DIR:-$ROOT/vendor/skills-repos/skills-and-personas}"
AGENTS="$ROOT/.agents/skills"

log() { printf "[prax-skills] %s\n" "$*"; }

if [ ! -d "$VENDOR/.git" ]; then
  log "cloning praxstack/skills-and-personas..."
  mkdir -p "$(dirname "$VENDOR")"
  git clone --depth 1 https://github.com/praxstack/skills-and-personas.git "$VENDOR"
else
  log "updating vendor clone..."
  git -C "$VENDOR" pull --ff-only 2>/dev/null || log "warning: vendor pull failed; using existing clone"
fi

mkdir -p "$AGENTS"

install_skill() {
  local src_dir="$1"
  local name="$2"
  local dst="$AGENTS/$name"

  if [ ! -f "$src_dir/SKILL.md" ]; then
    log "skip $name — no SKILL.md"
    return 0
  fi

  if [ -d "$dst" ] && [ "${PRAX_FORCE:-0}" != "1" ]; then
    if [ -f "$dst/.praxstack-skill" ] || grep -q 'praxstack/skills-and-personas' "$dst/SKILL.md" 2>/dev/null; then
      log "refresh $name"
    elif [ -f "$dst/SKILL.md" ]; then
      log "skip $name — non-prax skill already installed (set PRAX_FORCE=1 to overwrite)"
      return 0
    fi
  fi

  rm -rf "$dst"
  cp -R "$src_dir" "$dst"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$dst/.praxstack-skill"
  log "install $name"
}

installed=()
skipped=()

for src_dir in "$VENDOR/new-skills"/*/; do
  name="$(basename "$src_dir")"
  [[ "$name" == _* ]] && continue
  [[ "$name" == .* ]] && continue
  before="$([ -d "$AGENTS/$name" ] && echo yes || echo no)"
  install_skill "$src_dir" "$name"
  if [ -f "$AGENTS/$name/.praxstack-skill" ]; then
    installed+=("$name")
  elif [ "$before" = "yes" ]; then
    skipped+=("$name")
  fi
done

for name in teach-pro-max superimprove coding-agent-leadership-principles cross-agent-handoff; do
  src_dir="$VENDOR/skills/$name"
  [ -d "$src_dir" ] || continue
  before="$([ -d "$AGENTS/$name" ] && echo yes || echo no)"
  install_skill "$src_dir" "$name"
  if [ -f "$AGENTS/$name/.praxstack-skill" ]; then
    installed+=("$name")
  elif [ "$before" = "yes" ]; then
    skipped+=("$name")
  fi
done

log ""
log "=== summary ==="
log "installed/refreshed: ${#installed[@]}"
log "skipped (collision): ${#skipped[@]}"
if [ ${#skipped[@]} -gt 0 ]; then
  log "skipped: ${skipped[*]}"
fi
log "vendor: $VENDOR"
log "destination: $AGENTS"
