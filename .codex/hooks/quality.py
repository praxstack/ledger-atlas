"""Small Ledger Atlas safety hook. It is not a commit permission system."""

from __future__ import annotations

import json
import os
import shlex
import sys
from pathlib import Path
from typing import Any

DEFAULT_EVIDENCE_ROOT = "/Users/prax/Developer/money-manager-reverse-engineering"
PROTECTED_FILES = {
    "/Users/prax/Downloads/Money Manager_26-08-2026.xlsx",
    "/Users/prax/Downloads/25-12-2024_24-12-2025.xlsx",
    "/Users/prax/Downloads/25-12-2025_24-12-2026.xlsx",
    "/Users/prax/Downloads/25-07-2026_24-08-2026.xlsx",
    "/Users/prax/Downloads/25-08-2026_24-09-2026.xlsx",
    "/Users/prax/Downloads/money_android.sqlite",
    "/Users/prax/Downloads/Money Manager Backup 26 Aug 2026.zip",
}
MUTATORS = {"cp", "dd", "install", "mv", "rm", "rsync", "tee", "touch", "truncate"}


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


def load_payload() -> dict[str, Any]:
    value = json.load(sys.stdin)
    if not isinstance(value, dict):
        raise TypeError("hook input must be an object")
    return value


def command_from(payload: dict[str, Any]) -> str:
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        return ""
    for key in ("command", "patch"):
        value = tool_input.get(key)
        if isinstance(value, str):
            return value
    return ""


def policy_reason(command: str) -> str | None:
    if not command:
        return None
    try:
        tokens = shlex.split(command)
    except ValueError:
        return "The command could not be parsed safely."

    lowered = [token.lower() for token in tokens]
    evidence_root = os.environ.get("LEDGER_ATLAS_EVIDENCE_ROOT", DEFAULT_EVIDENCE_ROOT)
    mentions_evidence = evidence_root in command or any(path in command for path in PROTECTED_FILES)
    executables = {Path(token).name.lower() for token in tokens}

    if (
        mentions_evidence
        and "sqlite3" in executables
        and not ("mode=ro" in command and "immutable=1" in command)
    ):
        return "Open original SQLite evidence with mode=ro&immutable=1."
    if mentions_evidence and (executables & MUTATORS or ">" in tokens or ">>" in tokens):
        return "Original Money Manager evidence is read-only; write to a derived copy."

    if "git" in executables and (
        "clean" in lowered or ("reset" in lowered and "--hard" in lowered)
    ):
        return "Destructive Git cleanup requires an explicit, separately reviewed action."

    if executables & {"mv", "rm", "rmdir"} and any("test" in token.lower() for token in tokens):
        return "Do not delete or move tests to make a check pass."
    return None


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in {"session_start", "pre_tool_use"}:
        print("usage: quality.py session_start|pre_tool_use", file=sys.stderr)
        return 2
    try:
        payload = load_payload()
        if sys.argv[1] == "session_start":
            emit(
                {
                    "hookSpecificOutput": {
                        "hookEventName": "SessionStart",
                        "additionalContext": (
                            "Ledger Atlas: read AGENTS.md, CONTEXT.md, SPEC.md, prd.json, and "
                            "docs/orchestration/RUNBOOK.md before editing. Keep original Money "
                            "Manager evidence read-only. Use focused tests, then the relevant "
                            "fast or full verifier. Normal Git commits are allowed after checks pass."
                        ),
                    }
                }
            )
        else:
            reason = policy_reason(command_from(payload))
            if reason:
                deny(reason)
            else:
                emit({})
    except Exception as error:  # noqa: BLE001 - hooks must handle malformed tool input.
        if sys.argv[1] == "pre_tool_use":
            deny(f"Ledger Atlas evidence check failed: {type(error).__name__}.")
        else:
            emit(
                {"systemMessage": f"Ledger Atlas startup context skipped: {type(error).__name__}."}
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
