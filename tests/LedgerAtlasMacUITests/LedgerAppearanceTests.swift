import AppKit
import Testing

@testable import LedgerAtlasMacUI

// Synthetic data only: the window shows the made-up demo ledger.

/// The Appearance setting changes the look of the real app window: Dark darkens it, Light
/// lightens it, and System hands the look back to macOS. Before, the setting changed nothing
/// once a window was shown.
@MainActor
@Test func appearanceSettingChangesTheWholeApp() async throws {
  let app = NSApplication.shared
  let before = app.appearance
  defer { app.appearance = before }

  let mounted = try await MountedRoot(showing: .overview, appearance: .dark)
  defer { mounted.close() }
  func look(_ window: NSWindow) -> NSAppearance.Name? {
    window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
  }
  #expect(app.appearance?.name == .darkAqua, "choosing Dark in Settings didn't reach the app")
  #expect(look(mounted.window) == .darkAqua, "the window didn't turn dark")

  LedgerAppearance.apply(.light)
  #expect(app.appearance?.name == .aqua)
  #expect(look(mounted.window) == .aqua, "the window didn't turn light")

  LedgerAppearance.apply(.system)
  #expect(app.appearance == nil, "System should hand the look back to macOS")
}

/// Applying the same choice twice leaves the app's appearance object alone, and the
/// mapping is one to one.
@MainActor
@Test func appearanceIsAppliedOnlyWhenItChanges() {
  let app = NSApplication.shared
  let before = app.appearance
  defer { app.appearance = before }
  LedgerAppearance.apply(.dark)
  let first = app.appearance
  LedgerAppearance.apply(.dark)
  #expect(app.appearance === first)
  LedgerAppearance.apply(.system)
  #expect(app.appearance == nil)
}

/// With Increase Contrast on, Light and Dark keep the system's high-contrast look instead of
/// forcing the plain one. The runner may hand back the plain appearance for a high-contrast
/// name (`NSAppearance(named:)` does that when the setting is off), so the applied name is
/// checked loosely and the mapping strictly.
@MainActor
@Test func forcedAppearanceKeepsIncreaseContrast() {
  #expect(LedgerAppearance.appearanceName(for: .system, increaseContrast: true) == nil)
  #expect(LedgerAppearance.appearanceName(for: .light, increaseContrast: false) == .aqua)
  #expect(
    LedgerAppearance.appearanceName(for: .light, increaseContrast: true) == .accessibilityHighContrastAqua)
  #expect(LedgerAppearance.appearanceName(for: .dark, increaseContrast: false) == .darkAqua)
  #expect(
    LedgerAppearance.appearanceName(for: .dark, increaseContrast: true)
      == .accessibilityHighContrastDarkAqua)

  let app = NSApplication.shared
  let before = app.appearance
  defer { app.appearance = before }
  LedgerAppearance.apply(.dark, to: app, increaseContrast: true)
  let applied = app.appearance?.name
  #expect(
    applied == .accessibilityHighContrastDarkAqua || applied == .darkAqua,
    "applied \(applied?.rawValue ?? "nothing")")
  LedgerAppearance.apply(.light, to: app, increaseContrast: true)
  let light = app.appearance?.name
  #expect(light == .accessibilityHighContrastAqua || light == .aqua, "applied \(light?.rawValue ?? "nothing")")
}
