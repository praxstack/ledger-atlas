#!/usr/bin/env python3
"""Verify immutable source evidence against the repository manifest."""

from __future__ import annotations

import sys
from pathlib import Path, PurePosixPath

from orchestrion_lib import HarnessError, repository_root, sha256_file


def parse_manifest(root: Path) -> list[tuple[str, Path]]:
    manifest = root / ".orchestrion" / "protected-inputs.sha256"
    try:
        lines = manifest.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise HarnessError(f"cannot read {manifest}: {error}") from error

    entries: list[tuple[str, Path]] = []
    seen: set[str] = set()
    for number, raw_line in enumerate(lines, 1):
        if not raw_line.strip() or raw_line.lstrip().startswith("#"):
            continue
        try:
            digest, relative_text = raw_line.split(maxsplit=1)
        except ValueError as error:
            raise HarnessError(f"invalid manifest line {number}") from error
        relative = PurePosixPath(relative_text.strip())
        if (
            len(digest) != 64
            or any(character not in "0123456789abcdef" for character in digest)
            or relative.is_absolute()
            or ".." in relative.parts
            or relative_text in seen
        ):
            raise HarnessError(f"unsafe or duplicate manifest line {number}")
        target = (root / Path(*relative.parts)).resolve()
        if not target.is_relative_to(root.resolve()):
            raise HarnessError(f"manifest path escapes repository on line {number}")
        seen.add(relative_text)
        entries.append((digest, target))

    if not entries:
        raise HarnessError("protected-input manifest is empty")
    return entries


def check(root: Path) -> list[str]:
    errors: list[str] = []
    for expected, path in parse_manifest(root):
        relative = path.relative_to(root)
        if not path.is_file():
            errors.append(f"missing: {relative}")
            continue
        actual = sha256_file(path)
        if actual != expected:
            errors.append(f"hash mismatch: {relative}")
    return errors


def main() -> int:
    try:
        root = repository_root()
        errors = check(root)
    except HarnessError as error:
        print(f"protected-input check failed: {error}", file=sys.stderr)
        return 2
    if errors:
        print("protected-input check failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print(f"protected-input check passed ({len(parse_manifest(root))} files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
