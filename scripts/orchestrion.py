#!/usr/bin/env python3
"""Validate atoms and arm/disarm the finite Codex continuation loop."""

from __future__ import annotations

import argparse
import re
import sys
import time
from collections import deque
from pathlib import Path, PurePosixPath
from typing import Any

from orchestrion_lib import (
    HarnessError,
    atomic_write_json,
    load_json,
    repository_root,
    sha256_bytes,
    utc_now,
)

ATOM_ID = re.compile(r"^[A-Z][A-Z0-9]{1,15}-[0-9]{3}$")
STATUSES = {"todo", "doing", "blocked", "done"}
RUNTIME = Path(".orchestrion/runtime/loop.json")


def prd_path(root: Path) -> Path:
    root_level = root / "prd.json"
    return root_level if root_level.is_file() else root / "research/orchestration/prd.json"


def validate_prd(value: Any) -> list[str]:
    errors: list[str] = []
    if not isinstance(value, dict) or value.get("schema_version") != 1:
        return ["prd must be an object with schema_version=1"]
    atoms = value.get("atoms")
    if not isinstance(atoms, list) or not atoms:
        return ["atoms must be a non-empty array"]

    identifiers: list[str] = []
    dependencies: dict[str, list[str]] = {}
    for index, atom in enumerate(atoms):
        label = f"atoms[{index}]"
        if not isinstance(atom, dict):
            errors.append(f"{label} must be an object")
            continue
        identifier = atom.get("id")
        if not isinstance(identifier, str) or not ATOM_ID.fullmatch(identifier):
            errors.append(f"{label}.id is invalid")
            continue
        identifiers.append(identifier)
        if not isinstance(atom.get("title"), str) or not atom["title"].strip():
            errors.append(f"{identifier}.title must be non-empty")
        if not isinstance(atom.get("criterion"), str) or not atom["criterion"].strip():
            errors.append(f"{identifier}.criterion must be non-empty")
        if atom.get("status") not in STATUSES:
            errors.append(f"{identifier}.status is invalid")
        if not isinstance(atom.get("p0"), bool):
            errors.append(f"{identifier}.p0 must be boolean")
        paths = atom.get("paths")
        if (
            not isinstance(paths, list)
            or not paths
            or any(
                not isinstance(path, str)
                or not path
                or PurePosixPath(path).is_absolute()
                or ".." in PurePosixPath(path).parts
                for path in paths or []
            )
        ):
            errors.append(f"{identifier}.paths must be non-empty safe repository paths")
        evidence = atom.get("evidence", [])
        if not isinstance(evidence, list) or any(not isinstance(item, str) for item in evidence):
            errors.append(f"{identifier}.evidence must be an array of strings")
        deps = atom.get("deps", [])
        if not isinstance(deps, list) or any(not isinstance(item, str) for item in deps):
            errors.append(f"{identifier}.deps must be an array of atom ids")
            deps = []
        dependencies[identifier] = deps
        if atom.get("status") == "done" and not evidence:
            errors.append(f"{identifier} is done without evidence")

    if len(identifiers) != len(set(identifiers)):
        errors.append("atom ids must be unique")
    identifier_set = set(identifiers)
    for identifier, deps in dependencies.items():
        for dependency in deps:
            if dependency == identifier:
                errors.append(f"{identifier} depends on itself")
            elif dependency not in identifier_set:
                errors.append(f"{identifier} has unknown dependency {dependency}")

    indegree = {identifier: 0 for identifier in identifiers}
    followers: dict[str, list[str]] = {identifier: [] for identifier in identifiers}
    for identifier, deps in dependencies.items():
        for dependency in deps:
            if dependency in indegree and dependency != identifier:
                indegree[identifier] += 1
                followers[dependency].append(identifier)
    ready = deque(identifier for identifier, count in indegree.items() if count == 0)
    visited = 0
    while ready:
        current = ready.popleft()
        visited += 1
        for follower in followers[current]:
            indegree[follower] -= 1
            if indegree[follower] == 0:
                ready.append(follower)
    if visited != len(identifiers):
        errors.append("atom dependency graph contains a cycle")
    return errors


def load_validated_prd(root: Path) -> dict[str, Any]:
    value = load_json(prd_path(root))
    errors = validate_prd(value)
    if errors:
        raise HarnessError("invalid prd:\n- " + "\n- ".join(errors))
    return value


def find_atom(prd: dict[str, Any], identifier: str) -> dict[str, Any]:
    for atom in prd["atoms"]:
        if atom["id"] == identifier:
            return atom
    raise HarnessError(f"unknown atom: {identifier}")


def command_validate(root: Path, _args: argparse.Namespace) -> None:
    prd = load_validated_prd(root)
    print(f"valid prd ({len(prd['atoms'])} atoms)")


def command_ready(root: Path, _args: argparse.Namespace) -> None:
    prd = load_validated_prd(root)
    done = {atom["id"] for atom in prd["atoms"] if atom["status"] == "done"}
    ready = [
        atom["id"]
        for atom in prd["atoms"]
        if atom["status"] == "todo" and set(atom.get("deps", [])) <= done
    ]
    print("\n".join(ready))


def command_start(root: Path, args: argparse.Namespace) -> None:
    if (root / ".orchestrion/off").exists():
        raise HarnessError("kill switch .orchestrion/off exists; remove it explicitly first")
    prd = load_validated_prd(root)
    atom = find_atom(prd, args.atom)
    if atom["status"] in {"done", "blocked"}:
        raise HarnessError(f"cannot arm an atom with status {atom['status']}")
    done = {item["id"] for item in prd["atoms"] if item["status"] == "done"}
    if not set(atom.get("deps", [])) <= done:
        raise HarnessError("cannot arm a dependency-not-ready atom")
    if args.criterion != atom["criterion"]:
        raise HarnessError("criterion must match the frozen PRD atom criterion")
    state = {
        "schema_version": 1,
        "enabled": True,
        "run_id": f"{args.atom}-{int(time.time())}",
        "atom": args.atom,
        "criterion": atom["criterion"],
        "criterion_sha256": sha256_bytes(atom["criterion"].encode()),
        "owned_paths": list(atom["paths"]),
        "p0": atom["p0"],
        "started_at": utc_now(),
        "started_epoch": int(time.time()),
        "max_iterations": args.max_iterations,
        "max_elapsed_seconds": args.max_minutes * 60,
        "same_failure_limit": args.same_failure_limit,
        "allow_gated_commit": args.allow_gated_commit,
        "allow_provider_review": args.allow_provider_review,
        "iterations": 0,
        "same_failure_count": 0,
        "last_failure_signature": None,
    }
    atomic_write_json(root / RUNTIME, state)
    print(f"armed {args.atom} as {state['run_id']}")


def command_stop(root: Path, _args: argparse.Namespace) -> None:
    path = root / RUNTIME
    if not path.exists():
        print("loop already inactive")
        return
    state = load_json(path)
    state["enabled"] = False
    state["stopped_at"] = utc_now()
    atomic_write_json(path, state)
    print(f"disarmed {state.get('run_id', 'unknown run')}")


def command_status(root: Path, _args: argparse.Namespace) -> None:
    path = root / RUNTIME
    if not path.exists():
        print("inactive")
        return
    state = load_json(path)
    print(
        f"{'active' if state.get('enabled') else 'inactive'} "
        f"atom={state.get('atom')} iteration={state.get('iterations')} "
        f"same_failure={state.get('same_failure_count')}"
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    validate = subparsers.add_parser("validate")
    validate.set_defaults(handler=command_validate)
    ready = subparsers.add_parser("ready")
    ready.set_defaults(handler=command_ready)
    loop = subparsers.add_parser("loop")
    loop_commands = loop.add_subparsers(dest="loop_command", required=True)
    start = loop_commands.add_parser("start")
    start.add_argument("--atom", required=True)
    start.add_argument("--criterion", required=True)
    start.add_argument("--max-iterations", type=int, choices=range(1, 13), default=6)
    start.add_argument("--max-minutes", type=int, choices=range(1, 121), default=30)
    start.add_argument("--same-failure-limit", type=int, choices=range(1, 6), default=3)
    start.add_argument("--allow-gated-commit", action="store_true")
    start.add_argument("--allow-provider-review", action="store_true")
    start.set_defaults(handler=command_start)
    stop = loop_commands.add_parser("stop")
    stop.set_defaults(handler=command_stop)
    status = loop_commands.add_parser("status")
    status.set_defaults(handler=command_status)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        root = repository_root()
        args.handler(root, args)
    except HarnessError as error:
        print(f"orchestrion: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
