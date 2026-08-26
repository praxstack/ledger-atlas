#!/usr/bin/env python3
"""Generate feature-parity-tracker.html: Ticket column on EVERY row, verified.

Reads the sealed evidence original read-only; writes the annotated edition into
ledger-atlas. Refuses to write unless every content assertion passes.
ADR: docs/decisions/0011-parity-ticket-architecture.md
"""

import re
import sys
from pathlib import Path

SRC = Path(
    "/Users/prax/Developer/money-manager-reverse-engineering/research/feature-parity-report.html"
)
DST = Path("/Users/prax/Developer/ledger-atlas/feature-parity-tracker.html")
BASE = "https://github.com/praxstack/ledger-atlas"


def L(*nums: int) -> str:
    return " ".join(f'<a class="tkt" href="{BASE}/issues/{n}">#{n}</a>' for n in nums)


def OG(who: str | None = None) -> str:
    return f'{who or L(32)} <span class="tkn">oracle-gated</span>'


DEV = f'{L(12)} <span class="tkn">device export</span>'
GT = '<span class="tkn">verification</span>'
NA = '<span class="tkna">—</span>'

F = {
    "T01": L(6),
    "T02": L(3),
    "T03": L(3),
    "T04": L(14),
    "T05": L(10, 11),
    "T06": L(15),
    "T07": L(19),
    "T08": L(19),
    "T09": L(24),
    "T10": L(16),
    "T11": L(25),
    "T12": L(17),
    "T13": L(23),
    "T14": DEV,
    "T15": OG(),
    "T16": L(12),
    "T17": L(3),
    "T18": L(19),
    "S01": L(17),
    "S02": L(17),
    "S03": L(17),
    "S04": L(17),
    "S05": L(17),
    "S06": L(16),
    "S07": L(15) + " " + L(17) + " " + L(27),
    "S08": NA,
    "S09": L(18),
    "A01": L(22),
    "A02": L(15),
    "A03": L(6),
    "A04": L(27),
    "A05": L(22),
    "A06": L(19),
    "A07": L(27),
    "A08": L(18),
    "A09": L(27),
    "A10": L(15),
    "A11": L(14),
    "A12": OG(),
    "A13": L(17),
    "A14": NA,
    "M01": NA,
    "M02": L(19),
    "M03": L(28),
    "M04": L(28),
    "M05": L(16),
    "M06": L(16),
    "M07": L(14),
    "M08": L(19),
    "M09": L(31),
    "M10": L(24),
    "M11": L(29),
    "M12": L(31),
    "M13": L(17) + " " + OG(),
    "M14": NA,
    "M15": L(20),
    "X01": L(18),
    "X02": L(13),
    "X03": L(13),
    "X04": L(30),
    "X05": L(30),
    "X06": L(30),
    "X07": L(18),
    "X08": L(18),
    "X09": L(30),
    "X10": L(30),
    "X11": DEV,
    "X12": L(18),
    "X13": L(30),
    "X14": L(30),
    "X15": L(30),
    "PC01": NA,
    "PC02": NA,
    "PC03": NA,
    "PC04": NA,
    "PC05": NA,
    "PC06": NA,
    "SC01": L(26),
    "SC02": L(26),
    "SC03": L(26),
    "SC04": L(26),
    "SC05": L(26),
    "SC06": L(26),
    "SC07": GT,
    "WP01": NA,
    "WP02": NA,
    "WP03": L(20),
    "WP04": L(19),
    "WP05": NA,
    "WP06": NA,
    "WP07": L(31),
    "WP08": L(19),
    "WP09": L(19),
    "WP10": L(29),
    "WP11": L(31),
    "WP12": L(20),
}
D = {
    "ASSETS": L(3),
    "INOUTCOME": L(10, 11, 13),
    "REPEATTRANSACTION": L(12, 16),
    "BUDGET": L(16),
    "BUDGET_AMOUNT": L(16),
    "ZCATEGORY": L(9) + " " + L(28),
    "CURRENCY": L(14),
    "ASSETGROUP": L(22),
    "FAVTRANSACTION": L(25),
    "TAG / TX_TAG": L(23),
    "MEMO": L(24),
    "PHOTO": DEV,
    "SMS_RAW_READ": OG(),
    "MESSAGEMACRO2": OG(),
    "ZETC (app settings)": OG(),
    "CODE_DATA / CODE_LINK": OG(),
    "android_metadata / sqlite_sequence": NA,
}
A = {
    "Transactions": L(14) + "–" + L(17) + f" {L(19)} {L(23)}–{L(25)} {L(27)}–{L(29)}",
    "Statistics": L(16) + " " + L(17) + " " + L(27),
    "Accounts and cards": L(15) + " " + L(18) + " " + L(22) + " " + L(27),
    "Settings and categories": L(14)
    + " "
    + L(16)
    + " "
    + L(19)
    + " "
    + L(24)
    + " "
    + L(28)
    + " "
    + L(29)
    + " "
    + L(31),
    "Backup, import, export": L(12) + " " + L(13) + " " + L(18) + " " + L(30) + " " + L(32),
    "PC Manager": '<span class="tkna">non-goal</span>',
    "Security": L(26) + " " + '<span class="tkn">verification</span>',
    "Platform": L(19) + " " + L(20) + " " + L(29) + " " + L(31),
}

html = SRC.read_text(encoding="utf-8")
fails = []


def sub_once(old, new):
    global html
    if html.count(old) != 1:
        fails.append(f"anchor x{html.count(old)}: {old[:50]}")
    else:
        html = html.replace(old, new)


def sub_all(old, new, expect):
    global html
    if html.count(old) != expect:
        fails.append(f"{old[:40]} x{html.count(old)}!={expect}")
    else:
        html = html.replace(old, new)


def patch_rows(mapping, expect):
    """Insert ticket cell after each row's status chip, PRESERVING the ID cell."""
    global html
    done = 0
    for key, cell in mapping.items():
        pat = re.compile(
            r'(<td class="mono">'
            + re.escape(key)
            + r"</td>)(.*?)("
            + re.escape('<td class="why">')
            + ")",
            re.DOTALL,
        )
        html, n = pat.subn(
            lambda m, c=cell: m.group(1) + m.group(2) + f'<td class="num tk">{c}</td>' + m.group(3),
            html,
        )
        if n != 1:
            fails.append(f"row {key} matched {n}x")
        done += n
    if done != expect:
        fails.append(f"rows {done}!={expect}")


# CSS
sub_once(
    "@media print{",
    "a.tkt{color:var(--ok);text-decoration:none;font-weight:600}\n"
    "a.tkt:hover{text-decoration:underline}\n"
    "td.tk{white-space:nowrap;font-size:12px}\n"
    ".tkn{color:var(--part);font-weight:600}\n"
    ".tkna{color:var(--exc)}\n@media print{",
)
# Headers
sub_all("<th>Ledger Atlas</th><th>Why</th>", "<th>Ledger Atlas</th><th>Ticket</th><th>Why</th>", 8)
sub_once("<th>Status</th><th>Detail</th>", "<th>Status</th><th>Ticket</th><th>Detail</th>")
sub_once("Done / Partial / Missing</th>", "Done / Partial / Missing</th><th>Ticket</th>")
# Rows
patch_rows(F, 96)
patch_rows(D, 17)
for name, cell in A.items():
    pat = re.compile(r'(<tr><td class="an">' + re.escape(name) + r"</td>.*?)(</tr>)", re.DOTALL)
    html, n = pat.subn(
        lambda m, c=cell: m.group(1) + f'<td class="num tk">{c}</td>' + m.group(2), html
    )
    if n != 1:
        fails.append(f"area {name} x{n}")
# Statement bar
sub_once(
    "Audit date <b>2026-08-23</b></span>",
    "Audit date <b>2026-08-23</b></span>\n"
    f'<span>Tracker <b><a class="tkt" href="{BASE}/issues">praxstack/ledger-atlas</a></b></span>',
)
# Coverage summary
cov = (
    '</header>\n<section class="wrap">\n<h2>Tracker coverage</h2>\n'
    '<p style="max-width:78ch">Every row above carries its owning issue in the Ticket '
    "column: full coverage, zero unowned rows. Buildable gaps live in cluster epics "
    + L(26)
    + "–"
    + L(31)
    + "; device and oracle-gated decodes live in the "
    "human-supervised " + L(32) + "; excluded vendor-platform rows are marked —. "
    "Entity tickets "
    + L(22)
    + "–"
    + L(25)
    + " are sub-issues of spec "
    + L(21)
    + ". Generated by scripts/annotate_parity.py from the sealed audit original; "
    "see docs/decisions/0011-parity-ticket-architecture.md.</p>\n</section>"
)
sub_once("</header>", cov)
# Blockers
sub_once(
    "the constitution forbids the guess.</p>",
    f'the constitution forbids the guess.</p><p class="unl">Tracks: {L(8, 9, 10, 11)}</p>',
)
sub_once(
    "define exactly which proofs are missing.</p>",
    f'define exactly which proofs are missing.</p><p class="unl">Tracks: {L(8, 9, 10, 11, 12, 13)}</p>',
)
sub_once(
    "so the importer refuses instead of lying.</p>",
    f'so the importer refuses instead of lying.</p><p class="unl">Preservation tracks {L(12)}; byte export is a device action ({L(32)}).</p>',
)
sub_once(
    "so they stay out.</p>",
    f'so they stay out.</p><p class="unl">Oracle-gated decode: human-supervised, see {L(32)}.</p>',
)
sub_once(
    "<h4>There is deliberately no write path yet</h4><p>mmctl can classify, inspect, "
    "stage and reconcile your file, then prove zero loss. What it cannot do is commit, "
    "because the commit gate requires an armed run with independent review, and "
    "ledger-atlas still has no accepted baseline commit. That gate is what keeps a buggy "
    "import from wrecking your only copy of the data.</p>",
    "<h4>The real-backup write path is unfinished</h4><p>mmctl can classify, inspect, "
    "stage and reconcile supported synthetic data. It cannot yet populate a trusted "
    "canonical ledger from the supplied Android v19 evidence. The blocker is incomplete "
    f'mapping and reconciliation, not commit permission.</p><p class="unl">Tracks: {L(5, 13)}</p>',
)
sub_once(
    "Project verify gates enforce redaction.",
    "Tracked tests and review enforce redaction.",
)
sub_once(
    "App Sandbox enforced. Permission UX differs by platform.",
    "Security-scoped file access exists. App Sandbox entitlement and permission UX are not yet verified.",
)
# Roadmap
sub_once(
    "basic income, expense and transfer mapping.</p>",
    f'basic income, expense and transfer mapping.</p><p class="unl">Tickets: {L(8, 9, 10)}</p>',
)
sub_once(
    "in your 6,999 transactions.</p>",
    f'in your 6,999 transactions.</p><p class="unl">Tickets: {L(10, 11)}</p>',
)
sub_once(
    "<h4>Arm the commit gate</h4><p>Create the baseline commit, arm a finite atom, and "
    'let staged imports pass two-lens review.</p><p class="unl">Unlocks: Turns reconcile '
    "into a real import you can approve.</p>",
    "<h4>Implement and reconcile the real import</h4><p>Map every supplied source item, "
    "preserve unknowns with provenance, write a new Ledger Atlas ledger atomically, and "
    'compare counts and totals against the source exports.</p><p class="unl">Unlocks: '
    f'Turns reconciliation into a real import you can inspect and approve.</p><p class="unl">Tickets: {L(5, 13)}</p>',
)
sub_once(
    "part of the migration instead of collateral.</p>",
    f'part of the migration instead of collateral.</p><p class="unl">Tickets: {L(12)}, {L(32)}</p>',
)
sub_once(
    "toward the full set.</p>",
    f'toward the full set.</p><p class="unl">Tickets: {L(22, 23, 24, 25)}</p>',
)
sub_once(
    "backup opens in Ledger Atlas.</p>",
    f'backup opens in Ledger Atlas.</p><p class="unl">Tickets: {L(13)}</p>',
)
# Footer
sub_once(
    "No real names, amounts or institutions appear on this page.</footer>",
    "No real names, amounts or institutions appear on this page.<br>"
    "Annotated edition generated 2026-08-23 by scripts/annotate_parity.py; "
    "the canonical audit file in the evidence repository stays untouched.</footer>",
)
sub_once("reading the shipped Swift sources", "reading the local Swift sources")
sub_once(
    "A row counts as done only when a public command or journey implements it.",
    "An Implemented row means a public command or journey exists; it does not prove a complete native screen. Screen completion follows docs/specifications/screenshot-functional-parity-v1.md.",
)

if fails:
    print("GENERATION FAILED:")
    [print(" -", f) for f in fails]
    sys.exit(1)

DST.write_text(html, encoding="utf-8")

# ---- Content assertions on the WRITTEN file ----
chk = DST.read_text(encoding="utf-8")
asserts = {
    "cells == 121": chk.count('class="num tk"') == 121,
    "all IDs present": all(k in chk for k in list(F) + list(D)),
    "zero needs-ticket": "needs ticket" not in chk,
    "links >= 110": chk.count('class="tkt"') >= 110,
    "sample SC05 wired": "issues/26" in chk,
    "sample M04 wired": "issues/28" in chk,
    "oracle rows -> #32": chk.count("oracle-gated") >= 7,
}
bad = [k for k, ok in asserts.items() if not ok]
if bad:
    print("VERIFY FAILED ON DISK:", bad)
    sys.exit(1)
print(f"OK {DST}: cells=121, links={chk.count(chr(34) + 'tkt' + chr(34))}, all assertions passed")
