#!/usr/bin/env python3
"""The sole project commit path: exact staging, verification, review, attestation."""

from __future__ import annotations

import argparse
import json
import os
import secrets
import subprocess
import sys
import tempfile
import time
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path, PurePosixPath

from commit_attestation import GATE_KEY_ENV, attestation_path, create_attestation
from orchestrion import find_atom, load_validated_prd
from orchestrion_lib import (
    HarnessError,
    atomic_write_json,
    git_environment,
    git_output,
    is_p0_name,
    path_owned,
    qualified_executable,
    repository_root,
    run,
    sanitized_environment,
    sha256_bytes,
    sha256_file,
    staged_diff,
    staged_names,
    staged_tree,
    utc_now,
)
from review_changes import run_review

QUALIFIED_CODEX_SHA256 = "19c4f144c5226a9f17c58e6f0fa854843b0f77a6eb420f40e2745a12f10f5d37"
QUALIFIED_UV_SHA256 = "debc68c21b3bb1086e20d9889b53ff5ccf9ef343fda9a57dc2022212e3511125"
QUALIFIED_PYTHON_SHA256 = "7b05d803bbc1bbfc81644af4faf2b88f0a37b8de96b9f42c1e08033e2cd0848a"
QUALIFIED_XCRUN_SHA256 = "b8763cf250e607a778bb4603cecb5b90338814d0a3dfcba0d57b1de242f610e9"
EVIDENCE_ROOT = "/Users/prax/Developer/money-manager-reverse-engineering"


def verification_environment() -> dict[str, str]:
    qualified_executable("/usr/bin/git", QUALIFIED_XCRUN_SHA256)
    qualified_executable("/usr/bin/swift", QUALIFIED_XCRUN_SHA256)
    codex = Path(qualified_executable("codex", QUALIFIED_CODEX_SHA256))
    uv = Path(qualified_executable("uv", QUALIFIED_UV_SHA256))
    environment = sanitized_environment(codex.parent, uv.parent)
    environment["LEDGER_ATLAS_EVIDENCE_ROOT"] = EVIDENCE_ROOT
    return environment


def classify_p0(names: list[str], atom: dict[str, object]) -> bool:
    if atom.get("p0") is True:
        return True
    return any(is_p0_name(name) for name in names)


def assert_authority_live(root: Path, state: dict[str, object]) -> None:
    if (root / ".orchestrion/off").exists():
        raise HarnessError("kill switch .orchestrion/off exists")
    if state.get("enabled") is not True:
        raise HarnessError("active atom does not authorize a gated commit")
    started = state.get("started_epoch")
    if not isinstance(started, int | float):
        raise HarnessError("authority is missing started_epoch")
    now = time.time()
    if started > now:
        raise HarnessError("authority started_epoch is in the future")
    max_elapsed = state.get("max_elapsed_seconds")
    if isinstance(max_elapsed, int | float) and now - float(started) > float(max_elapsed):
        raise HarnessError("authority expired: elapsed time ceiling")
    iterations = state.get("iterations", 0)
    max_iterations = state.get("max_iterations")
    if (
        isinstance(max_iterations, int)
        and isinstance(iterations, int)
        and iterations >= max_iterations
    ):
        raise HarnessError("authority expired: iteration ceiling")
    same_failure = state.get("same_failure_count", 0)
    same_limit = state.get("same_failure_limit")
    if isinstance(same_limit, int) and isinstance(same_failure, int) and same_failure >= same_limit:
        raise HarnessError("authority expired: no-progress ceiling")


def untracked_names(root: Path) -> list[str]:
    output = run(["git", "ls-files", "-o", "-z"], root=root).stdout
    return [name for name in output.split("\0") if name]


def protected_names(root: Path) -> set[str]:
    names: set[str] = set()
    for raw_line in (
        (root / ".orchestrion/protected-inputs.sha256").read_text(encoding="utf-8").splitlines()
    ):
        if not raw_line.strip() or raw_line.lstrip().startswith("#"):
            continue
        _digest, path = raw_line.split(maxsplit=1)
        relative = PurePosixPath(path.strip())
        if relative.is_absolute() or ".." in relative.parts:
            raise HarnessError("unsafe protected-input manifest")
        names.add(relative.as_posix())
    return names


def active_run_authority(root: Path, atom: str) -> dict[str, object]:
    state_path = root / ".orchestrion/runtime/loop.json"
    try:
        state = json.loads(state_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise HarnessError(f"no valid active run authority: {error}") from error
    if (
        state.get("enabled") is not True
        or state.get("atom") != atom
        or state.get("allow_gated_commit") is not True
    ):
        raise HarnessError("active atom does not authorize a gated commit")
    assert_authority_live(root, state)
    return state


def preflight(root: Path) -> tuple[list[str], bool]:
    if (root / ".orchestrion/off").exists():
        raise HarnessError("kill switch .orchestrion/off exists")
    if git_output(root, "config", "--get", "core.hooksPath") != ".githooks":
        raise HarnessError("core.hooksPath must be exactly .githooks")
    diff = staged_diff(root)
    if not diff:
        raise HarnessError("nothing is staged; the gate never stages files")
    unstaged = run(["git", "diff", "--quiet", "--no-ext-diff"], root=root, check=False)
    if unstaged.returncode != 0:
        raise HarnessError("tracked unstaged changes exist; isolate the exact atom before review")
    names = staged_names(root)
    protected = protected_names(root)
    touched = sorted(set(names) & protected)
    if touched:
        raise HarnessError("protected source evidence is staged: " + ", ".join(touched))
    if any(name.startswith(".git/") or ".." in PurePosixPath(name).parts for name in names):
        raise HarnessError("unsafe staged path")
    p0 = any(is_p0_name(name) for name in names)
    return names, p0


def assert_untracked_paths_are_outside_atom(root: Path, atom: dict[str, object]) -> None:
    owned = [str(path) for path in atom["paths"]]
    missing = [name for name in untracked_names(root) if path_owned(name, owned)]
    if missing:
        raise HarnessError("untracked atom path is not staged: " + ", ".join(missing))


@contextmanager
def materialized_staged_tree(root: Path) -> Iterator[Path]:
    tree = staged_tree(root)
    with tempfile.TemporaryDirectory(prefix="ledger-gate-verify-") as directory:
        snapshot = Path(directory) / "repo"
        snapshot.mkdir()
        listing = subprocess.run(
            ["git", "ls-tree", "-r", "-z", tree],
            cwd=root,
            env=git_environment(),
            capture_output=True,
            check=False,
        )
        if listing.returncode != 0:
            raise HarnessError(
                "cannot enumerate staged tree: " + listing.stderr.decode("utf-8", "replace").strip()
            )
        for entry in listing.stdout.split(b"\0"):
            if not entry:
                continue
            metadata, raw_name = entry.split(b"\t", 1)
            mode, object_type, object_id = metadata.split()
            name = os.fsdecode(raw_name)
            relative = PurePosixPath(name)
            if relative.is_absolute() or ".." in relative.parts:
                raise HarnessError("unsafe path in staged tree")
            if object_type != b"blob" or mode not in {b"100644", b"100755", b"120000"}:
                raise HarnessError(f"unsupported staged entry: {name}")
            blob = subprocess.run(
                ["git", "cat-file", "blob", object_id.decode("ascii")],
                cwd=root,
                env=git_environment(),
                capture_output=True,
                check=False,
            )
            if blob.returncode != 0:
                raise HarnessError(
                    f"cannot read staged blob {name}: "
                    + blob.stderr.decode("utf-8", "replace").strip()
                )
            destination = snapshot / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            if mode == b"120000":
                os.symlink(os.fsdecode(blob.stdout), destination)
            else:
                destination.write_bytes(blob.stdout)
                destination.chmod(0o755 if mode == b"100755" else 0o644)
        for path in snapshot.rglob("*"):
            if not path.is_symlink():
                continue
            try:
                target = path.resolve(strict=True)
            except OSError as error:
                raise HarnessError(
                    f"staged symlink is broken: {path.relative_to(snapshot)}"
                ) from error
            if not target.is_relative_to(snapshot):
                raise HarnessError(
                    f"staged symlink escapes the exact tree: {path.relative_to(snapshot)}"
                )
        run(["git", "init", "-q", "-b", "gate-verification"], root=snapshot)
        project = snapshot / "pyproject.toml"
        lock = snapshot / "uv.lock"
        if project.is_file() or lock.is_file():
            if not project.is_file() or not lock.is_file():
                raise HarnessError("staged Python toolchain requires pyproject.toml and uv.lock")
            if (snapshot / ".venv").exists() or (snapshot / ".venv").is_symlink():
                raise HarnessError("staged tree may not contain .venv")
            uv = Path(qualified_executable("uv", QUALIFIED_UV_SHA256))
            environment = sanitized_environment(uv.parent)
            sync = subprocess.run(
                [
                    str(uv),
                    "sync",
                    "--frozen",
                    "--offline",
                    "--python",
                    "3.12.13",
                ],
                cwd=snapshot,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
            if sync.returncode != 0:
                raise HarnessError(
                    "cannot provision locked verification environment: "
                    + (sync.stderr or sync.stdout).strip()
                )
            interpreter = (snapshot / ".venv/bin/python").resolve()
            if not interpreter.is_file() or sha256_file(interpreter) != QUALIFIED_PYTHON_SHA256:
                raise HarnessError("locked Python interpreter changed")
        yield snapshot


def verification_receipt(root: Path, receipt_dir: Path) -> Path:
    log_path = receipt_dir / "verify-full.log"
    with materialized_staged_tree(root) as snapshot:
        result = run(
            [str(snapshot / "scripts/verify.sh"), "--full"],
            root=snapshot,
            env=verification_environment(),
            timeout=600,
            check=False,
        )
    combined = result.stdout + result.stderr
    log_path.write_text(combined, encoding="utf-8")
    if result.returncode != 0:
        raise HarnessError(f"full verification failed ({result.returncode}); inspect {log_path}")
    receipt_path = receipt_dir / "verify.json"
    atomic_write_json(
        receipt_path,
        {
            "schema_version": 1,
            "created_at": utc_now(),
            "verdict": "pass",
            "mode": "full",
            "staged_tree": staged_tree(root),
            "diff_sha256": sha256_bytes(staged_diff(root)),
            "log_sha256": sha256_bytes(combined.encode()),
        },
    )
    return receipt_path


def bind_prd_atom(root: Path, atom_id: str, names: list[str]) -> dict[str, object]:
    prd = load_validated_prd(root)
    atom = find_atom(prd, atom_id)
    if atom["status"] not in {"todo", "doing"}:
        raise HarnessError(f"cannot commit an atom with status {atom['status']}")
    done = {item["id"] for item in prd["atoms"] if item["status"] == "done"}
    missing = [dep for dep in atom.get("deps", []) if dep not in done]
    if missing:
        raise HarnessError("dependency-not-ready: " + ", ".join(missing))
    owned = [str(path) for path in atom["paths"]]
    outsiders = [name for name in names if not path_owned(name, owned)]
    if outsiders:
        raise HarnessError("staged path outside atom contract: " + ", ".join(outsiders))
    return atom


def gate(root: Path, args: argparse.Namespace) -> None:
    names, conservative_p0 = preflight(root)
    authority = active_run_authority(root, args.atom)
    if authority.get("allow_provider_review") is not True:
        raise HarnessError(
            "the active atom does not authorize provider review; re-arm it explicitly"
        )
    atom = bind_prd_atom(root, args.atom, names)
    assert_untracked_paths_are_outside_atom(root, atom)
    p0 = classify_p0(names, atom) or conservative_p0
    frozen_criterion = str(atom["criterion"]).strip()
    frozen_hash = sha256_bytes(frozen_criterion.encode())
    armed_hash = authority.get("criterion_sha256")
    if isinstance(armed_hash, str) and armed_hash != frozen_hash:
        raise HarnessError("armed criterion does not match the frozen PRD atom criterion")
    criterion = args.criterion.resolve()
    if not criterion.is_relative_to(root) or not criterion.is_file():
        raise HarnessError("criterion must be an existing repository file")
    if criterion.read_text(encoding="utf-8").strip() != frozen_criterion:
        raise HarnessError("caller criterion does not match the frozen PRD atom criterion")

    git_directory = Path(git_output(root, "rev-parse", "--git-dir"))
    if not git_directory.is_absolute():
        git_directory = root / git_directory
    receipt_dir = git_directory.resolve() / "orchestrion/receipts" / str(int(time.time()))
    receipt_dir.mkdir(parents=True, exist_ok=False)
    criterion_path = receipt_dir / "frozen-criterion.txt"
    criterion_path.write_text(frozen_criterion + "\n", encoding="utf-8")
    tree_before = staged_tree(root)

    verify_receipt = verification_receipt(root, receipt_dir)
    review_receipts: list[Path] = []
    lenses = ["reviewer", "red-team"] if p0 else ["reviewer"]
    codex = qualified_executable("codex", QUALIFIED_CODEX_SHA256)
    with materialized_staged_tree(root) as review_snapshot:
        for lens in lenses:
            output_path = receipt_dir / f"{lens}.json"
            receipt = run_review(
                root,
                lens=lens,
                criterion_path=criterion_path,
                output_path=output_path,
                codex=codex,
                review_root=review_snapshot,
            )
            if receipt["verdict"] != "pass":
                raise HarnessError(f"{lens} review failed; inspect {output_path}")
            review_receipts.append(output_path)

    if staged_tree(root) != tree_before:
        raise HarnessError("staged tree changed after verification/review")
    active_run_authority(root, args.atom)
    if git_output(root, "config", "--get", "core.hooksPath") != ".githooks":
        raise HarnessError("core.hooksPath must be exactly .githooks")
    if (root / ".orchestrion/off").exists():
        raise HarnessError("kill switch .orchestrion/off exists")

    gate_key = secrets.token_bytes(32)
    create_attestation(root, verify_receipt, review_receipts, gate_key=gate_key)

    # The pre-commit hook verifies the exact same attestation again.
    commit_environment = git_environment()
    commit_environment[GATE_KEY_ENV] = gate_key.hex()
    commit = subprocess.run(
        ["git", "commit", "-m", args.message],
        cwd=root,
        env=commit_environment,
        text=True,
        check=False,
    )
    try:
        attestation_path(root).unlink(missing_ok=True)
    except OSError as error:
        print(f"warning: could not remove spent attestation: {error}", file=sys.stderr)
    if commit.returncode != 0:
        raise HarnessError(f"git commit failed ({commit.returncode})")
    print(
        f"committed exact staged tree with full verification and {len(lenses)} review lens(es); "
        f"receipts={receipt_dir}; files={len(names)}"
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--atom", required=True)
    parser.add_argument("--message", required=True)
    parser.add_argument("--criterion", type=Path, required=True)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        gate(repository_root(), args)
    except (HarnessError, OSError, ValueError) as error:
        print(f"gate-commit: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
