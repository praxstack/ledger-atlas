#!/usr/bin/env bash
# Waits until the CI workflow has passed on a commit, so a release is only published from a
# commit whose tests ran to the end and passed (#186). It looks at the whole CI run's result,
# not at job names, so renaming or adding a job in ci.yml needs no change here. Pull request
# runs don't count: they may skip the Swift jobs, while push and tag runs always run them.
#
# usage: wait-for-green-ci.sh SHA [MAX_MINUTES]
# Needs GH_TOKEN with actions:read and GITHUB_REPOSITORY. Exits 0 when a CI run on SHA
# succeeded; 1 when every CI run on SHA finished without success, or on timeout.
set -euo pipefail

sha=${1:?usage: wait-for-green-ci.sh SHA [MAX_MINUTES]}
max_minutes=${2:-60}
repo=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}
workflow=ci.yml

deadline=$(($(date +%s) + max_minutes * 60))
while :; do
  runs=$(gh api "repos/$repo/actions/workflows/$workflow/runs?head_sha=$sha&per_page=50" \
    --jq '.workflow_runs[] | select(.event != "pull_request") | [.id, .event, .status, (.conclusion // "")] | @tsv')
  if printf '%s\n' "$runs" | awk -F'\t' '$4 == "success"' | grep -q .; then
    printf '%s\n' "$runs" | awk -F'\t' '$4 == "success" {print "ok: CI run " $1 " (" $2 ") passed on '"${sha::7}"'"; exit}'
    exit 0
  fi
  if [ -z "$runs" ]; then
    echo "waiting: no CI run on ${sha::7} yet"
  elif printf '%s\n' "$runs" | awk -F'\t' '$3 != "completed"' | grep -q .; then
    echo "waiting: CI is still running on ${sha::7}"
  else
    echo "::error::CI did not pass on ${sha::7}:"
    printf '%s\n' "$runs" | awk -F'\t' '{print "  run " $1 " (" $2 "): " $4}'
    exit 1
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "::error::CI on ${sha::7} did not finish within $max_minutes minutes"
    exit 1
  fi
  sleep 30
done
