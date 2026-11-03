#!/usr/bin/env python3
"""Reconcile a Money Manager XLSX export against an imported Ledger Atlas ledger.

Money Manager can export every transaction to an XLSX workbook (sheet
"Money Manager"). This script reads that workbook and an imported canonical
ledger and compares, per kind and per calendar month, the row count and the
amount sum. It prints aggregates only: kinds, months, counts and sums. It never
prints dates of single rows, accounts, categories, notes or descriptions.

Kinds:
  income    XLSX "Income" rows        vs ledger events of kind income
  expense   XLSX "Expense" rows       vs ledger events of kind expense
  transfer  XLSX "Transfer-Out" rows  vs ledger transfer pairs (debit leg)
  balance   not in the XLSX export    vs ledger adjustment events
  same_account_transfer  XLSX "Transfer-Out" rows whose Category (the
            receiving account) is the sending Account; Ledger Atlas preserves
            these instead of mapping them, so they are counted, not compared

Money Manager records some balance edits ("Modified Bal.") as plain income or
expense rows; those count as income or expense on both sides. Balance edits
stored as adjustments are left out of the XLSX export, so "balance" is only
checked against --expect.

Exit codes:
  0  every kind and month matches (and every --expect total holds)
  1  a mismatch; each one is printed with its kind and month
  2  unreadable input: not an XLSX workbook, missing sheet or column, unknown
     kind, or not a Ledger Atlas ledger

Usage:
  scripts/mm_v19_xlsx_reconcile.py <export.xlsx> <ledger.sqlite>
      [--sheet "Money Manager"] [--through YYYY-MM]
      [--expect income=1146 --expect expense=5387 ...]
"""

from __future__ import annotations

import argparse
import re
import sqlite3
import sys
import zipfile
from collections import Counter
from datetime import date, timedelta
from decimal import Decimal, InvalidOperation
from pathlib import Path
from xml.etree import ElementTree

MAIN = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
REL = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}"
PKG_REL = "{http://schemas.openxmlformats.org/package/2006/relationships}"

KINDS = ("income", "expense", "transfer", "balance", "same_account_transfer")
# Kinds that only one side holds; they are reported and checked against --expect.
ONE_SIDED = {"balance": "ledger", "same_account_transfer": "xlsx"}
XLSX_KINDS = {"Income": "income", "Expense": "expense", "Transfer-Out": "transfer"}
# Money Manager also lists the receiving leg of a transfer in some versions; the
# outgoing leg already stands for the pair.
XLSX_SKIPPED_KINDS = {"Transfer-In"}
MAX_XML_BYTES = 256 * 1024 * 1024


class InputError(Exception):
    """The input cannot be reconciled. The message never quotes row content."""


class Totals:
    """Row count and amount sum per (kind, month)."""

    def __init__(self) -> None:
        self.count: Counter = Counter()
        self.amount: dict[tuple[str, str], Decimal] = {}

    def add(self, kind: str, month: str, amount: Decimal) -> None:
        key = (kind, month)
        self.count[key] += 1
        self.amount[key] = self.amount.get(key, Decimal(0)) + amount

    def kind_count(self, kind: str) -> int:
        return sum(n for (k, _), n in self.count.items() if k == kind)

    def kind_amount(self, kind: str) -> Decimal:
        return sum((a for (k, _), a in self.amount.items() if k == kind), Decimal(0))


def _column(reference: str) -> str:
    match = re.match(r"[A-Z]+", reference or "")
    if not match:
        raise InputError("a cell has no column reference")
    return match.group(0)


def _xml(archive: zipfile.ZipFile, name: str) -> ElementTree.Element:
    try:
        info = archive.getinfo(name)
    except KeyError as error:
        raise InputError(f"workbook part {name} is missing") from error
    if info.file_size > MAX_XML_BYTES:
        raise InputError(f"workbook part {name} is too large")
    return ElementTree.fromstring(archive.read(info))


def _sheet_part(archive: zipfile.ZipFile, sheet: str) -> tuple[str, bool]:
    workbook = _xml(archive, "xl/workbook.xml")
    properties = workbook.find(f"{MAIN}workbookPr")
    date1904 = properties is not None and properties.get("date1904") in ("1", "true")
    relation = None
    for entry in workbook.iter(f"{MAIN}sheet"):
        if entry.get("name") == sheet:
            relation = entry.get(f"{REL}id")
    if relation is None:
        raise InputError(f'sheet "{sheet}" is missing')
    for entry in _xml(archive, "xl/_rels/workbook.xml.rels").iter(f"{PKG_REL}Relationship"):
        if entry.get("Id") == relation:
            target = entry.get("Target", "").lstrip("/")
            return (target if target.startswith("xl/") else f"xl/{target}"), date1904
    raise InputError(f'sheet "{sheet}" has no worksheet part')


def _shared_strings(archive: zipfile.ZipFile) -> list[str]:
    if "xl/sharedStrings.xml" not in archive.namelist():
        return []
    return [
        "".join(text.text or "" for text in item.iter(f"{MAIN}t"))
        for item in _xml(archive, "xl/sharedStrings.xml").findall(f"{MAIN}si")
    ]


def _cell_value(cell: ElementTree.Element, strings: list[str]) -> str | None:
    kind = cell.get("t")
    if kind == "inlineStr":
        return "".join(text.text or "" for text in cell.iter(f"{MAIN}t"))
    value = cell.find(f"{MAIN}v")
    if value is None or value.text is None:
        return None
    if kind == "s":
        try:
            return strings[int(value.text)]
        except (ValueError, IndexError) as error:
            raise InputError("a cell points at a missing shared string") from error
    return value.text


def _month(serial: str, date1904: bool, row: int) -> str:
    try:
        days = int(Decimal(serial))
    except (InvalidOperation, ValueError) as error:
        raise InputError(f"row {row}: Date is not a spreadsheet date") from error
    epoch = date(1904, 1, 1) if date1904 else date(1899, 12, 30)
    return (epoch + timedelta(days=days)).strftime("%Y-%m")


def _amount(text: str | None, row: int) -> Decimal:
    try:
        return abs(Decimal((text or "").replace(",", "").strip()))
    except InvalidOperation as error:
        raise InputError(f"row {row}: Amount is not a number") from error


def read_xlsx(path: Path, sheet: str = "Money Manager") -> Totals:
    """Counts and sums per (kind, month) from a Money Manager XLSX export."""
    try:
        archive = zipfile.ZipFile(path)
    except (OSError, zipfile.BadZipFile) as error:
        raise InputError("the export is not an XLSX workbook") from error
    with archive:
        part, date1904 = _sheet_part(archive, sheet)
        strings = _shared_strings(archive)
        rows = _xml(archive, part).iter(f"{MAIN}row")
        header: dict[str, str] = {}
        for header_row in rows:
            for cell in header_row.findall(f"{MAIN}c"):
                name = _cell_value(cell, strings)
                # Money Manager repeats "Account"; the first column of a name wins.
                if name and name not in header:
                    header[name] = _column(cell.get("r", ""))
            break
        needed = ("Date", "Income/Expense", "Amount")
        missing = [name for name in needed if name not in header]
        if missing:
            raise InputError(f"column {', '.join(missing)} is missing")
        totals = Totals()
        for number, row in enumerate(rows, start=2):
            cells = {
                _column(cell.get("r", "")): _cell_value(cell, strings)
                for cell in row.findall(f"{MAIN}c")
            }
            if not any(cells.values()):
                continue
            label = cells.get(header["Income/Expense"])
            if label in XLSX_SKIPPED_KINDS:
                continue
            kind = XLSX_KINDS.get(label or "")
            if kind is None:
                raise InputError(f"row {number}: unknown Income/Expense kind")
            if (
                kind == "transfer"
                and "Category" in header
                and "Account" in header
                and cells.get(header["Category"]) == cells.get(header["Account"])
            ):
                kind = "same_account_transfer"
            totals.add(
                kind,
                _month(cells.get(header["Date"]) or "", date1904, number),
                _amount(cells.get(header["Amount"]), number),
            )
        return totals


LEDGER_QUERY = """
SELECT CASE e.event_kind
         WHEN 'income' THEN 'income'
         WHEN 'expense' THEN 'expense'
         ELSE 'balance' END,
       printf('%04d-%02d', e.local_year, e.local_month),
       e.amount_literal
FROM economic_event e
WHERE e.event_kind IN ('income', 'expense', 'adjustment', 'adjustment_debit')
UNION ALL
SELECT 'transfer', printf('%04d-%02d', d.local_year, d.local_month), d.amount_literal
FROM economic_event_transfer t
JOIN economic_event d ON d.event_id = t.debit_event_id
"""


def read_ledger(path: Path) -> Totals:
    """Counts and sums per (kind, month) from an imported canonical ledger."""
    if not path.is_file():
        raise InputError("the ledger file does not exist")
    uri = f"{path.resolve().as_uri()}?mode=ro&immutable=1"
    try:
        database = sqlite3.connect(uri, uri=True)
    except sqlite3.Error as error:
        raise InputError("the ledger cannot be opened") from error
    try:
        totals = Totals()
        for kind, month, literal in database.execute(LEDGER_QUERY):
            try:
                amount = abs(Decimal(literal))
            except (InvalidOperation, TypeError) as error:
                raise InputError("a ledger amount is not a decimal") from error
            totals.add(kind, month, amount)
        return totals
    except sqlite3.DatabaseError as error:
        raise InputError("the file is not a Ledger Atlas ledger") from error
    finally:
        database.close()


def _through(totals: Totals, last: str | None) -> Totals:
    if last is None:
        return totals
    kept = Totals()
    for (kind, month), count in totals.count.items():
        if month <= last:
            kept.count[(kind, month)] = count
            kept.amount[(kind, month)] = totals.amount[(kind, month)]
    return kept


def reconcile(xlsx: Totals, ledger: Totals) -> list[str]:
    """Mismatch lines, each naming its kind and month. Empty means reconciled."""
    problems = []
    months = sorted(
        {key for key in xlsx.count if key[0] not in ONE_SIDED}
        | {key for key in ledger.count if key[0] not in ONE_SIDED}
    )
    for kind, month in months:
        x_count, l_count = xlsx.count[(kind, month)], ledger.count[(kind, month)]
        x_sum = xlsx.amount.get((kind, month), Decimal(0))
        l_sum = ledger.amount.get((kind, month), Decimal(0))
        if x_count != l_count or x_sum != l_sum:
            problems.append(
                f"MISMATCH kind={kind} month={month} xlsx_count={x_count} "
                f"ledger_count={l_count} xlsx_sum={x_sum} ledger_sum={l_sum}"
            )
    return problems


def expectations(xlsx: Totals, ledger: Totals, expect: dict[str, int]) -> list[str]:
    """Mismatch lines for whole-file --expect totals."""
    problems = []
    for kind, expected in sorted(expect.items()):
        side = ONE_SIDED.get(kind, "ledger")
        actual = (xlsx if side == "xlsx" else ledger).kind_count(kind)
        if actual != expected:
            problems.append(
                f"MISMATCH kind={kind} month=all expected_count={expected} {side}_count={actual}"
            )
    return problems


def _expectation(text: str) -> tuple[str, int]:
    kind, _, value = text.partition("=")
    if kind not in KINDS or not value.isdigit():
        raise argparse.ArgumentTypeError(f"expected KIND=COUNT with KIND in {', '.join(KINDS)}")
    return kind, int(value)


def _month_argument(text: str) -> str:
    if not re.fullmatch(r"\d{4}-(0[1-9]|1[0-2])", text):
        raise argparse.ArgumentTypeError("expected YYYY-MM")
    return text


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("xlsx", type=Path)
    parser.add_argument("ledger", type=Path)
    parser.add_argument("--sheet", default="Money Manager")
    parser.add_argument(
        "--through", type=_month_argument, help="ignore months after YYYY-MM on both sides"
    )
    parser.add_argument("--expect", type=_expectation, action="append", default=[])
    arguments = parser.parse_args(argv)
    try:
        whole_xlsx = read_xlsx(arguments.xlsx, arguments.sheet)
        whole_ledger = read_ledger(arguments.ledger)
    except InputError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    xlsx, ledger = whole_xlsx, whole_ledger
    for kind in KINDS:
        on_xlsx = ONE_SIDED.get(kind) != "ledger"
        on_ledger = ONE_SIDED.get(kind) != "xlsx"
        x = str(xlsx.kind_count(kind)) if on_xlsx else "-"
        x_sum = str(xlsx.kind_amount(kind)) if on_xlsx else "-"
        l = str(ledger.kind_count(kind)) if on_ledger else "-"
        l_sum = str(ledger.kind_amount(kind)) if on_ledger else "-"
        print(f"kind={kind} xlsx_count={x} ledger_count={l} xlsx_sum={x_sum} ledger_sum={l_sum}")
    # Months are compared up to --through; --expect checks whole-file totals.
    problems = reconcile(
        _through(whole_xlsx, arguments.through), _through(whole_ledger, arguments.through)
    )
    problems += expectations(whole_xlsx, whole_ledger, dict(arguments.expect))
    for line in problems:
        print(line)
    print("status=" + ("mismatch" if problems else "reconciled"))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
