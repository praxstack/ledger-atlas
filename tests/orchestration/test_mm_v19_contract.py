"""The v19 contract checker on synthetic databases built from the frozen DDL."""

from __future__ import annotations

import importlib.util
import sqlite3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "mm_v19_contract_check", ROOT / "scripts" / "mm_v19_contract_check.py"
)
assert SPEC and SPEC.loader
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)

DDL = (ROOT / "docs" / "compatibility" / "money-manager-android-v19.schema.sql").read_text()

# 2026-01-15 03:00 IST (+05:30) is 2026-01-14T21:30Z, so WDATE differs from the UTC date.
ZDATE = "1768426200000"
WDATE = "2026-01-15"


def _build(path: Path, *extra_sql: str) -> Path:
    db = sqlite3.connect(path)
    db.executescript(DDL)
    db.executescript(
        f"""
        INSERT INTO ASSETGROUP (uid, ACC_GROUP_NAME, TYPE) VALUES ('1', 'Cash', 1);
        INSERT INTO ASSETS (uid, NIC_NAME, groupUid, currencyUid) VALUES
          ('a-1', 'Wallet', '1', 'c-1'), ('a-2', 'Bank', '1', 'c-1');
        INSERT INTO ZCATEGORY (uid, NAME, TYPE, pUid) VALUES ('k-1', 'Food', 1, '0');
        INSERT INTO INOUTCOME (uid, assetUid, ctgUid, DO_TYPE, ZMONEY, ZDATE, WDATE) VALUES
          ('t-1', 'a-1', 'k-1', '1', '12.50', '{ZDATE}', '{WDATE}'),
          ('t-2', 'a-1', NULL, '3', '40.0', '{ZDATE}', '{WDATE}'),
          ('t-3', 'a-2', NULL, '4', '40.0', '{ZDATE}', '{WDATE}'),
          ('t-4', 'a-1', '-4', '7', '3.0', '{ZDATE}', '{WDATE}'),
          ('t-5', 'a-2', '-4', '8', '1.0', '{ZDATE}', '{WDATE}');
        UPDATE INOUTCOME SET toAssetUid = 'a-2', txUidTrans = 'g-1' WHERE uid = 't-2';
        UPDATE INOUTCOME SET toAssetUid = 'a-1', txUidTrans = 'g-1' WHERE uid = 't-3';
        """
    )
    for sql in extra_sql:
        db.executescript(sql)
    db.commit()
    db.close()
    return path


def test_contract_ddl_is_v19_with_19_tables() -> None:
    db = sqlite3.connect(":memory:")
    db.executescript(DDL)
    assert db.execute("PRAGMA user_version").fetchone()[0] == 19
    names = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
    assert len(names - {"sqlite_sequence"}) == 19


def test_synthetic_v19_is_compatible(tmp_path: Path) -> None:
    code, report = checker.check(_build(tmp_path / "ok.sqlite"))
    assert code == 0, report
    inv = report["invariants"]
    assert inv["reciprocal_transfer_pairs"] == 1
    assert inv["balance_modification_category_rows"] == 2
    offsets = inv["wdate_consistent_utc_offsets_minutes"]
    assert 330 in offsets and 0 not in offsets
    assert report["unchanged"] is True


def test_added_column_is_additive_drift(tmp_path: Path) -> None:
    path = _build(tmp_path / "drift.sqlite", "ALTER TABLE INOUTCOME ADD COLUMN newField TEXT;")
    code, report = checker.check(path)
    assert code == 1
    assert report["structure"]["extra_columns"] == ["INOUTCOME.newField"]


def test_missing_column_is_breaking(tmp_path: Path) -> None:
    path = _build(tmp_path / "broken.sqlite", "ALTER TABLE INOUTCOME DROP COLUMN gstd;")
    code, report = checker.check(path)
    assert code == 2
    assert report["structure"]["missing_columns"] == ["INOUTCOME.gstd"]


def test_unknown_type_and_one_sided_transfer_are_breaking(tmp_path: Path) -> None:
    path = _build(
        tmp_path / "semantic.sqlite",
        "UPDATE INOUTCOME SET DO_TYPE = '9' WHERE uid = 't-1';",
        "DELETE FROM INOUTCOME WHERE uid = 't-3';",
    )
    code, report = checker.check(path)
    assert code == 2
    assert "unknown_do_type_rows" in report["hard_failures"]
    assert "transfer legs not reciprocal" in report["hard_failures"]


def test_non_v19_and_non_sqlite_are_rejected(tmp_path: Path) -> None:
    text = tmp_path / "x.mmbak"
    text.write_bytes(b"PK\x03\x04 not sqlite")
    assert checker.check(text)[0] == 3
    other = tmp_path / "v18.sqlite"
    db = sqlite3.connect(other)
    db.execute("PRAGMA user_version = 18")
    db.close()
    assert checker.check(other) == (3, {"verdict": "not_v19", "user_version": 18})
