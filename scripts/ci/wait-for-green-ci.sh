#!/usr/bin/env bash
# Waits until the CI workflow's required checks have passed on a commit, so a release is only
# published from a commit whose tests ran to the end and passed (#186).
#
# usage: wait-for-green-ci.sh SHA [MAX_MINUTES]
# Needs GH_TOKEN with checks:read and GITHUB_REPOSITORY. Exits 0 when every required check has
# a successful run on SHA, 1 when one finished without success and none is still running, and
# 1 on timeout.
set -euo pipefail

sha=${1:?usage: wait-for-green-ci.sh SHA [MAX_MINUTES]}
max_minutes=${2:-60}
repo=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}
required=("Swift build + test (macOS)" "Web + Python checks")

deadline=$(($(date +%s) + max_minutes * 60))
while :; do
  runs=$(gh api --paginate "repos/$repo/commits/$sha/check-runs?per_page=100" \
    --jq '.check_runs[] | [.name, .status, (.conclusion // "")] | @tsv')
  waiting=0
  for name in "${required[@]}"; do
    mine=$(printf '%s\n' "$runs" | awk -F'\t' -v n="$name" '$1 == n')
    if printf '%s\n' "$mine" | awk -F'\t' '$3 == "success"' | grep -q .; then
      echo "ok: $name passed on ${sha::7}"
      continue
    fi
    if printf '%s\n' "$mine" | awk -F'\t' '$2 != "completed"' | grep -q .; then
      echo "waiting: $name is still running on ${sha::7}"
      waiting=1
      continue
    fi
    if [ -n "$mine" ]; then
      echo "::error::$name did not pass on ${sha::7}:"
      printf '%s\n' "$mine"
      exit 1
    fi
    echo "waiting: $name has not started on ${sha::7}"
    waiting=1
  done
  [ "$waiting" = 0 ] && exit 0
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "::error::CI on ${sha::7} did not finish within $max_minutes minutes"
    exit 1
  fi
  sleep 30
done
