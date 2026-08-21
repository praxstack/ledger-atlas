#!/usr/bin/env python3
"""Create or verify a short-lived attestation for the exact staged Git tree."""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import sys
import time
from pathlib import Path
from typing import Any

from orchestrion_lib import (
    HarnessError,
    atomic_write_json,
    git_output,
    is_p0_name,
    repository_root,
    sha256_bytes,
    sha256_file,
    staged_diff,
    staged_names,
    staged_tree,
    utc_now,
)

MAX_AGE_SECONDS = 900
EXPECTED_REVIEWER = "codex-ephemeral-read-only"
GATE_KEY_ENV = "LEDGER_ATLAS_GATE_KEY"


def gate_key_from_environment() -> bytes:
    try:
        key = bytes.fromhex(os.environ[GATE_KEY_ENV])
    except (KeyError, ValueError) as error:
        raise HarnessError("missing or invalid short-lived gate capability") from error
    if len(key) != 32:
        raise HarnessError("missing or invalid short-lived gate capability")
    return key


def attestation_hmac(value: dict[str, Any], gate_key: bytes) -> str:
    unsigned = {key: item for key, item in value.items() if key != "auth_hmac_sha256"}
    payload = json.dumps(unsigned, sort_keys=True, separators=(",", ":")).encode()
    return hmac.new(gate_key, payload, hashlib.sha256).hexdigest()


def active_atom_declares_p0(root: Path) -> bool:
    state_path = root / ".orchestrion/runtime/loop.json"
    if not state_path.is_file():
        return False
    try:
        state = json.loads(state_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise HarnessError(f"invalid active run state: {error}") from error
    if not isinstance(state, dict):
        raise HarnessError("invalid active run state shape")
    if state.get("enabled") is not True:
        return False
    atom_id = state.get("atom")
    prd_path = root / "prd.json"
    try:
        prd = json.loads(prd_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise HarnessError(f"invalid PRD while checking review lenses: {error}") from error
    if not isinstance(prd, dict) or not isinstance(prd.get("atoms"), list):
        raise HarnessError("invalid PRD shape while checking review lenses")
    for atom in prd["atoms"]:
        if isinstance(atom, dict) and atom.get("id") == atom_id:
            return atom.get("p0") is True
    raise HarnessError("active atom is absent from the PRD")


def required_review_lenses(root: Path) -> set[str]:
    p0 = active_atom_declares_p0(root) or any(is_p0_name(name) for name in staged_names(root))
    return {"reviewer", "red-team"} if p0 else {"reviewer"}


def attestation_path(root: Path) -> Path:
    git_dir_text = git_output(root, "rev-parse", "--git-dir")
    git_dir = Path(git_dir_text)
    if not git_dir.is_absolute():
        git_dir = root / git_dir
    return git_dir.resolve() / "orchestrion/commit-attestation.json"


def create_attestation(
    root: Path, verify_receipt: Path, reviews: list[Path], *, gate_key: bytes
) -> dict[str, Any]:
    if len(gate_key) != 32:
        raise HarnessError("invalid short-lived gate capability")
    review_values = []
    required_lenses = required_review_lenses(root)
    seen_lenses: set[str] = set()
    current_tree = staged_tree(root)
    current_diff = sha256_bytes(staged_diff(root))
    for path in reviews:
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise HarnessError(f"invalid review receipt {path}: {error}") from error
        if not isinstance(value, dict):
            raise HarnessError(f"review receipt is not an object: {path}")
        if value.get("verdict") != "pass":
            raise HarnessError(f"review receipt is not passing: {path}")
        lens = value.get("lens")
        if value.get("schema_version") != 1 or value.get("reviewer") != EXPECTED_REVIEWER:
            raise HarnessError(f"review receipt has an invalid producer or schema: {path}")
        if lens not in required_lenses or lens in seen_lenses:
            raise HarnessError(f"review receipt has a duplicate or unexpected lens: {path}")
        binding = value.get("binding")
        if not isinstance(binding, dict):
            raise HarnessError(f"review receipt has an invalid binding: {path}")
        if binding.get("staged_tree") != current_tree or binding.get("diff_sha256") != current_diff:
            raise HarnessError(f"review receipt is stale for the staged tree: {path}")
        review_values.append(
            {
                "path": str(path),
                "sha256": sha256_file(path),
                "lens": lens,
                "reviewer": EXPECTED_REVIEWER,
            }
        )
        seen_lenses.add(lens)
    if seen_lenses != required_lenses:
        raise HarnessError("review receipts do not satisfy the required lens set")
    try:
        verification = json.loads(verify_receipt.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise HarnessError(f"invalid verification receipt: {error}") from error
    if not isinstance(verification, dict):
        raise HarnessError("verification receipt is not an object")
    if verification.get("verdict") != "pass" or verification.get("staged_tree") != current_tree:
        raise HarnessError("verification receipt is not passing for the staged tree")
    value = {
        "schema_version": 2,
        "created_at": utc_now(),
        "created_epoch": int(time.time()),
        "staged_tree": current_tree,
        "diff_sha256": current_diff,
        "required_lenses": sorted(required_lenses),
        "verify_receipt": {
            "path": str(verify_receipt),
            "sha256": sha256_file(verify_receipt),
        },
        "reviews": review_values,
    }
    value["auth_hmac_sha256"] = attestation_hmac(value, gate_key)
    atomic_write_json(attestation_path(root), value)
    return value


def check_attestation(root: Path, *, gate_key: bytes | None = None) -> None:
    gate_key = gate_key or gate_key_from_environment()
    path = attestation_path(root)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise HarnessError(f"missing or invalid commit attestation: {error}") from error
    if not isinstance(value, dict):
        raise HarnessError("commit attestation is not an object")
    if set(value) != {
        "schema_version",
        "created_at",
        "created_epoch",
        "staged_tree",
        "diff_sha256",
        "required_lenses",
        "verify_receipt",
        "reviews",
        "auth_hmac_sha256",
    }:
        raise HarnessError("commit attestation has an unexpected shape")
    if value["schema_version"] != 2:
        raise HarnessError("unsupported commit attestation schema")
    expected_hmac = attestation_hmac(value, gate_key)
    if not isinstance(value["auth_hmac_sha256"], str) or not hmac.compare_digest(
        value["auth_hmac_sha256"], expected_hmac
    ):
        raise HarnessError("commit attestation lacks the short-lived gate capability")
    if not isinstance(value["created_epoch"], int) or not isinstance(value["reviews"], list):
        raise HarnessError("commit attestation contains invalid field types")
    age = int(time.time()) - value["created_epoch"]
    if age < 0 or age > MAX_AGE_SECONDS:
        raise HarnessError("commit attestation is stale")
    if value["staged_tree"] != staged_tree(root) or value["diff_sha256"] != sha256_bytes(
        staged_diff(root)
    ):
        raise HarnessError("staged tree changed after verification/review")
    required_lenses = sorted(required_review_lenses(root))
    if value["required_lenses"] != required_lenses:
        raise HarnessError("commit attestation has the wrong required lens set")
    if any(not isinstance(review, dict) for review in value["reviews"]):
        raise HarnessError("commit attestation contains an invalid review entry")
    review_lenses = [review.get("lens") for review in value["reviews"]]
    if any(lens not in {"reviewer", "red-team"} for lens in review_lenses):
        raise HarnessError("commit attestation contains an invalid review lens")
    if sorted(review_lenses) != required_lenses or len(review_lenses) != len(set(review_lenses)):
        raise HarnessError("commit attestation does not contain the exact review lenses")
    receipt_entries = [value["verify_receipt"], *value["reviews"]]
    for receipt in receipt_entries:
        if not isinstance(receipt, dict) or not {"path", "sha256"} <= set(receipt):
            raise HarnessError("commit attestation receipt entry is invalid")
        path_value = Path(receipt["path"])
        if not path_value.is_absolute():
            path_value = root / path_value
        if not path_value.is_file() or sha256_file(path_value) != receipt["sha256"]:
            raise HarnessError(f"attested receipt changed or is missing: {path_value}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check")
    parser.parse_args()
    try:
        root = repository_root()
        check_attestation(root)
        print("commit attestation passed")
    except (HarnessError, OSError, ValueError) as error:
        print(f"attestation: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
