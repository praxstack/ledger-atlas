from __future__ import annotations

import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_widget_extension_has_a_discoverable_widgetkit_extension_point() -> None:
    info = plistlib.loads((ROOT / "Sources/LedgerAtlasWidget/Info.plist").read_bytes())
    assert info["NSExtension"]["NSExtensionPointIdentifier"] == "com.apple.widgetkit-extension"
    project = (ROOT / "project.yml").read_text(encoding="utf-8")
    assert "path: Sources/LedgerAtlasWidget/Info.plist" in project
    assert "INFOPLIST_KEY_NSExtension_NSExtensionPointIdentifier" not in project


def test_local_swift_package_is_relative_and_has_a_stable_group() -> None:
    project = (ROOT / "project.yml").read_text(encoding="utf-8")
    assert "path: LedgerAtlasPackage" in project
    assert (ROOT / "LedgerAtlasPackage").is_symlink()
