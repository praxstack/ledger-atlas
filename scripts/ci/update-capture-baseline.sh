#!/usr/bin/env bash
# Updates the committed capture baseline (#57 snapshot regression) from a CI run's
# `ui-captures` artifact, after a deliberate UI change.
#
#   scripts/ci/update-capture-baseline.sh <run-id>
#
# The run id is the number in the Actions run URL. Needs the GitHub CLI (`gh`), signed in.
# Review the diff before committing: every changed entry is a capture whose words or looks moved.
set -euo pipefail

run_id="${1:?usage: $0 <run-id>}"
repo="${GITHUB_REPOSITORY:-praxstack/ledger-atlas}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
target="$root/tests/LedgerAtlasMacUITests/Fixtures/capture-baseline.json"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

gh run download "$run_id" --repo "$repo" --name ui-captures --dir "$work"
if [[ ! -s "$work/capture-baseline.json" ]]; then
  echo "run $run_id's ui-captures artifact has no capture-baseline.json" >&2
  exit 1
fi
mkdir -p "$(dirname "$target")"
cp "$work/capture-baseline.json" "$target"
echo "updated $target from run $run_id:"
git -C "$root" diff --stat -- "$target" || true
