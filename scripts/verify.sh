#!/bin/sh
set -eu

MODE=${1:---fast}
case "$MODE" in
  --fast|--full) ;;
  *) echo "usage: $0 --fast|--full" >&2; exit 2 ;;
esac

REPO_ROOT=$(git rev-parse --show-toplevel)
EVIDENCE_ROOT=${LEDGER_ATLAS_EVIDENCE_ROOT:-/Users/prax/Developer/money-manager-reverse-engineering}
PYTHON="$REPO_ROOT/.venv/bin/python"
cd "$REPO_ROOT"

if [ ! -x .venv/bin/python ] || [ ! -x .venv/bin/ruff ]; then
  echo "locked environment missing; run: uv sync --frozen" >&2
  exit 2
fi

"$PYTHON" scripts/check-protected-inputs.py
if [ -d "$EVIDENCE_ROOT" ] && [ -f "$EVIDENCE_ROOT/.orchestrion/protected-inputs.sha256" ]; then
  (
    cd "$EVIDENCE_ROOT"
    "$PYTHON" scripts/check-protected-inputs.py
  )
else
  echo "evidence tree absent; skipped sibling protected-input check"
fi
.venv/bin/ruff check scripts tests/orchestration
.venv/bin/ruff format --check scripts tests/orchestration
"$PYTHON" -m pytest tests/orchestration
"$PYTHON" scripts/orchestrion.py validate
if [ -f Package.swift ]; then
  swift build
  swift test
  swift run mmctl >/dev/null
else
  echo "Swift package absent from exact tree; skipped Swift verification"
fi

if [ "$MODE" = "--full" ]; then
  PYTHONPYCACHEPREFIX=.orchestrion/runtime/pycache \
    "$PYTHON" -m compileall -q scripts .codex/hooks tests/orchestration
  "$PYTHON" -m json.tool .codex/hooks.json >/dev/null
  "$PYTHON" -m json.tool .orchestrion/schemas/review.schema.json >/dev/null
  "$PYTHON" scripts/check_codex_surface.py
  if [ -f Package.swift ]; then
    swift build -c release
  fi
fi

echo "verification passed ($MODE)"
