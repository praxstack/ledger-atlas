#!/bin/sh
set -eu

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"
uv sync --frozen
echo "bootstrap complete; review and trust the project quality hooks with /hooks"
