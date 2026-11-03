import AppKit
import SwiftUI

/// The design tokens for the Ledger Atlas look. See DESIGN.md for the rules behind them.
///
/// Every colour is dynamic: it resolves for light, dark and both Increase Contrast
/// appearances, so views never branch on the colour scheme themselves.
public enum LedgerTheme {
  // MARK: Colour

  /// Window content background. Numbers live on this solid surface, never on glass.
  public static let canvas = dynamic(light: 0xFBFBFA, dark: 0x1C1C1E)
  /// Recessed surfaces: inspector, day headers, drop zones.
  public static let recessed = dynamic(light: 0xF4F4F2, dark: 0x232325)
  /// Raised cards on the canvas.
  public static let card = dynamic(light: 0xFFFFFF, dark: 0x232326, highContrastLight: 0xFFFFFF, highContrastDark: 0x26262A)

  public static let ink = dynamic(light: 0x1D1D1F, dark: 0xF5F5F7, highContrastLight: 0x000000, highContrastDark: 0xFFFFFF)
  public static let inkSecondary = dynamic(light: 0x515154, dark: 0xC7C7CC, highContrastLight: 0x2C2C2E, highContrastDark: 0xE5E5EA)
  public static let inkTertiary = dynamic(light: 0x86868B, dark: 0x8E8E93, highContrastLight: 0x515154, highContrastDark: 0xC7C7CC)

  /// Hairline separators. Increase Contrast doubles their strength.
  public static let hairline = dynamic(
    light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.09,
    highContrastLightAlpha: 0.22, highContrastDarkAlpha: 0.26)
  public static let hairlineSoft = dynamic(
    light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.045, darkAlpha: 0.05,
    highContrastLightAlpha: 0.16, highContrastDarkAlpha: 0.2)
  /// Fill for fields, chips and unselected segmented items.
  public static let fieldFill = dynamic(
    light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.045, darkAlpha: 0.07,
    highContrastLightAlpha: 0.09, highContrastDarkAlpha: 0.14)

  /// The single accent: selection, focus and the one primary action per surface.
  public static let accent = dynamic(light: 0x0A7C86, dark: 0x4FC3CE, highContrastLight: 0x005A62, highContrastDark: 0x7FDDE6)
  public static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x062024)
  public static let accentSoft = dynamic(
    light: 0x0A7C86, dark: 0x4FC3CE, lightAlpha: 0.11, darkAlpha: 0.16,
    highContrastLightAlpha: 0.2, highContrastDarkAlpha: 0.26)

  /// Money in. Spending stays in `ink`; colour is never the only signal (signs always show).
  public static let positive = dynamic(light: 0x1F8A55, dark: 0x4CC985, highContrastLight: 0x0E6B3C, highContrastDark: 0x7BE0A8)
  /// Over budget, negative balances, destructive actions and errors.
  public static let negative = dynamic(light: 0xC2412D, dark: 0xFF7A66, highContrastLight: 0x9C2A18, highContrastDark: 0xFF9C8C)
  public static let warning = dynamic(light: 0xB26B00, dark: 0xF0A83C, highContrastLight: 0x8A5200, highContrastDark: 0xFFC266)
  /// Blue alternative for money in, for the "income blue" amount-colour setting.
  public static let positiveBlue = dynamic(light: 0x2F6FD0, dark: 0x6FA8FF)

  /// Category and account colours: muted, equal in perceived lightness, used only as
  /// small dots and thin bars.
  public static let categoryPalette: [Color] = [
    dynamic(light: 0x5B7FB8, dark: 0x7D9FD6),
    dynamic(light: 0xC27A46, dark: 0xDF9764),
    dynamic(light: 0x6E9E72, dark: 0x8CBF90),
    dynamic(light: 0xC2A245, dark: 0xDCBD60),
    dynamic(light: 0xA7709D, dark: 0xC690BB),
    dynamic(light: 0x5E9EA3, dark: 0x7DBDC2),
    dynamic(light: 0xB5666A, dark: 0xD68589),
    dynamic(light: 0x8B8F97, dark: 0xA3A7AE),
  ]

  /// A stable palette colour for any name, so a category keeps its colour everywhere.
  public static func paletteColor(for key: String) -> Color {
    categoryPalette[Int(stableHash(key) % UInt64(categoryPalette.count))]
  }

  static func stableHash(_ key: String) -> UInt64 {
    // FNV-1a: stable across launches, unlike `Hasher`.
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for byte in key.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01B3
    }
    return hash
  }

  // MARK: Spacing, shape

  /// The 4-point spacing scale.
  public enum Space {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 20
    public static let xxl: CGFloat = 24
    public static let xxxl: CGFloat = 32
  }

  public enum Radius {
    /// Chips, fields, small buttons.
    public static let control: CGFloat = 7
    /// Rows and list selection.
    public static let row: CGFloat = 8
    /// Grouped key-value boxes inside cards and the inspector.
    public static let group: CGFloat = 10
    /// Cards on the canvas.
    public static let card: CGFloat = 14
    /// Floating sidebar and sheets (concentric with the window corner).
    public static let panel: CGFloat = 16
  }

  /// Standard row heights.
  public enum Metrics {
    public static let tableRow: CGFloat = 40
    public static let compactRow: CGFloat = 28
    public static let sidebarRow: CGFloat = 27
    public static let iconTile: CGFloat = 28
    public static let inspectorWidth: CGFloat = 320
  }

  // MARK: Type

  /// The type scale. All styles are SF Pro; money adds tabular figures (see `MoneyText`).
  public enum Typeface {
    /// 44 pt display figure: the one hero number on a screen.
    public static let hero = Font.system(size: 44, weight: .semibold, design: .default)
    /// 32 pt figure in the inspector.
    public static let figureLarge = Font.system(size: 32, weight: .semibold)
    /// 20 pt key figures.
    public static let figure = Font.system(size: 20, weight: .semibold)
    /// 30 pt welcome and empty-state titles.
    public static let display = Font.system(size: 30, weight: .bold)
    /// 15 pt screen titles in the toolbar.
    public static let screenTitle = Font.system(size: 15, weight: .bold)
    /// 13 pt semibold card titles.
    public static let cardTitle = Font.system(size: 13, weight: .semibold)
    public static let body = Font.system(size: 13)
    public static let bodyEmphasis = Font.system(size: 13, weight: .medium)
    public static let secondary = Font.system(size: 12)
    public static let caption = Font.system(size: 11.5)
    public static let captionEmphasis = Font.system(size: 11, weight: .semibold)
  }

  /// Tracking for large figures, in points per point of size (SF Pro Display tightening).
  static func figureTracking(forSize size: CGFloat) -> CGFloat {
    size >= 28 ? -size * 0.03 : (size >= 18 ? -size * 0.018 : 0)
  }

  // MARK: Dynamic colour

  static func dynamic(
    light: UInt32, dark: UInt32, highContrastLight: UInt32? = nil, highContrastDark: UInt32? = nil,
    lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1,
    highContrastLightAlpha: CGFloat? = nil, highContrastDarkAlpha: CGFloat? = nil
  ) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let match = appearance.bestMatch(from: [
          .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
        ])
        switch match {
        case .darkAqua?:
          return rgb(dark, alpha: darkAlpha)
        case .accessibilityHighContrastAqua?:
          return rgb(highContrastLight ?? light, alpha: highContrastLightAlpha ?? lightAlpha)
        case .accessibilityHighContrastDarkAqua?:
          return rgb(highContrastDark ?? dark, alpha: highContrastDarkAlpha ?? darkAlpha)
        default:
          return rgb(light, alpha: lightAlpha)
        }
      })
  }

  static func rgb(_ hex: UInt32, alpha: CGFloat) -> NSColor {
    NSColor(
      srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
  }
}
