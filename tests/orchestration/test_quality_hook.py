from __future__ import annotations

import importlib.util
from pathlib import Path

HOOK = Path(__file__).resolve().parents[2] / ".codex/hooks/quality.py"
SPEC = importlib.util.spec_from_file_location("quality_hook", HOOK)
assert SPEC and SPEC.loader
QUALITY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(QUALITY)


def test_quality_hook_protects_evidence_but_allows_normal_commits(monkeypatch) -> None:
    evidence = "/private/evidence"
    monkeypatch.setenv("LEDGER_ATLAS_EVIDENCE_ROOT", evidence)

    assert QUALITY.policy_reason("git commit -m product") is None
    assert (
        QUALITY.policy_reason(f"sqlite3 'file:{evidence}/money.sqlite?mode=ro&immutable=1' .schema")
        is None
    )
    assert QUALITY.policy_reason(f"rm {evidence}/money.sqlite") is not None
    assert QUALITY.policy_reason("rm '/Users/prax/Downloads/money_android.sqlite'") is not None
    assert QUALITY.policy_reason("git reset --hard HEAD~1") is not None
