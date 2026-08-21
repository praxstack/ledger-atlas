"""Codex lifecycle policy for Ledger Atlas.

This is a deterministic guardrail, not a security boundary. Repository sandboxing,
rules, protected-input hashes, the pre-commit hook, and remote branch policy remain
separate controls.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path, PurePosixPath
from typing import Any

POLICY_PATHS = {
    ".codex/hooks.json",
    ".codex/hooks/orchestrion.py",
    ".codex/rules/default.rules",
    ".githooks/pre-commit",
    "scripts/commit_attestation.py",
    "scripts/gate_commit.py",
    "scripts/gate-commit.sh",
    "scripts/review_changes.py",
    "scripts/verify.sh",
}
TEST_ROOTS = ("tests/", "__tests__/")
MUTATING_TOOLS = {
    "bash",
    "chmod",
    "chown",
    "cp",
    "dd",
    "install",
    "ln",
    "mv",
    "perl",
    "python",
    "python3",
    "rm",
    "rsync",
    "sed",
    "sh",
    "tee",
    "touch",
    "truncate",
}


def emit(value: dict[str, Any]) -> None:
    print(json.dumps(value, separators=(",", ":")))


def deny(reason: str) -> None:
    emit(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            }
        }
    )


def find_root(payload: dict[str, Any]) -> Path:
    start = Path(str(payload.get("cwd") or os.getcwd())).resolve()
    for candidate in (start, *start.parents):
        if (candidate / ".git").exists() and (candidate / "AGENTS.md").is_file():
            return candidate
    raise RuntimeError("Ledger Atlas repository root not found")


def load_payload() -> dict[str, Any]:
    try:
        value = json.load(sys.stdin)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"invalid hook JSON: {error}") from error
    if not isinstance(value, dict):
        raise TypeError("hook input must be a JSON object")
    return value


def protected_paths(root: Path) -> set[str]:
    paths: set[str] = set()
    manifest = root / ".orchestrion/protected-inputs.sha256"
    for line in manifest.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        _digest, relative = line.split(maxsplit=1)
        candidate = PurePosixPath(relative.strip())
        if candidate.is_absolute() or ".." in candidate.parts:
            raise RuntimeError("unsafe protected-input manifest")
        paths.add(candidate.as_posix())
    if not paths:
        raise RuntimeError("protected-input manifest is empty")
    return paths


def shell_tokens(command: str) -> list[str]:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|()<>")
    lexer.whitespace_split = True
    lexer.commenters = ""
    return list(lexer)


def mutating_tools(tokens: list[str]) -> set[str]:
    tools = {Path(token).name.lower() for token in tokens} & MUTATING_TOOLS
    if "sed" not in tools:
        return tools
    if not any(
        token == "--in-place"
        or token.startswith("--in-place=")
        or (token.startswith("-") and not token.startswith("--") and "i" in token[1:])
        for token in tokens
    ):
        tools.remove("sed")
    return tools


def git_subcommand(tokens: list[str], start: int) -> tuple[str | None, list[str]]:
    index = start + 1
    while index < len(tokens):
        token = tokens[index]
        if token in {"-C", "-c", "--git-dir", "--work-tree", "--namespace"}:
            index += 2
            continue
        if token.startswith(("--git-dir=", "--work-tree=", "--namespace=", "-c")):
            index += 1
            continue
        if token.startswith("-"):
            index += 1
            continue
        return token, tokens[index + 1 :]
    return None, []


def command_policy_reason(command: str, protected: set[str]) -> str | None:
    try:
        tokens = shell_tokens(command)
    except ValueError:
        return "Unparseable shell input is denied by the repository policy."
    lowered = [token.lower() for token in tokens]
    if "--no-verify" in lowered:
        return "Bypassing repository verification is forbidden."

    for index, token in enumerate(tokens):
        if Path(token).name.lower() != "git":
            continue
        subcommand, remaining = git_subcommand(tokens, index)
        normalized = (subcommand or "").lower()
        remaining_lower = [item.lower() for item in remaining]
        if normalized in {"commit", "push", "merge", "rebase", "clean"}:
            return f"Direct git {normalized} is forbidden; use the documented human gate."
        if normalized == "reset" and "--hard" in remaining_lower:
            return "Destructive git reset --hard is forbidden."
        if normalized == "config" and any("core.hookspath" in item for item in remaining_lower):
            return "Changing core.hooksPath would bypass the commit attestation."

    executable_names = {Path(token).name.lower() for token in tokens}
    mutators = mutating_tools(tokens)
    mentioned = {path for path in protected if path in command}
    has_redirection = any(token in {">", ">>", "<>", ">&"} for token in tokens)
    if mentioned and "sqlite3" in executable_names and not (
        "mode=ro" in command and "immutable=1" in command
    ):
        return "SQLite evidence may be opened only with mode=ro&immutable=1."
    if mentioned and (mutators or has_redirection):
        return "A source-evidence path is immutable; use a derived working copy."

    policy_mentioned = {path for path in POLICY_PATHS if path in command}
    if policy_mentioned and (mutators or has_redirection):
        return "An active atom may not rewrite its own orchestration controls."

    mutating_names = executable_names & {"rm", "mv", "rmdir"}
    if mutating_names and any(
        token.lower().lstrip("./").startswith(("tests/", "__tests__/"))
        or token.lower().rstrip("/").endswith(("tests", "__tests__"))
        or "/tests/" in token.lower()
        or "/__tests__/" in token.lower()
        for token in tokens
    ):
        return "Deleting or moving tests is forbidden by the repository policy."
    return None


def patch_paths(command: str) -> list[tuple[str, str]]:
    matches = re.findall(
        r"^\*\*\* (Add|Update|Delete) File: (.+?)\s*$", command, flags=re.MULTILINE
    )
    return [
        (operation.lower(), PurePosixPath(path.strip()).as_posix()) for operation, path in matches
    ]


def patch_policy_reason(command: str, protected: set[str]) -> str | None:
    paths = patch_paths(command)
    if not paths:
        return "An apply_patch call without explicit file headers is denied."
    for operation, path in paths:
        candidate = PurePosixPath(path)
        if candidate.is_absolute() or ".." in candidate.parts:
            return "Patch path must remain inside the repository."
        if path in protected:
            return "A source-evidence path is immutable; use a derived working copy."
        if path in POLICY_PATHS:
            return "Orchestration policy files require an explicit human-reviewed change."
        if operation == "delete" and path.lower().startswith(TEST_ROOTS):
            return "Deleting tests is forbidden by the repository policy."
    return None


def pre_tool_use(payload: dict[str, Any], root: Path) -> None:
    tool_name = str(payload.get("tool_name") or "")
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict) or not isinstance(tool_input.get("command"), str):
        deny("Missing or invalid command input is denied by the repository policy.")
        return
    command = tool_input["command"]
    protected = protected_paths(root)
    reason = (
        patch_policy_reason(command, protected)
        if tool_name == "apply_patch"
        else command_policy_reason(command, protected)
    )
    if reason:
        deny(reason)


def session_start(root: Path) -> None:
    state_path = root / ".orchestrion/runtime/loop.json"
    context = (
        "Ledger Atlas: read AGENTS.md and CONTEXT.md before editing. "
        "Source backups and screenshots are immutable. Autonomous loops are default-off; "
        "commit, push, merge, deploy, and destructive actions remain separately gated."
    )
    if state_path.is_file() and not (root / ".orchestrion/off").exists():
        try:
            state = json.loads(state_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            state = {}
        if state.get("enabled"):
            criterion = str(state.get("criterion", ""))[:500].replace("\n", " ")
            context += (
                f" Active bounded atom: {state.get('atom', 'unknown')}. "
                f"Frozen criterion: {criterion}"
            )
    emit(
        {
            "hookSpecificOutput": {
                "hookEventName": "SessionStart",
                "additionalContext": context,
            }
        }
    )


def disable_state(state_path: Path, state: dict[str, Any], reason: str) -> None:
    state["enabled"] = False
    state["stopped_reason"] = reason
    state["stopped_epoch"] = int(time.time())
    temporary = state_path.with_name(f".{state_path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, state_path)


def stop(root: Path) -> None:
    state_path = root / ".orchestrion/runtime/loop.json"
    if not state_path.is_file():
        emit({})
        return
    try:
        state = json.loads(state_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        emit({"systemMessage": "Orchestrion state is invalid; continuation was released safely."})
        return
    if not state.get("enabled"):
        emit({})
        return
    if (root / ".orchestrion/off").exists():
        disable_state(state_path, state, "kill_switch")
        emit({"systemMessage": "Orchestrion kill switch is active; continuation was stopped."})
        return

    for field in (
        "iterations",
        "same_failure_count",
        "max_iterations",
        "max_elapsed_seconds",
        "same_failure_limit",
        "started_epoch",
    ):
        if not isinstance(state.get(field), int) or state[field] < 0:
            disable_state(state_path, state, "invalid_state")
            emit(
                {
                    "systemMessage": "Orchestrion counters are invalid; continuation was released safely."
                }
            )
            return

    try:
        result = subprocess.run(
            [str(root / "scripts/verify.sh"), "--fast"],
            cwd=root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=110,
            check=False,
        )
        output = result.stdout[-64_000:]
    except (OSError, subprocess.TimeoutExpired) as error:
        result_code = 124
        output = f"verification runner error: {type(error).__name__}"
    else:
        result_code = result.returncode

    runtime = root / ".orchestrion/runtime"
    runtime.mkdir(parents=True, exist_ok=True)
    (runtime / "last-verify.log").write_text(output, encoding="utf-8")
    signature = hashlib.sha256(f"{result_code}\n{output}".encode()).hexdigest()[:16]
    state["iterations"] += 1
    if result_code == 0:
        disable_state(state_path, state, "verified")
        emit({"systemMessage": f"Bounded atom {state.get('atom')} passed fast verification."})
        return

    if signature == state.get("last_failure_signature"):
        state["same_failure_count"] += 1
    else:
        state["same_failure_count"] = 1
    state["last_failure_signature"] = signature
    state["last_failure_exit"] = result_code
    elapsed = int(time.time()) - state["started_epoch"]
    ceiling = state["iterations"] >= state["max_iterations"]
    stale = state["same_failure_count"] >= state["same_failure_limit"]
    expired = elapsed >= state["max_elapsed_seconds"]
    if ceiling or stale or expired:
        reason = "iteration_ceiling" if ceiling else "no_progress" if stale else "elapsed_ceiling"
        disable_state(state_path, state, reason)
        emit(
            {
                "systemMessage": (
                    f"Bounded atom {state.get('atom')} stopped at {reason}; "
                    f"verification exit={result_code}, signature={signature}. "
                    "Inspect .orchestrion/runtime/last-verify.log and revise the hypothesis."
                )
            }
        )
        return

    temporary = state_path.with_name(f".{state_path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, state_path)
    emit(
        {
            "decision": "block",
            "reason": (
                f"Continue bounded atom {state.get('atom')}. Fast verification failed "
                f"with exit={result_code}, signature={signature}, iteration="
                f"{state['iterations']}/{state['max_iterations']}. Inspect only "
                ".orchestrion/runtime/last-verify.log, form a changed hypothesis, make the "
                "smallest in-scope correction, and rerun the focused check. Do not commit."
            ),
        }
    )


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in {"session_start", "pre_tool_use", "stop"}:
        print("usage: orchestrion.py session_start|pre_tool_use|stop", file=sys.stderr)
        return 2
    try:
        payload = load_payload()
        root = find_root(payload)
        if sys.argv[1] == "session_start":
            session_start(root)
        elif sys.argv[1] == "pre_tool_use":
            pre_tool_use(payload, root)
        else:
            stop(root)
    except Exception as error:  # noqa: BLE001 - hooks must fail safe on any runtime fault.
        if sys.argv[1] == "pre_tool_use":
            deny(f"Orchestration policy failed closed: {type(error).__name__}.")
        else:
            emit({"systemMessage": f"Orchestration hook released safely: {type(error).__name__}."})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
