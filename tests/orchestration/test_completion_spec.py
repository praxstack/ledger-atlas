from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RENDERER = ROOT / "scripts/render_completion_spec.py"
MARKDOWN = ROOT / "docs/specifications/ledger-atlas-mac-completion-v2.md"
HTML = ROOT / "docs/specifications/ledger-atlas-mac-completion-v2.html"
PRD = ROOT / "prd.json"


def run_check(markdown: Path = MARKDOWN, html: Path = HTML) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(RENDERER),
            "--check",
            "--markdown",
            str(markdown),
            "--html",
            str(html),
        ],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )


def test_completion_spec_render_is_current() -> None:
    result = run_check()
    assert result.returncode == 0, result.stdout + result.stderr


def test_completion_spec_has_exact_story_and_ticket_sets() -> None:
    source = MARKDOWN.read_text(encoding="utf-8")
    assert re.findall(r"^### (US-\d{2}) ", source, re.MULTILINE) == [
        f"US-{number:02d}" for number in range(1, 34)
    ]
    assert re.findall(r"^### (MACV2-\d{2}) ", source, re.MULTILINE) == [
        f"MACV2-{number:02d}" for number in range(1, 24)
    ]


def test_completion_html_is_accessible_and_self_contained() -> None:
    rendered = HTML.read_text(encoding="utf-8")
    assert '<header role="banner">' in rendered
    assert '<nav aria-label="Specification sections">' in rendered
    assert '<main id="main" tabindex="-1">' in rendered
    assert '<a class="skip" href="#main">' in rendered
    assert "JetBrainsMono Nerd Font" in rendered
    assert "@media print" in rendered
    assert '<meta name="source-sha256"' in rendered
    assert '<meta name="generated-at"' in rendered
    assert "<link " not in rendered
    assert "<script" not in rendered
    assert "url(" not in rendered


def test_prd_release_graph_matches_published_tickets() -> None:
    tickets = json.loads(PRD.read_text(encoding="utf-8"))["release_one"]["tickets"]
    identifiers = [ticket["id"] for ticket in tickets]
    assert identifiers == [f"MACV2-{number:02d}" for number in range(1, 24)]
    assert [ticket["github"] for ticket in tickets] == list(range(37, 60))
    assert all(ticket["linear"].startswith("PRA-") for ticket in tickets)

    seen: set[str] = set()
    for ticket in tickets:
        assert set(ticket["deps"]) <= seen
        seen.add(ticket["id"])


def test_parity_check_rejects_required_content_and_hash_drift(tmp_path: Path) -> None:
    source = MARKDOWN.read_text(encoding="utf-8")
    rendered = HTML.read_text(encoding="utf-8")
    mutations = (
        source.replace("## Product contract", "## Product terms", 1),
        source.replace("### MACV2-01 ", "### MACV2-00 ", 1),
        source.replace("Acceptance:", "Criteria:", 1),
        re.sub(r"https://github\.com/praxstack/ledger-atlas/issues/\d+", "", source, count=1),
    )

    for index, mutated in enumerate(mutations):
        markdown = tmp_path / f"mutated-{index}.md"
        markdown.write_text(mutated, encoding="utf-8")
        result = run_check(markdown, HTML)
        assert result.returncode != 0

    html = tmp_path / "bad-hash.html"
    html.write_text(
        rendered.replace('data-source-sha256="', 'data-source-sha256="0', 1), encoding="utf-8"
    )
    result = run_check(MARKDOWN, html)
    assert result.returncode != 0
