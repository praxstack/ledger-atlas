#!/usr/bin/env python3
"""Run path-disjoint ready atoms in isolated worktrees; never merge them."""

from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
import time
from pathlib import Path, PurePosixPath
from typing import Any

from orchestrion import ATOM_ID, load_validated_prd
from orchestrion_lib import HarnessError, atomic_write_json, repository_root
from run_unattended import load_policy, ready_atoms, require_clean_start


def paths_overlap(first: str, second: str) -> bool:
    left = PurePosixPath(first).parts
    right = PurePosixPath(second).parts
    shorter = min(len(left), len(right))
    return left[:shorter] == right[:shorter]


def select_disjoint(
    atoms: list[dict[str, Any]], limit: int, requested: set[str] | None = None
) -> list[dict[str, Any]]:
    selected: list[dict[str, Any]] = []
    owned: list[str] = []
    for atom in atoms:
        if requested is not None and atom["id"] not in requested:
            continue
        if any(
            paths_overlap(candidate, existing) for candidate in atom["paths"] for existing in owned
        ):
            continue
        selected.append(atom)
        owned.extend(atom["paths"])
        if len(selected) == limit:
            break
    return selected


def add_worktree(root: Path, base: Path, atom: dict[str, Any], run_id: str) -> tuple[Path, str]:
    identifier = atom["id"]
    if not ATOM_ID.fullmatch(identifier):
        raise HarnessError(f"unsafe atom id: {identifier}")
    branch = f"atom/{identifier.lower()}-{run_id}"
    worktree = base / identifier.lower()
    result = subprocess.run(
        ["git", "worktree", "add", "-b", branch, str(worktree), "HEAD"],
        cwd=root,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise HarnessError((result.stderr or result.stdout).strip())
    return worktree, branch


def run(args: argparse.Namespace) -> None:
    root = repository_root()
    require_clean_start(root)
    policy = load_policy(root)
    limit = min(args.jobs, policy.get("max_parallel_atoms", 3))
    requested = set(args.atoms) if args.atoms else None
    prd = load_validated_prd(root)
    available = ready_atoms(prd)
    if requested:
        unknown = requested - {atom["id"] for atom in available}
        if unknown:
            raise HarnessError("requested atoms are not ready: " + ", ".join(sorted(unknown)))
    selected = select_disjoint(available, limit, requested)
    if not selected:
        raise HarnessError("no path-disjoint ready atoms")
    if requested and {atom["id"] for atom in selected} != requested:
        raise HarnessError("requested atom paths overlap; split ownership or run sequentially")

    run_id = str(int(time.time()))
    worktree_base = root.parent / f".{root.name}-worktrees" / run_id
    worktree_base.mkdir(parents=True, exist_ok=False)
    receipt_dir = root / ".orchestrion/runtime/batches" / run_id
    receipt_dir.mkdir(parents=True)
    children: list[tuple[dict[str, Any], Path, str, subprocess.Popen[str]]] = []
    manifest: list[dict[str, Any]] = []
    for atom in selected:
        worktree, branch = add_worktree(root, worktree_base, atom, run_id)
        bootstrap = subprocess.run(
            ["uv", "sync", "--frozen"],
            cwd=worktree,
            text=True,
            capture_output=True,
            check=False,
        )
        if bootstrap.returncode != 0:
            raise HarnessError(
                f"could not prepare {atom['id']} worktree: "
                f"{(bootstrap.stderr or bootstrap.stdout).strip()}"
            )
        command = [
            sys.executable,
            str(worktree / "scripts/run_unattended.py"),
            "--atom",
            atom["id"],
            "--max-atoms",
            "1",
            "--max-minutes",
            str(min(args.max_minutes, policy["max_run_minutes"])),
            "--atom-minutes",
            str(min(args.atom_minutes, policy["max_atom_minutes"])),
            "--allow-gated-commits",
            "--allow-provider-review",
        ]
        log_path = receipt_dir / f"{atom['id']}.log"
        log = log_path.open("w", encoding="utf-8")
        process = subprocess.Popen(
            command,
            cwd=worktree,
            stdout=log,
            stderr=subprocess.STDOUT,
            text=True,
            start_new_session=True,
        )
        log.close()
        children.append((atom, worktree, branch, process))
        manifest.append(
            {
                "atom": atom["id"],
                "branch": branch,
                "worktree": str(worktree),
                "log": str(log_path),
                "paths": atom["paths"],
            }
        )
    atomic_write_json(receipt_dir / "manifest.json", {"schema_version": 1, "runs": manifest})

    deadline = time.monotonic() + min(args.max_minutes, policy["max_run_minutes"]) * 60
    while any(process.poll() is None for *_rest, process in children):
        if (root / ".orchestrion/off").exists() or time.monotonic() >= deadline:
            for _atom, worktree, _branch, process in children:
                if process.poll() is None:
                    (worktree / ".orchestrion/off").touch()
            graceful_deadline = time.monotonic() + 15
            while (
                any(process.poll() is None for *_rest, process in children)
                and time.monotonic() < graceful_deadline
            ):
                time.sleep(1)
            for *_rest, process in children:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
            raise HarnessError("batch stopped by kill switch or wall-clock ceiling")
        time.sleep(1)
    failures = [
        f"{atom['id']}={process.returncode}"
        for atom, _worktree, _branch, process in children
        if process.returncode != 0
    ]
    if failures:
        raise HarnessError("batch failures: " + ", ".join(failures))
    print(f"batch finished without merging; review branches in {receipt_dir / 'manifest.json'}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jobs", type=int, choices=range(1, 9), default=3)
    parser.add_argument("--atoms", nargs="*")
    parser.add_argument("--max-minutes", type=int, default=90)
    parser.add_argument("--atom-minutes", type=int, default=30)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        run(args)
    except (HarnessError, OSError, ValueError) as error:
        print(f"batch: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
