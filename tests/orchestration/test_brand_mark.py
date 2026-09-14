from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP_ICON = ROOT / "Assets/Brand/ledger-atlas-app-icon.svg"
MENU_ICON = ROOT / "Assets/Brand/ledger-atlas-menu-icon.svg"
FORBIDDEN = ("Perfect", "Money Manager", "MoneyManager", "Realbyte", "realbyte")


def _read(path: Path) -> str:
    assert path.is_file(), f"missing shipped icon {path}"
    return path.read_text(encoding="utf-8")


def test_ledger_atlas_icons_identify_the_product_and_use_presentation_paints() -> None:
    for path in (APP_ICON, MENU_ICON):
        svg = _read(path)
        assert "<title" in svg and "Ledger Atlas" in svg
        assert "<desc" in svg and "Ledger Atlas" in svg
        assert 'fill="#' in svg
        assert "var(" not in svg
        assert "currentColor" not in svg
        for banned in FORBIDDEN:
            assert banned not in svg
