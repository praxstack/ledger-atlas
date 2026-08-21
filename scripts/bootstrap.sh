#!/bin/sh
set -eu

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"
uv sync --frozen
git config core.hooksPath .githooks
python3 scripts/orchestrion.py validate
echo "bootstrap complete; review and trust project hooks with /hooks before using a goal loop"
