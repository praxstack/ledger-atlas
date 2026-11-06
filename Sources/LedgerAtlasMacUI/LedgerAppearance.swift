import AppKit

/// Applies the Appearance setting (System, Light, Dark) to the whole app.
///
/// The choice is set on `NSApplication`, so every window, sheet, panel, alert and menu follows
/// it, and choosing System hands the look back to macOS. SwiftUI's `preferredColorScheme` was
/// used before: it reaches only the window it is set in, and on macOS a window that was once
/// forced light or dark never returns to the system look, which is why the setting appeared not
/// to apply.
enum LedgerAppearance {
  @MainActor
  static func apply(
    _ appearance: LedgerProductSettings.Appearance, to app: NSApplication = .shared
  ) {
    let name = appearance.appearanceName
    guard app.appearance?.name != name else { return }
    app.appearance = name.flatMap { NSAppearance(named: $0) }
  }
}
