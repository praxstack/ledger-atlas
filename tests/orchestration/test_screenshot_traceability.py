from __future__ import annotations

import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "docs/specifications/screenshot-traceability-v1.json"
EXPECTED_ROUTES = {
    "transactions.daily",
    "statistics.overview",
    "statistics.category_detail",
    "statistics.total_balance",
    "accounts.overview",
    "accounts.account_info",
    "settings.configuration",
    "settings.accounts",
    "settings.account_groups",
    "settings.account_list",
    "accounts.add",
    "security.set_passcode",
    "local_web_access.idle",
    "backup.hub",
}
EXPECTED_FILENAMES = {
    f"Screenshot_20260810-{suffix}.png"
    for suffix in (
        "003508",
        "003514",
        "003520",
        "003523",
        "003528",
        "003532",
        "003539",
        "003550",
        "003555",
        "003600",
        "003604",
        "003608",
        "003612",
        "003616",
        "003623",
        "003632",
        "003635",
        "003641",
        "003644",
        "003649",
        "003652",
        "003703",
        "003726",
        "003736",
        "003741",
    )
}


def test_direct_screenshot_checklist_matches_supplied_private_evidence() -> None:
    value = json.loads(MANIFEST.read_text(encoding="utf-8"))
    captures = value["captures"]
    filenames = [capture["filename"] for capture in captures]
    private_root = Path(value["private_root"])
    control_contracts = set(value["control_contract_ids"])

    assert len(captures) == 25
    assert len(set(filenames)) == 25
    assert set(filenames) == EXPECTED_FILENAMES
    assert {capture["route_id"] for capture in captures} == EXPECTED_ROUTES
    assert all(capture["visible_control_ids"] for capture in captures)
    assert all(set(capture["visible_control_ids"]) <= control_contracts for capture in captures)
    # MACV2-21 (#57): each record names its light capture in the ui-captures CI artifact,
    # made by tests/LedgerAtlasMacUITests/LedgerCaptureSetTests.swift (a dark sibling too).
    assert [capture["synthetic_capture_path"] for capture in captures] == [
        f"ui-captures/{number:02d}-{capture['route_id']}-{capture['state_id']}-light.png"
        for number, capture in enumerate(captures, start=1)
    ]
    assert value["evidence_grade"] == "observed"
    assert value["completion_spec"] == ("docs/specifications/ledger-atlas-mac-completion-v2.md")
    assert value["release_one_capture_ticket"] == (
        "https://github.com/praxstack/ledger-atlas/issues/57"
    )
    assert value["source_screenshots_read_only"] is True
    if os.environ.get("LEDGER_ATLAS_VERIFY_PRIVATE_EVIDENCE") == "1":
        assert private_root.is_dir()
        assert set(filenames) == {path.name for path in private_root.glob("*.png")}
