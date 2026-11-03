"""The XLSX reconciliation script on a synthetic export and a synthetic ledger."""

from __future__ import annotations

import importlib.util
import sqlite3
import zipfile
from datetime import date
from pathlib import Path
from xml.sax.saxutils import escape

import pytest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "mm_v19_xlsx_reconcile", ROOT / "scripts" / "mm_v19_xlsx_reconcile.py"
)
assert SPEC and SPEC.loader
reconciler = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(reconciler)

NOTE = "Synthetic private note"
HEADER = [
    "Date",
    "Account",
    "Category",
    "Subcategory",
    "Note",
    "INR",
    "Income/Expense",
    "Tag",
    "Description",
    "Amount",
    "Currency",
    "Account",
]
# (day, kind, category, amount): two months, every kind, a "Modified Bal." income.
ROWS = [
    (date(2025, 1, 3), "Income", "Salary", "100.00"),
    (date(2025, 1, 4), "Expense", "Food", "12.50"),
    (date(2025, 1, 5), "Income", "Modified Bal.", "3.00"),
    (date(2025, 1, 6), "Transfer-Out", "Bank", "40.00"),
    (date(2025, 2, 1), "Expense", "Food", "7.25"),
]


def _serial(day: date) -> str:
    # Spreadsheet day number plus a time of day, as Money Manager writes it.
    return f"{(day - date(1899, 12, 30)).days}.5416666667"


def _column(index: int) -> str:
    return chr(ord("A") + index)


def write_xlsx(path: Path, rows=ROWS, header=HEADER, sheet="Money Manager") -> Path:
    strings: list[str] = []

    def shared(text: str) -> str:
        if text not in strings:
            strings.append(text)
        return str(strings.index(text))

    def row_xml(number: int, values: list[tuple[str, str]]) -> str:
        cells = []
        for index, (kind, value) in enumerate(values):
            ref = f"{_column(index)}{number}"
            if kind == "s":
                cells.append(f'<c r="{ref}" t="s"><v>{shared(value)}</v></c>')
            else:
                cells.append(f'<c r="{ref}"><v>{value}</v></c>')
        return f'<row r="{number}">{"".join(cells)}</row>'

    body = [row_xml(1, [("s", name) for name in header])]
    for number, (day, kind, category, amount) in enumerate(rows, start=2):
        body.append(
            row_xml(
                number,
                [
                    ("n", _serial(day)),
                    ("s", "Wallet"),
                    ("s", category),
                    ("s", ""),
                    ("s", NOTE),
                    ("n", amount),
                    ("s", kind),
                    ("s", ""),
                    ("s", NOTE),
                    ("s", amount),
                    ("s", "INR"),
                    ("n", amount),
                ],
            )
        )
    main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr(
            "xl/workbook.xml",
            f'<workbook xmlns="{main}" xmlns:r="{rel}"><workbookPr date1904="false"/>'
            f'<sheets><sheet name="{escape(sheet)}" r:id="rId3" sheetId="1"/></sheets></workbook>',
        )
        archive.writestr(
            "xl/_rels/workbook.xml.rels",
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId3" Target="worksheets/sheet1.xml" '
            'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"/>'
            "</Relationships>",
        )
        archive.writestr(
            "xl/worksheets/sheet1.xml",
            f'<worksheet xmlns="{main}"><sheetData>{"".join(body)}</sheetData></worksheet>',
        )
        archive.writestr(
            "xl/sharedStrings.xml",
            f'<sst xmlns="{main}">'
            + "".join(f"<si><t>{escape(text)}</t></si>" for text in strings)
            + "</sst>",
        )
    return path


def write_ledger(path: Path, extra: list[tuple] = ()) -> Path:
    """The canonical tables the script reads, holding the same events as ROWS."""
    database = sqlite3.connect(path)
    database.executescript(
        """
        CREATE TABLE economic_event(
          event_id TEXT PRIMARY KEY, event_kind TEXT NOT NULL, amount_literal TEXT NOT NULL,
          local_year INTEGER NOT NULL, local_month INTEGER NOT NULL,
          currency_unit TEXT NOT NULL DEFAULT 'INR');
        CREATE TABLE economic_event_transfer(
          debit_event_id TEXT NOT NULL, credit_event_id TEXT NOT NULL);
        """
    )
    events = [
        ("e1", "income", "100.00", 2025, 1),
        ("e2", "expense", "12.50", 2025, 1),
        ("e3", "income", "3.00", 2025, 1),
        ("t1d", "transfer_debit", "40.00", 2025, 1),
        ("t1c", "transfer_credit", "40.00", 2025, 1),
        ("e4", "expense", "7.25", 2025, 2),
        ("a1", "adjustment", "4.00", 2024, 12),
        *extra,
    ]
    database.executemany(
        "INSERT INTO economic_event"
        " (event_id, event_kind, amount_literal, local_year, local_month, currency_unit)"
        " VALUES (?, ?, ?, ?, ?, ?)",
        [event if len(event) == 6 else (*event, "INR") for event in events],
    )
    database.execute("INSERT INTO economic_event_transfer VALUES ('t1d', 't1c')")
    database.commit()
    database.close()
    return path


def run(capsys, *argv) -> tuple[int, str]:
    code = reconciler.main([str(arg) for arg in argv])
    captured = capsys.readouterr()
    return code, captured.out + captured.err


def test_matching_export_reconciles(tmp_path, capsys):
    code, output = run(
        capsys,
        write_xlsx(tmp_path / "export.xlsx"),
        write_ledger(tmp_path / "ledger.sqlite"),
        "--expect",
        "income=2",
        "--expect",
        "expense=2",
        "--expect",
        "transfer=1",
        "--expect",
        "balance=1",
    )
    assert code == 0, output
    assert "status=reconciled" in output
    assert "kind=income xlsx_count=2 ledger_count=2 xlsx_sum=103.00 ledger_sum=103.00" in output
    assert "kind=transfer xlsx_count=1 ledger_count=1" in output
    assert "kind=balance xlsx_count=- ledger_count=1" in output


def test_extra_ledger_event_names_its_kind_and_month(tmp_path, capsys):
    code, output = run(
        capsys,
        write_xlsx(tmp_path / "export.xlsx"),
        write_ledger(tmp_path / "ledger.sqlite", [("e9", "expense", "1.00", 2025, 2)]),
    )
    assert code == 1
    assert (
        "MISMATCH kind=expense month=2025-02 currency=INR xlsx_count=1 ledger_count=2 "
        "xlsx_sum=7.25 ledger_sum=8.25"
    ) in output
    assert "month=2025-01" not in output


def test_amount_difference_alone_is_a_mismatch(tmp_path, capsys):
    rows = [*ROWS[:4], (date(2025, 2, 1), "Expense", "Food", "7.24")]
    code, output = run(
        capsys,
        write_xlsx(tmp_path / "export.xlsx", rows=rows),
        write_ledger(tmp_path / "ledger.sqlite"),
    )
    assert code == 1
    assert "MISMATCH kind=expense month=2025-02 currency=INR xlsx_count=1 ledger_count=1" in output


def test_through_ignores_later_months_on_both_sides(tmp_path, capsys):
    rows = [*ROWS, (date(2025, 3, 2), "Expense", "Food", "9.00")]
    export = write_xlsx(tmp_path / "export.xlsx", rows=rows)
    ledger = write_ledger(tmp_path / "ledger.sqlite")
    assert run(capsys, export, ledger)[0] == 1
    code, output = run(capsys, export, ledger, "--through", "2025-02")
    assert code == 0, output
    # --expect totals are whole-ledger totals, whatever --through cuts.
    code, output = run(capsys, export, ledger, "--through", "2024-12", "--expect", "expense=2")
    assert code == 0, output


def test_expected_total_mismatch_fails(tmp_path, capsys):
    code, output = run(
        capsys,
        write_xlsx(tmp_path / "export.xlsx"),
        write_ledger(tmp_path / "ledger.sqlite"),
        "--expect",
        "balance=8",
    )
    assert code == 1
    assert "MISMATCH kind=balance month=all expected_count=8 ledger_count=1" in output


def test_transfer_in_rows_are_not_counted_twice(tmp_path, capsys):
    rows = [*ROWS, (date(2025, 1, 6), "Transfer-In", "Wallet", "40.00")]
    code, output = run(
        capsys,
        write_xlsx(tmp_path / "export.xlsx", rows=rows),
        write_ledger(tmp_path / "ledger.sqlite"),
    )
    assert code == 0, output


@pytest.mark.parametrize(
    "export",
    [
        lambda path: write_xlsx(path, sheet="Other"),
        lambda path: write_xlsx(path, header=[h if h != "Amount" else "Sum" for h in HEADER]),
        lambda path: write_xlsx(path, rows=[(date(2025, 1, 3), "Refund", "Salary", "1.00")]),
        lambda path: path.write_bytes(b"not a workbook") or path,
    ],
    ids=["missing-sheet", "missing-column", "unknown-kind", "not-xlsx"],
)
def test_unreadable_export_exits_2(tmp_path, capsys, export):
    code, output = run(
        capsys, export(tmp_path / "export.xlsx"), write_ledger(tmp_path / "ledger.sqlite")
    )
    assert code == 2
    assert output.startswith("error: ")


def test_not_a_ledger_exits_2(tmp_path, capsys):
    ledger = tmp_path / "ledger.sqlite"
    sqlite3.connect(ledger).execute("CREATE TABLE other(x)").connection.close()
    code, _ = run(capsys, write_xlsx(tmp_path / "export.xlsx"), ledger)
    assert code == 2


def test_output_never_quotes_row_content(tmp_path, capsys):
    _, output = run(
        capsys,
        write_xlsx(tmp_path / "export.xlsx"),
        write_ledger(tmp_path / "ledger.sqlite", [("e9", "expense", "1.00", 2025, 2)]),
    )
    for secret in (NOTE, "Wallet", "Salary", "Food", "Modified Bal."):
        assert secret not in output


def test_same_account_transfer_is_counted_not_compared(tmp_path, capsys):
    # The Category of a Transfer-Out row is the receiving account. Wallet to Wallet is the
    # same-account pair the importer preserves instead of mapping.
    rows = [*ROWS, (date(2025, 2, 2), "Transfer-Out", "Wallet", "6.00")]
    code, output = run(
        capsys,
        write_xlsx(tmp_path / "export-1.xlsx", rows=rows),
        write_ledger(tmp_path / "ledger-1.sqlite"),
        "--expect",
        "same_account_transfer=1",
    )
    assert code == 0, output
    assert "kind=same_account_transfer xlsx_count=1 ledger_count=- xlsx_sum=6.00" in output
    code, output = run(
        capsys,
        write_xlsx(tmp_path / "export-2.xlsx", rows=rows),
        write_ledger(tmp_path / "ledger-2.sqlite"),
        "--expect",
        "same_account_transfer=0",
    )
    assert code == 1
    assert "MISMATCH kind=same_account_transfer month=all expected_count=0 xlsx_count=1" in output


def test_currencies_cannot_cancel_out(tmp_path, capsys):
    # One expense moved from INR to USD: same count and sum per month, wrong currency.
    ledger = write_ledger(tmp_path / "ledger.sqlite")
    database = sqlite3.connect(ledger)
    database.execute("UPDATE economic_event SET currency_unit='USD' WHERE event_id='e4'")
    database.commit()
    database.close()
    code, output = run(capsys, write_xlsx(tmp_path / "export.xlsx"), ledger)
    assert code == 1
    assert "MISMATCH kind=expense month=2025-02 currency=INR xlsx_count=1 ledger_count=0" in output
    assert "MISMATCH kind=expense month=2025-02 currency=USD xlsx_count=0 ledger_count=1" in output


def test_skipped_transfer_in_rows_are_reported(tmp_path, capsys):
    rows = [*ROWS, (date(2025, 1, 6), "Transfer-In", "Wallet", "40.00")]
    _, output = run(
        capsys,
        write_xlsx(tmp_path / "export.xlsx", rows=rows),
        write_ledger(tmp_path / "ledger.sqlite"),
    )
    assert "skipped_transfer_in_rows=1" in output
