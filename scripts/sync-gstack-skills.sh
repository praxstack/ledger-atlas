#!/usr/bin/env bash
# Sync gstack skills into .agents/skills/ with short slash-command names (/review, /qa, …).
# Cursor --host cursor installs gstack-* prefixed folders; Cloud Agents only load
# project .agents/skills/, so we symlink generated Cursor SKILL.md trees here.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GSTACK="${GSTACK_DIR:-$ROOT/vendor/skills-repos/gstack}"
AGENTS="$ROOT/.agents/skills"
CURSOR_SKILLS="${CURSOR_SKILLS_DIR:-$HOME/.cursor/skills}"

if [ ! -d "$GSTACK" ]; then
  git clone --depth 1 https://github.com/garrytan/gstack.git "$GSTACK"
fi

export PATH="${HOME}/.bun/bin:${PATH}"

if [ ! -d "$GSTACK/.cursor/skills" ]; then
  echo "Generating Cursor skill docs..."
  (cd "$GSTACK" && bun run gen:skill-docs --host cursor)
fi

patch_skill_md() {
  local file="$1"
  if [ ! -f "$file" ]; then return 0; fi
  if ! grep -q '.agents/skills/gstack' "$file"; then
    perl -0pi -e 's/(GSTACK_ROOT="\$HOME\/\.cursor\/skills\/gstack")/$1\n[ -n "\$_ROOT" ] && [ -d "\$_ROOT\/.agents\/skills\/gstack" ] && GSTACK_ROOT="\$_ROOT\/.agents\/skills\/gstack"/' "$file"
  fi
  if ! grep -q '.agents/skills/gstack/bin/gstack-skill-start' "$file"; then
    perl -0pi -e 's/\[ -x "\$_SS" \] \|\| _SS="\.cursor\/skills\/gstack\/bin\/gstack-skill-start"/[ -x "\$_SS" ] || _SS=".agents\/skills\/gstack\/bin\/gstack-skill-start"\n[ -x "\$_SS" ] || _SS=".cursor\/skills\/gstack\/bin\/gstack-skill-start"/' "$file"
  fi
}

install_gstack_runtime() {
  local dest="$1"
  mkdir -p "$dest/browse" "$dest/gstack-upgrade" "$dest/review" "$dest/supabase"
  for sub in bin lib; do
    if [ -d "$GSTACK/$sub" ]; then
      ln -sfn "$GSTACK/$sub" "$dest/$sub"
    fi
  done
  if [ -d "$GSTACK/browse/dist" ]; then
    ln -sfn "$GSTACK/browse/dist" "$dest/browse/dist"
  fi
  if [ -d "$GSTACK/browse/bin" ]; then
    ln -sfn "$GSTACK/browse/bin" "$dest/browse/bin"
  fi
  if [ -f "$GSTACK/ETHOS.md" ]; then
    ln -sfn "$GSTACK/ETHOS.md" "$dest/ETHOS.md"
  fi
  if [ -f "$GSTACK/.cursor/skills/gstack/SKILL.md" ]; then
    ln -sfn "$GSTACK/.cursor/skills/gstack/SKILL.md" "$dest/SKILL.md"
  fi
  if [ -f "$GSTACK/.cursor/skills/gstack-upgrade/SKILL.md" ]; then
    ln -sfn "$GSTACK/.cursor/skills/gstack-upgrade/SKILL.md" "$dest/gstack-upgrade/SKILL.md"
  fi
  for f in checklist.md TODOS-format.md; do
    if [ -f "$GSTACK/review/$f" ]; then
      ln -sfn "$GSTACK/review/$f" "$dest/review/$f"
    fi
  done
  if [ -f "$GSTACK/supabase/config.sh" ]; then
    ln -sfn "$GSTACK/supabase/config.sh" "$dest/supabase/config.sh"
  fi
}

install_alias_skill() {
  local skills_parent="$1"
  local alias_name="$2"
  local source_cursor_name="$3"
  local source_skill_dir="$4"
  local alias_dir="$skills_parent/$alias_name"
  local cursor_skill_dir="$GSTACK/.cursor/skills/$source_cursor_name"

  rm -rf "$alias_dir"
  mkdir -p "$alias_dir"
  if [ -f "$cursor_skill_dir/SKILL.md" ]; then
    cp "$cursor_skill_dir/SKILL.md" "$alias_dir/SKILL.md"
    sed -i "s/^name: .*/name: $alias_name/" "$alias_dir/SKILL.md"
    patch_skill_md "$alias_dir/SKILL.md"
  elif [ -f "$source_skill_dir/SKILL.md" ]; then
    cp "$source_skill_dir/SKILL.md" "$alias_dir/SKILL.md"
    sed -i "s/^name: .*/name: $alias_name/" "$alias_dir/SKILL.md"
    patch_skill_md "$alias_dir/SKILL.md"
  fi
  # Link runtime assets from the canonical skill directory.
  if [ -d "$source_skill_dir" ]; then
    for asset in "$source_skill_dir"/*; do
      [ -e "$asset" ] || continue
      base="$(basename "$asset")"
      [ "$base" = "SKILL.md" ] || [ "$base" = "SKILL.md.tmpl" ] && continue
      ln -sfn "$asset" "$alias_dir/$base"
    done
  fi
}

install_skills_to() {
  local skills_parent="$1"
  local linked=()

  for old in "$skills_parent"/gstack-*; do
    [ -e "$old" ] || continue
    rm -rf "$old"
  done

  install_gstack_runtime "$skills_parent/gstack"

  for skill_dir in "$GSTACK/.cursor/skills"/gstack*/; do
    [ -f "$skill_dir/SKILL.md" ] || continue
    cursor_name="$(basename "$skill_dir")"
    [ "$cursor_name" = "gstack" ] && continue

    skill_name="$(grep -m1 '^name:' "$skill_dir/SKILL.md" | sed 's/^name:[[:space:]]*//' | tr -d '[:space:]')"
    [ -n "$skill_name" ] || continue

    if [ -f "$skills_parent/$skill_name/SKILL.md" ] && ! grep -q '(gstack)' "$skills_parent/$skill_name/SKILL.md"; then
      echo "warning: skipping gstack $skill_name — non-gstack skill already installed" >&2
      continue
    fi

    target="$skills_parent/$skill_name"
    rm -rf "$target"
    ln -sfn "$(cd "$skill_dir" && pwd -P)" "$target"

    # Patch preamble in the vendor-generated SKILL.md via a repo-local overlay copy
    # when the symlink target is vendor (gitignored). For committed skills, write
    # a thin wrapper directory with patched SKILL.md + symlink to vendor for updates.
    if [ "$skills_parent" = "$AGENTS" ]; then
      vendor_skill="$(cd "$skill_dir" && pwd -P)"
      rm -f "$target"
      mkdir -p "$target"
      cp "$vendor_skill/SKILL.md" "$target/SKILL.md"
      patch_skill_md "$target/SKILL.md"
      linked+=("$skill_name")
    else
      linked+=("$skill_name")
    fi
  done

  if [ -d "$GSTACK/open-gstack-browser" ]; then
    install_alias_skill "$skills_parent" "connect-chrome" "gstack-open-gstack-browser" "$GSTACK/open-gstack-browser"
    linked+=("connect-chrome")
  fi

  echo "Installed ${#linked[@]} gstack skills to $skills_parent"
}

mkdir -p "$AGENTS"
install_skills_to "$AGENTS"

if [ -d "$(dirname "$CURSOR_SKILLS")" ]; then
  mkdir -p "$CURSOR_SKILLS"
  # Global Cursor skills: symlink directly to vendor generated trees (no git commit).
  for skill_dir in "$GSTACK/.cursor/skills"/gstack*/; do
    [ -f "$skill_dir/SKILL.md" ] || continue
    cursor_name="$(basename "$skill_dir")"
    [ "$cursor_name" = "gstack" ] && continue
    skill_name="$(grep -m1 '^name:' "$skill_dir/SKILL.md" | sed 's/^name:[[:space:]]*//' | tr -d '[:space:]')"
    [ -n "$skill_name" ] || continue
  done
  rm -rf "$CURSOR_SKILLS"/gstack-*
  install_gstack_runtime "$CURSOR_SKILLS/gstack"
  for skill_dir in "$GSTACK/.cursor/skills"/gstack*/; do
    [ -f "$skill_dir/SKILL.md" ] || continue
    cursor_name="$(basename "$skill_dir")"
    [ "$cursor_name" = "gstack" ] && continue
    skill_name="$(grep -m1 '^name:' "$skill_dir/SKILL.md" | sed 's/^name:[[:space:]]*//' | tr -d '[:space:]')"
    [ -n "$skill_name" ] || continue
    rm -rf "$CURSOR_SKILLS/$skill_name"
    ln -sfn "$(cd "$skill_dir" && pwd -P)" "$CURSOR_SKILLS/$skill_name"
    perl -0pi -e 's/(GSTACK_ROOT="\$HOME\/\.cursor\/skills\/gstack")/$1\n[ -n "\$_ROOT" ] && [ -d "\$_ROOT\/.agents\/skills\/gstack" ] && GSTACK_ROOT="\$_ROOT\/.agents\/skills\/gstack"/' "$CURSOR_SKILLS/$skill_name/SKILL.md" 2>/dev/null || true
  done
  install_alias_skill "$CURSOR_SKILLS" "connect-chrome" "gstack-open-gstack-browser" "$GSTACK/open-gstack-browser"
fi

echo "gstack skills synced."
