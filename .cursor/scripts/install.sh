#!/usr/bin/env bash
set -euo pipefail

# Python tooling for scripts/ and tests/orchestration. The Swift app builds on macOS only.
if command -v uv >/dev/null 2>&1; then
  uv sync --frozen
fi

# Agent skills are not committed (#185); recreate them from skills-lock.json.
./scripts/install-skills.sh || echo "warning: some agent skills failed to install" >&2
