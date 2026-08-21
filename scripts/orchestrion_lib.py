"""Shared, dependency-free helpers for the Ledger Atlas orchestration harness."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

P0_PREFIXES = (
    ".codex/",
    ".githooks/",
    ".orchestrion/",
    "docs/orchestration/",
    "scripts/",
    "src/",
    "Sources/",
    "Tests/",
    "tests/",
    "AGENTS.md",
    "CONTEXT.md",
    "Package.swift",
    "SPEC.md",
    "prd.json",
)
SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
QUALIFIED_GIT_SHA256 = "b8763cf250e607a778bb4603cecb5b90338814d0a3dfcba0d57b1de242f610e9"


class HarnessError(RuntimeError):
    """A deterministic harness failure that should be shown without a traceback."""


def sanitized_environment(*extra_path_entries: Path) -> dict[str, str]:
    blocked_prefixes = (
        "CODEX_",
        "DYLD_",
        "GIT_",
        "LD_",
        "LEDGER_ATLAS_GATE_",
        "PIP_",
        "PYTHON",
        "SWIFT",
        "UV_",
    )
    blocked_names = {
        "BASH_ENV",
        "CC",
        "CXX",
        "DEVELOPER_DIR",
        "ENV",
        "SDKROOT",
        "SHELLOPTS",
        "TOOLCHAINS",
        "VIRTUAL_ENV",
    }
    environment = {
        key: value
        for key, value in os.environ.items()
        if key not in blocked_names and not key.startswith(blocked_prefixes)
    }
    entries = [str(path.resolve()) for path in extra_path_entries]
    entries.extend(SYSTEM_PATH.split(os.pathsep))
    environment["PATH"] = os.pathsep.join(dict.fromkeys(entries))
    environment["PYTHONNOUSERSITE"] = "1"
    return environment


def git_environment() -> dict[str, str]:
    qualified_executable("/usr/bin/git", QUALIFIED_GIT_SHA256)
    environment = sanitized_environment()
    environment["GIT_NO_REPLACE_OBJECTS"] = "1"
    return environment


def assert_no_git_replacements(root: Path) -> None:
    result = subprocess.run(
        ["git", "for-each-ref", "--format=%(refname)", "refs/replace/"],
        cwd=root,
        env=git_environment(),
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise HarnessError("cannot inspect Git replacement refs")
    if result.stdout.strip():
        raise HarnessError("Git replacement refs are forbidden during gated work")


def qualified_executable(name: str, expected_sha256: str) -> str:
    candidate = shutil.which(name)
    if not candidate:
        raise HarnessError(f"qualified executable is unavailable: {name}")
    resolved = Path(candidate).resolve()
    if not resolved.is_file() or sha256_file(resolved) != expected_sha256:
        raise HarnessError(f"qualified executable changed: {name}")
    return str(resolved)


def repository_root(start: Path | None = None) -> Path:
    """Find the repository root without trusting an environment variable."""
    cursor = (start or Path.cwd()).resolve()
    for candidate in (cursor, *cursor.parents):
        if (candidate / ".git").exists() and (candidate / "AGENTS.md").is_file():
            return candidate
    raise HarnessError("not inside the Ledger Atlas Git repository")


def atomic_write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise HarnessError(f"cannot read valid JSON from {path}: {error}") from error


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(
    args: list[str],
    *,
    root: Path,
    timeout: int = 120,
    input_text: str | None = None,
    env: dict[str, str] | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    if env is None and args and Path(args[0]).name == "git":
        env = git_environment()
    result = subprocess.run(
        args,
        cwd=root,
        input=input_text,
        env=env,
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )
    if check and result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise HarnessError(
            f"command failed ({result.returncode}): {' '.join(args)}"
            + (f"\n{detail}" if detail else "")
        )
    return result


def git_output(root: Path, *args: str) -> str:
    assert_no_git_replacements(root)
    return run(["git", *args], root=root).stdout.strip()


def path_owned(name: str, prefixes: list[str]) -> bool:
    return any(
        name == raw.rstrip("/") or name.startswith(raw.rstrip("/") + "/") for raw in prefixes
    )


def is_p0_name(name: str) -> bool:
    return name.endswith(".swift") or path_owned(name, list(P0_PREFIXES))


def staged_names(root: Path) -> list[str]:
    assert_no_git_replacements(root)
    output = run(
        ["git", "diff", "--cached", "--name-only", "--diff-filter=ACDMRTUXB", "-z"],
        root=root,
    ).stdout
    return [name for name in output.split("\0") if name]


def staged_diff(root: Path) -> bytes:
    assert_no_git_replacements(root)
    result = subprocess.run(
        ["git", "diff", "--cached", "--binary", "--no-ext-diff", "--no-textconv"],
        cwd=root,
        env=git_environment(),
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise HarnessError(result.stderr.decode("utf-8", "replace").strip())
    return result.stdout


def staged_tree(root: Path) -> str:
    assert_no_git_replacements(root)
    return run(["git", "write-tree"], root=root).stdout.strip()


def utc_now() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
