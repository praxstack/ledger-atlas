#!/usr/bin/env python3
"""Fail closed when the local Codex surface drifts from the qualified harness."""

from __future__ import annotations

import json
import re
import subprocess
import sys
import tomllib
from pathlib import Path

from orchestrion_lib import HarnessError, repository_root

QUALIFIED_MINOR = (0, 147)
REQUIRED_FEATURES = {"goals", "hooks", "multi_agent"}
REQUIRED_EXEC_FLAGS = {
    "--ephemeral",
    "--strict-config",
    "--ignore-user-config",
    "--output-schema",
}


def execute(root: Path, args: list[str]) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(args, cwd=root, text=True, capture_output=True, check=False)
    if result.returncode != 0:
        raise HarnessError(
            f"Codex probe failed: {' '.join(args)}\n{(result.stderr or result.stdout).strip()}"
        )
    return result


def check(root: Path) -> list[str]:
    evidence: list[str] = []
    version_text = execute(root, ["codex", "--version"]).stdout.strip()
    match = re.search(r"(\d+)\.(\d+)\.(\d+)", version_text)
    if not match or tuple(map(int, match.groups()[:2])) != QUALIFIED_MINOR:
        raise HarnessError(
            f"Codex {version_text!r} is outside qualified minor 0.147; re-run harness qualification"
        )
    evidence.append(f"version={version_text}")

    feature_text = execute(root, ["codex", "features", "list"]).stdout
    enabled = {
        line.split()[0]
        for line in feature_text.splitlines()
        if len(line.split()) >= 3 and line.split()[-1] == "true"
    }
    missing = REQUIRED_FEATURES - enabled
    if missing:
        raise HarnessError(
            "required stable Codex features are not enabled: " + ", ".join(sorted(missing))
        )
    evidence.append("features=" + ",".join(sorted(REQUIRED_FEATURES)))

    help_text = execute(root, ["codex", "-a", "never", "exec", "--help"]).stdout
    missing_flags = {flag for flag in REQUIRED_EXEC_FLAGS if flag not in help_text}
    if missing_flags:
        raise HarnessError(
            "required codex exec flags are missing: " + ", ".join(sorted(missing_flags))
        )
    evidence.append("exec_flags=qualified")

    hooks_path = root / ".codex/hooks.json"
    hooks = json.loads(hooks_path.read_text(encoding="utf-8"))["hooks"]
    if set(hooks) != {"SessionStart", "PreToolUse", "Stop"}:
        raise HarnessError("project hooks must contain exactly SessionStart, PreToolUse, and Stop")
    if not (root / ".codex/hooks/orchestrion.py").is_file():
        raise HarnessError("project hook implementation is missing")
    evidence.append("hook_json=valid")

    with (root / ".codex/config.toml").open("rb") as handle:
        config = tomllib.load(handle)
    if "hooks" in config:
        raise HarnessError("hooks must have one representation; remove inline config hooks")
    if config.get("features", {}).get("hooks") is not True:
        raise HarnessError("project config must enable the hooks feature")
    for path in sorted((root / ".codex/agents").glob("*.toml")):
        with path.open("rb") as handle:
            agent = tomllib.load(handle)
        if agent.get("sandbox_mode") not in {"read-only", "workspace-write"}:
            raise HarnessError(f"agent has unsafe sandbox mode: {path}")
    evidence.append("project_config=valid")

    rules = str(root / ".codex/rules/default.rules")
    forbidden = execute(
        root,
        ["codex", "execpolicy", "check", "--rules", rules, "--", "git", "commit", "-m", "nope"],
    )
    if json.loads(forbidden.stdout).get("decision") != "forbidden":
        raise HarnessError("execpolicy did not forbid direct git commit")
    allowed = execute(
        root, ["codex", "execpolicy", "check", "--rules", rules, "--", "git", "status"]
    )
    if json.loads(allowed.stdout).get("decision") not in {None, "prompt", "allow"}:
        raise HarnessError("execpolicy unexpectedly blocks git status")
    evidence.append("execpolicy=deny-and-allow-probed")
    return evidence


def main() -> int:
    try:
        evidence = check(repository_root())
    except (
        HarnessError,
        OSError,
        ValueError,
        json.JSONDecodeError,
        tomllib.TOMLDecodeError,
    ) as error:
        print(f"codex-surface: {error}", file=sys.stderr)
        return 2
    print("Codex surface passed: " + "; ".join(evidence))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
