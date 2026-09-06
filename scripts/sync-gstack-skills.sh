#!/usr/bin/env bash
# Sync gstack skills into .agents/skills/ with short slash-command names (/review, /qa, …).
# Cursor --host cursor installs gstack-* prefixed folders; Cloud Agents only load
# project .agents/skills/, so we install patched Cursor SKILL.md overlays here.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GSTACK="${GSTACK_DIR:-$ROOT/vendor/skills-repos/gstack}"
if [ -z "${GSTACK_DIR:-}" ] && [ ! -d "$GSTACK" ] && [ -d "$HOME/.agents/skills/gstack" ]; then
  GSTACK="$HOME/.agents/skills/gstack"
fi
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
  # Native short-skill resource paths resolve through the installed runtime on either host.
  GSTACK_SOURCE="$GSTACK" perl -pi -e 's{(?<![\w/])(?:\$HOME/|\$_ROOT/|~/)?\.(?:cursor|agents)/skills/((?!gstack/)[a-z0-9][a-z0-9-]*)/}{-d "$ENV{GSTACK_SOURCE}/$1" ? "\$GSTACK_ROOT/$1/" : $&}ge' "$file"

}

link_runtime() {
  local source="$1" target="$2" parent child source_real target_real
  [ -e "$source" ] || return 0
  # Never merge through a destination symlink, even one into the source tree.
  [ ! -L "$target" ] || return 0
  if [ -d "$source" ]; then
    source_real="$(cd "$source" && pwd -P)/"
    target_real="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$target")/"
    case "$source_real" in "$target_real"*) return 0 ;; esac
    case "$target_real" in "$source_real"*) return 0 ;; esac
  fi
  if [ -d "$source" ] && [ -d "$target" ]; then
    for child in "$source"/* "$source"/.[!.]* "$source"/..?*; do
      link_runtime "$child" "$target/$(basename "$child")"
    done
    return 0
  fi
  # Existing runtime assets may be local edits or links to shared installations.
  [ ! -e "$target" ] || return 0
  parent="$(dirname "$target")"
  if [ -L "$parent" ] || { [ -e "$parent" ] && [ ! -d "$parent" ]; }; then
    echo "warning: preserving runtime parent $parent" >&2
    return 0
  fi
  mkdir -p "$parent"
  ln -s "$(python3 -c 'import os,sys; print(os.path.relpath(os.path.realpath(sys.argv[1]), os.path.realpath(sys.argv[2])))' "$source" "$parent")" "$target"
}

install_gstack_runtime() {
  local dest="$1" rel
  if [ -L "$dest" ] || { [ -e "$dest" ] && [ ! -d "$dest" ]; }; then
    echo "warning: preserving existing runtime $dest" >&2
    return 0
  fi
  # A mirror or nested destination must not turn runtime installation into source edits.
  if python3 -c 'import os,sys; a,b=map(os.path.realpath,sys.argv[1:]); sys.exit(0 if os.path.commonpath([a,b]) in (a,b) else 1)' "$GSTACK" "$dest"; then
    return 0
  fi
  mkdir -p "$dest"
  # Prefer host-generated docs before merging the complete native runtime layout.
  link_runtime "$GSTACK/.cursor/skills/gstack/SKILL.md" "$dest/SKILL.md"
  link_runtime "$GSTACK/.cursor/skills/gstack-upgrade/SKILL.md" "$dest/gstack-upgrade/SKILL.md"
  for rel in "$GSTACK"/*; do
    link_runtime "$rel" "$dest/$(basename "$rel")"
  done
}

skill_missing() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    # ponytail: no ownership manifest; refresh copied overlays explicitly after reviewing local edits.
    echo "warning: preserving existing skill $1 (copied overlays are not refreshed)" >&2
    return 1
  fi
}

install_alias_skill() {
  local skills_parent="$1"
  local alias_name="$2"
  local source_cursor_name="$3"
  local source_skill_dir="$4"
  local alias_dir="$skills_parent/$alias_name"
  local cursor_skill_dir="$GSTACK/.cursor/skills/$source_cursor_name"

  skill_missing "$alias_dir" || return 0
  mkdir -p "$alias_dir"
  if [ -f "$cursor_skill_dir/SKILL.md" ]; then
    cp "$cursor_skill_dir/SKILL.md" "$alias_dir/SKILL.md"
    ALIAS_NAME="$alias_name" perl -pi -e 's/^name: .*/name: $ENV{ALIAS_NAME}/' "$alias_dir/SKILL.md"
    patch_skill_md "$alias_dir/SKILL.md"
  elif [ -f "$source_skill_dir/SKILL.md" ]; then
    cp "$source_skill_dir/SKILL.md" "$alias_dir/SKILL.md"
    ALIAS_NAME="$alias_name" perl -pi -e 's/^name: .*/name: $ENV{ALIAS_NAME}/' "$alias_dir/SKILL.md"
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

  install_gstack_runtime "$skills_parent/gstack"

  for skill_dir in "$GSTACK/.cursor/skills"/gstack*/; do
    [ -f "$skill_dir/SKILL.md" ] || continue
    cursor_name="$(basename "$skill_dir")"
    [ "$cursor_name" = "gstack" ] && continue

    skill_name="$(sed -n '/^name:/{s/^name:[[:space:]]*//;s/[[:space:]]*$//;p;q;}' "$skill_dir/SKILL.md")"
    if [[ ! "$skill_name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || [ "$skill_name" = "gstack" ]; then
      echo "error: invalid skill name in $skill_dir/SKILL.md: $skill_name" >&2
      return 1
    fi

    target="$skills_parent/$skill_name"
    skill_missing "$target" || continue

    # Both hosts need patched overlays; never edit through a generated-source symlink.
    mkdir -p "$target"
    cp "$skill_dir/SKILL.md" "$target/SKILL.md"
    patch_skill_md "$target/SKILL.md"
    linked+=("$skill_name")
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
  install_skills_to "$CURSOR_SKILLS"
fi

echo "gstack skills synced."
