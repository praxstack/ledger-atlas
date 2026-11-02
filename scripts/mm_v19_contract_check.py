#!/usr/bin/env python3
"""Check a Money Manager Android backup against the frozen v19 schema contract.

The source is opened read-only and immutable, hashed before and after, and the
report holds counts only: no names, notes, amounts, identifiers, or paths.

Exit codes:
  0  compatible: every contract table and column is present, invariants hold
  1  additive drift: extra tables/columns or a soft invariant miss; import can
     continue only if the new data is preserved as a sidecar
  2  breaking: a contract table or column is missing, or a hard invariant fails
  3  not a SQLite file, or not user_version 19

Usage: scripts/mm_v19_contract_check.py <backup.sqlite|backup.mmbak> [--json]
"""

from __future__ import annotations

import hashlib
import json
import re
import sqlite3
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path

CONTRACT = (
    Path(__file__).resolve().parent.parent
    / "docs"
    / "compatibility"
    / "money-manager-android-v19.schema.sql"
)
SQLITE_MAGIC = b"SQLite format 3\x00"
KNOWN_DO_TYPES = {"0", "1", "3", "4", "7"}
PLAIN_DECIMAL = re.compile(r"^\d+(\.\d+)?$")
LOCAL_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
EPOCH_MS = re.compile(r"^\d{13}$")
BALANCE_MODIFICATION_CATEGORY = "-4"


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _columns(connection: sqlite3.Connection, table: str) -> dict[str, str]:
    rows = connection.execute(f'PRAGMA table_info("{table}")').fetchall()
    return {row[1]: (row[2] or "").upper() for row in rows}


def _tables(connection: sqlite3.Connection) -> list[str]:
    rows = connection.execute(
        "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
    ).fetchall()
    return [row[0] for row in rows]


def _contract() -> sqlite3.Connection:
    contract = sqlite3.connect(":memory:")
    contract.executescript(CONTRACT.read_text(encoding="utf-8"))
    return contract


def _structure(source: sqlite3.Connection) -> dict:
    contract = _contract()
    expected = set(_tables(contract))
    observed = set(_tables(source))
    missing_columns: list[str] = []
    extra_columns: list[str] = []
    retyped_columns: list[str] = []
    for table in sorted(expected & observed):
        want = _columns(contract, table)
        have = _columns(source, table)
        missing_columns += [f"{table}.{name}" for name in sorted(set(want) - set(have))]
        extra_columns += [f"{table}.{name}" for name in sorted(set(have) - set(want))]
        retyped_columns += [
            f"{table}.{name}" for name in sorted(set(want) & set(have)) if want[name] != have[name]
        ]
    return {
        "missing_tables": sorted(expected - observed),
        "extra_tables": sorted(observed - expected),
        "missing_columns": missing_columns,
        "extra_columns": extra_columns,
        "retyped_columns": retyped_columns,
    }


def _count(connection: sqlite3.Connection, sql: str) -> int:
    return int(connection.execute(sql).fetchone()[0] or 0)


def _wdate_offsets(rows: list[tuple[str, str]]) -> list[int]:
    """Return every UTC offset (minutes, 15-minute grid) under which WDATE == local date of ZDATE."""
    instants = []
    for zdate, wdate in rows:
        if not (EPOCH_MS.match(zdate or "") and LOCAL_DATE.match(wdate or "")):
            return []
        instants.append((datetime.fromtimestamp(int(zdate) / 1000, UTC), wdate))
    offsets = []
    for minutes in range(-12 * 60, 14 * 60 + 1, 15):
        shift = timedelta(minutes=minutes)
        if all((instant + shift).date().isoformat() == wdate for instant, wdate in instants):
            offsets.append(minutes)
    return offsets


def _invariants(source: sqlite3.Connection) -> dict:
    tx = "INOUTCOME"
    rows = source.execute(f"SELECT DO_TYPE, ZMONEY, ZDATE, WDATE FROM {tx}").fetchall()
    do_types: dict[str, int] = {}
    for row in rows:
        key = str(row[0])
        do_types[key] = do_types.get(key, 0) + 1
    amounts = [str(row[1]) if row[1] is not None else "" for row in rows]
    pairs = source.execute(
        f"""SELECT count(*) FROM {tx} a JOIN {tx} b
            ON a.txUidTrans = b.txUidTrans AND a.DO_TYPE = '3' AND b.DO_TYPE = '4'
            WHERE a.ZMONEY = b.ZMONEY AND a.assetUid = b.toAssetUid
              AND a.toAssetUid = b.assetUid AND a.WDATE = b.WDATE"""
    ).fetchone()[0]
    sentinel = BALANCE_MODIFICATION_CATEGORY
    return {
        "transactions": len(rows),
        "do_type_rows": dict(sorted(do_types.items())),
        "unknown_do_type_rows": sum(n for k, n in do_types.items() if k not in KNOWN_DO_TYPES),
        "amount_not_plain_decimal": sum(1 for a in amounts if not PLAIN_DECIMAL.match(a)),
        "amount_more_than_2_fraction_digits": sum(
            1 for a in amounts if PLAIN_DECIMAL.match(a) and len(a.partition(".")[2]) > 2
        ),
        "zdate_not_epoch_ms": sum(1 for r in rows if not EPOCH_MS.match(str(r[2] or ""))),
        "wdate_not_local_date": sum(1 for r in rows if not LOCAL_DATE.match(str(r[3] or ""))),
        "wdate_consistent_utc_offsets_minutes": _wdate_offsets(
            [(str(r[2] or ""), str(r[3] or "")) for r in rows]
        ),
        "transfer_out_rows": do_types.get("3", 0),
        "transfer_in_rows": do_types.get("4", 0),
        "reciprocal_transfer_pairs": int(pairs),
        "balance_modification_category_rows": _count(
            source, f"SELECT count(*) FROM {tx} WHERE ctgUid = '{sentinel}'"
        ),
        "recurrence_generated_rows": _count(
            source, f"SELECT count(*) FROM {tx} WHERE instr(uid, '_') > 0"
        ),
        "orphan_account_refs": _count(
            source, f"SELECT count(*) FROM {tx} WHERE assetUid NOT IN (SELECT uid FROM ASSETS)"
        ),
        "orphan_destination_account_refs": _count(
            source,
            f"""SELECT count(*) FROM {tx} WHERE coalesce(toAssetUid, '') <> ''
                AND toAssetUid NOT IN (SELECT uid FROM ASSETS)""",
        ),
        "orphan_category_refs_excluding_sentinel": _count(
            source,
            f"""SELECT count(*) FROM {tx} WHERE coalesce(ctgUid, '') NOT IN ('', '{sentinel}')
                AND ctgUid NOT IN (SELECT uid FROM ZCATEGORY)""",
        ),
        "orphan_live_photo_refs": _count(
            source,
            f"""SELECT count(*) FROM PHOTO WHERE coalesce(IS_DEL, 0) = 0
                AND txUid NOT IN (SELECT uid FROM {tx})""",
        ),
        "category_parent_orphans": _count(
            source,
            """SELECT count(*) FROM ZCATEGORY WHERE coalesce(pUid, '') NOT IN ('', '0')
               AND pUid NOT IN (SELECT uid FROM ZCATEGORY)""",
        ),
    }


def check(path: Path) -> tuple[int, dict]:
    with path.open("rb") as handle:
        if handle.read(16) != SQLITE_MAGIC:
            return 3, {"verdict": "not_sqlite"}
    before = _sha256(path)
    uri = f"file:{path.resolve()}?mode=ro&immutable=1"
    source = sqlite3.connect(uri, uri=True)
    try:
        source.execute("PRAGMA query_only = ON")
        user_version = source.execute("PRAGMA user_version").fetchone()[0]
        if user_version != 19:
            return 3, {"verdict": "not_v19", "user_version": user_version}
        structure = _structure(source)
        breaking_structure = bool(structure["missing_tables"] or structure["missing_columns"])
        invariants = {} if breaking_structure else _invariants(source)
    finally:
        source.close()
    after = _sha256(path)

    hard: list[str] = []
    soft: list[str] = []
    if breaking_structure:
        hard.append("contract tables or columns missing")
    if before != after:
        hard.append("source bytes changed during the check")
    if invariants:
        for key in (
            "unknown_do_type_rows",
            "amount_not_plain_decimal",
            "zdate_not_epoch_ms",
            "wdate_not_local_date",
            "orphan_account_refs",
        ):
            if invariants[key]:
                hard.append(key)
        if invariants["transfer_out_rows"] != invariants["reciprocal_transfer_pairs"]:
            hard.append("transfer legs not reciprocal")
        if invariants["transfer_in_rows"] != invariants["reciprocal_transfer_pairs"]:
            hard.append("transfer legs not reciprocal")
        if not invariants["wdate_consistent_utc_offsets_minutes"]:
            soft.append("no single UTC offset explains every WDATE")
    if structure["extra_tables"] or structure["extra_columns"] or structure["retyped_columns"]:
        soft.append("schema has additive drift; preserve new data as sidecars")

    code = 2 if hard else 1 if soft else 0
    report = {
        "verdict": {0: "compatible", 1: "additive_drift", 2: "breaking"}[code],
        "source_sha256": before,
        "unchanged": before == after,
        "user_version": 19,
        "structure": structure,
        "invariants": invariants,
        "hard_failures": sorted(set(hard)),
        "soft_findings": soft,
    }
    return code, report


def main(argv: list[str]) -> int:
    args = [a for a in argv if not a.startswith("--")]
    if len(args) != 1:
        print(__doc__, file=sys.stderr)
        return 3
    code, report = check(Path(args[0]))
    if "--json" in argv:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(f"{report['verdict']} (exit {code})")
        for item in report.get("hard_failures", []) + report.get("soft_findings", []):
            print(f"  - {item}")
    return code


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
