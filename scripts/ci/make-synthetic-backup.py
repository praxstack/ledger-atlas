#!/usr/bin/env python3
"""Write a made-up Money Manager v19 backup about the size of a real one.

Uses the frozen v19 DDL (docs/compatibility/money-manager-android-v19.schema.sql), so the file
has the real 19-table shape. Every name, note and amount is synthetic and generated from a fixed
seed. CI uses it to run the shipped app's import on a realistic amount of data
(scripts/ci/demo-tour.sh). The app reads the file directly from its container, so this does not
exercise the file panel or security-scoped access.

The last line printed is the number of transactions the import should show: every row, with each
transfer pair counted once.

usage: make-synthetic-backup.py OUT [TRANSACTIONS]
"""

import datetime
import random
import sqlite3
import sys
from pathlib import Path

DDL = (
    Path(__file__).resolve().parents[2] / "docs/compatibility/money-manager-android-v19.schema.sql"
)
DAY_MS = 86_400_000
START_MS = 1_672_531_200_000  # 2023-01-01T00:00:00Z
IST = datetime.timezone(datetime.timedelta(hours=5, minutes=30))


def main() -> None:
    out = Path(sys.argv[1])
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 7_500
    out.unlink(missing_ok=True)
    rng = random.Random(19)
    db = sqlite3.connect(out)
    db.executescript(DDL.read_text())
    db.execute("INSERT INTO android_metadata (locale) VALUES ('en_US')")
    db.execute(
        "INSERT INTO CURRENCY (uid, NAME, ISO, MAIN_ISO, IS_DEL, RATE, IS_MAIN_CURRENCY, DECIMAL_POINT)"
        " VALUES ('cur-inr', 'Rupee', 'INR', 'INR', 0, 1.0, 1, 2)"
    )
    groups = ["Cash", "Bank", "Cards", "Savings"]
    for index, name in enumerate(groups, 1):
        db.execute(
            "INSERT INTO ASSETGROUP (uid, IS_DEL, ACC_GROUP_NAME, TYPE, ORDERSEQ) VALUES (?, 0, ?, 1, ?)",
            (str(index), name, index),
        )
    accounts = [f"acct-{n}" for n in range(1, 13)]
    for index, uid in enumerate(accounts, 1):
        db.execute(
            "INSERT INTO ASSETS (uid, NIC_NAME, ZDATA, groupUid, currencyUid, ORDERSEQ)"
            " VALUES (?, ?, '0', ?, 'cur-inr', ?)",
            (uid, f"Account {index}", str(index % len(groups) + 1), index),
        )
    income = [f"in-{n}" for n in range(1, 7)]
    expense = [f"ex-{n}" for n in range(1, 25)]
    for index, uid in enumerate(income, 1):
        db.execute(
            "INSERT INTO ZCATEGORY (uid, NAME, TYPE, STATUS, pUid, C_IS_DEL, ORDERSEQ)"
            " VALUES (?, ?, 0, 0, '0', 0, ?)",
            (uid, f"Income {index}", index),
        )
    for index, uid in enumerate(expense, 1):
        parent = "0" if index <= 12 else expense[index - 13]
        db.execute(
            "INSERT INTO ZCATEGORY (uid, NAME, TYPE, STATUS, pUid, C_IS_DEL, ORDERSEQ)"
            " VALUES (?, ?, 1, ?, ?, 0, ?)",
            (uid, f"Expense {index}", 0 if parent == "0" else 2, parent, index),
        )

    rows = []
    pairs = 0
    n = 0
    while len(rows) < count:
        n += 1
        when = START_MS + rng.randrange(0, 1_000) * DAY_MS + rng.randrange(0, DAY_MS)
        # WDATE is the civil day at the phone's offset (India, +05:30), as in a real backup.
        wdate = datetime.datetime.fromtimestamp(when / 1000, IST).strftime("%Y-%m-%d")
        amount = f"{rng.randrange(1, 500_000) / 100:.2f}"
        roll = rng.random()
        if roll < 0.10 and len(rows) + 2 <= count:
            source, target = rng.sample(accounts, 2)
            group = f"grp-{n}"
            pairs += 1
            for uid, do_type, account, other in (
                (f"tx-{n}-out", "3", source, target),
                (f"tx-{n}-in", "4", target, source),
            ):
                rows.append((uid, account, None, other, group, do_type, amount, when, wdate))
            continue
        if roll < 0.25:
            rows.append(
                (
                    f"tx-{n}",
                    rng.choice(accounts),
                    rng.choice(income),
                    None,
                    None,
                    "0",
                    amount,
                    when,
                    wdate,
                )
            )
        else:
            rows.append(
                (
                    f"tx-{n}",
                    rng.choice(accounts),
                    rng.choice(expense),
                    None,
                    None,
                    "1",
                    amount,
                    when,
                    wdate,
                )
            )
    db.executemany(
        "INSERT INTO INOUTCOME (uid, assetUid, ctgUid, toAssetUid, txUidTrans, DO_TYPE, ZMONEY,"
        " IN_ZMONEY, AMOUNT_ACCOUNT, ZDATE, WDATE, ZCONTENT, ZDATA, CARDDIVIDMONTH, currencyUid,"
        " UTIME, IS_DEL) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '', '0', 'cur-inr', ?, 0)",
        [
            (
                uid,
                account,
                category,
                other,
                group,
                do_type,
                amount,
                amount,
                float(amount),
                str(when),
                wdate,
                f"note {i % 97}",
                when,
            )
            for i, (
                uid,
                account,
                category,
                other,
                group,
                do_type,
                amount,
                when,
                wdate,
            ) in enumerate(rows)
        ],
    )
    db.commit()
    db.close()
    print(f"{out}: {len(rows)} rows, {out.stat().st_size} bytes", file=sys.stderr)
    print(len(rows) - pairs)


if __name__ == "__main__":
    main()
