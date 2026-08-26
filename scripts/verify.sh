#!/bin/sh
set -eu

MODE=${1:---fast}
case "$MODE" in
  --fast|--full) ;;
  *) echo "usage: $0 --fast|--full" >&2; exit 2 ;;
esac

REPO_ROOT=$(git rev-parse --show-toplevel)
PYTHON="$REPO_ROOT/.venv/bin/python"
cd "$REPO_ROOT"

if [ ! -x .venv/bin/python ] || [ ! -x .venv/bin/ruff ]; then
  echo "development environment missing; run: uv sync --frozen" >&2
  exit 2
fi

.venv/bin/ruff check scripts .codex/hooks tests/orchestration
.venv/bin/ruff format --check scripts .codex/hooks tests/orchestration
"$PYTHON" -m pytest tests/orchestration
if [ -f Package.swift ]; then
  swift build
  swift test
  swift run mmctl >/dev/null
else
  echo "Swift package absent from exact tree; skipped Swift verification"
fi

if [ "$MODE" = "--full" ]; then
  PYTHONPYCACHEPREFIX=.build/python-cache \
    "$PYTHON" -m compileall -q scripts .codex/hooks tests/orchestration
  "$PYTHON" -m json.tool .codex/hooks.json >/dev/null
  "$PYTHON" -m json.tool prd.json >/dev/null
  if [ -f Package.swift ]; then
    swift build -c release
  fi
fi

echo "verification passed ($MODE)"
