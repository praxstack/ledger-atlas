import AppKit

/// Applies the Appearance setting (System, Light, Dark) to the whole app.
///
/// The choice is set on `NSApplication`, so every window, sheet, panel, alert and menu follows
/// it, and choosing System hands the look back to macOS. SwiftUI's `preferredColorScheme` was
/// used before: it reaches only the window it is set in, and on macOS a window that was once
/// forced light or dark never returns to the system look, which is why the setting appeared not
/// to apply.
///
/// A forced appearance would also drop the system's Increase Contrast look, so Light and Dark
/// pick the high-contrast appearance while that setting is on (the root view applies the
/// choice again when the accessibility display options change).
enum LedgerAppearance {
  @MainActor
  static func apply(
    _ appearance: LedgerProductSettings.Appearance, to app: NSApplication = .shared,
    increaseContrast: Bool = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
  ) {
    let name = appearanceName(for: appearance, increaseContrast: increaseContrast)
    guard app.appearance?.name != name else { return }
    app.appearance = name.flatMap { NSAppearance(named: $0) }
  }

  /// The appearance to force for a choice. `nil` follows the Mac.
  static func appearanceName(
    for appearance: LedgerProductSettings.Appearance, increaseContrast: Bool
  ) -> NSAppearance.Name? {
    switch (appearance, increaseContrast) {
    case (.system, _): nil
    case (.light, false): .aqua
    case (.light, true): .accessibilityHighContrastAqua
    case (.dark, false): .darkAqua
    case (.dark, true): .accessibilityHighContrastDarkAqua
    }
  }
}
