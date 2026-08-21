#!/bin/sh
set -eu

REPO_ROOT=$(git rev-parse --show-toplevel)
exec python3 "$REPO_ROOT/scripts/run_unattended.py" "$@"
