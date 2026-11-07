import AppKit
import SwiftUI

/// The design tokens for the Ledger Atlas look. See DESIGN.md for the rules behind them.
///
/// This is the only file allowed to define colours (the accessibility guard in
/// LedgerAccessibilityTests exempts it). Every colour here is dynamic and has its own
/// Increase Contrast value, so it follows that setting the way system colours do, and views
/// never branch on the colour scheme or fade a colour themselves.
public enum LedgerTheme {
  // MARK: Colour

  /// Window content background behind every screen. Numbers live on this solid surface,
  /// never on glass. Light is a shade off white so white cards stand out from it.
  public static let canvas = dynamic(
    light: 0xF5F5F4, dark: 0x1C1C1E, highContrastLight: 0xFBFBFA, highContrastDark: 0x1C1C1E)
  /// Recessed surfaces: inspector, day headers, drop zones. Below the canvas in both looks
  /// (darker than it in dark mode too), so they read as set in, never raised.
  public static let recessed = dynamic(
    light: 0xF0F0EE, dark: 0x161618, highContrastLight: 0xF4F4F2, highContrastDark: 0x141416)
  /// Raised cards on the canvas: lighter than the canvas in both looks.
  public static let card = dynamic(light: 0xFFFFFF, dark: 0x28282B, highContrastLight: 0xFFFFFF, highContrastDark: 0x26262A)

  public static let ink = dynamic(light: 0x1D1D1F, dark: 0xF5F5F7, highContrastLight: 0x000000, highContrastDark: 0xFFFFFF)
  public static let inkSecondary = dynamic(light: 0x515154, dark: 0xC7C7CC, highContrastLight: 0x2C2C2E, highContrastDark: 0xE5E5EA)
  public static let inkTertiary = dynamic(light: 0x69696D, dark: 0x8E8E93, highContrastLight: 0x515154, highContrastDark: 0xC7C7CC)

  /// Hairline separators. Increase Contrast doubles their strength.
  public static let hairline = dynamic(
    light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.09,
    highContrastLightAlpha: 0.22, highContrastDarkAlpha: 0.26)
  public static let hairlineSoft = dynamic(
    light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.045, darkAlpha: 0.05,
    highContrastLightAlpha: 0.16, highContrastDarkAlpha: 0.2)
  /// Fill for fields, chips and unselected segmented items.
  public static let fieldFill = dynamic(
    light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.10,
    highContrastLightAlpha: 0.09, highContrastDarkAlpha: 0.14)

  /// The single accent: selection, focus and the one primary action per surface.
  public static let accent = dynamic(light: 0x09747D, dark: 0x4FC3CE, highContrastLight: 0x005A62, highContrastDark: 0x7FDDE6)
  public static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x062024)
  public static let accentSoft = dynamic(
    light: 0x09747D, dark: 0x4FC3CE, lightAlpha: 0.11, darkAlpha: 0.16,
    highContrastLightAlpha: 0.2, highContrastDarkAlpha: 0.26)

  /// Money in. Spending stays in `ink`; colour is never the only signal (signs always show).
  public static let positive = dynamic(light: 0x1B774A, dark: 0x4CC985, highContrastLight: 0x0C5F35, highContrastDark: 0x7BE0A8)
  /// Over budget, negative balances, destructive actions and errors.
  public static let negative = dynamic(light: 0xBA3E2B, dark: 0xFF7A66, highContrastLight: 0x992918, highContrastDark: 0xFF9D8D)
  public static let warning = dynamic(light: 0x975B00, dark: 0xF0A83C, highContrastLight: 0x784700, highContrastDark: 0xFFC266)
  /// Blue alternative for money in, for the "income blue" amount-colour setting.
  public static let positiveBlue = dynamic(light: 0x2B67C0, dark: 0x6FA8FF, highContrastLight: 0x225198, highContrastDark: 0x8AB9FF)

  /// The quiet half of a figure (currency symbol, paise). One per amount colour, so the
  /// de-emphasis follows Increase Contrast instead of fading a colour by hand. Each still
  /// reaches 4.5:1 on the canvas and cards (7:1 with Increase Contrast), checked by
  /// `themeTextColoursMeetContrastMinimums`.
  public static let inkQuiet = dynamic(
    light: 0x1D1D1F, dark: 0xF5F5F7, highContrastLight: 0x000000, highContrastDark: 0xFFFFFF,
    lightAlpha: 0.64, darkAlpha: 0.52, highContrastLightAlpha: 0.68, highContrastDarkAlpha: 0.67)
  public static let positiveQuiet = dynamic(
    light: 0x1B774A, dark: 0x4CC985, highContrastLight: 0x0C5F35, highContrastDark: 0x7BE0A8,
    lightAlpha: 0.97, darkAlpha: 0.75, highContrastLightAlpha: 0.99, highContrastDarkAlpha: 0.87)
  public static let positiveBlueQuiet = dynamic(
    light: 0x2B67C0, dark: 0x6FA8FF, highContrastLight: 0x225198, highContrastDark: 0x8AB9FF,
    lightAlpha: 0.97, darkAlpha: 0.81, highContrastLightAlpha: 0.99, highContrastDarkAlpha: 0.98)
  public static let negativeQuiet = dynamic(
    light: 0xBA3E2B, dark: 0xFF7A66, highContrastLight: 0x992918, highContrastDark: 0xFF9D8D,
    lightAlpha: 0.96, darkAlpha: 0.85, highContrastLightAlpha: 0.98, highContrastDarkAlpha: 0.98)
  public static let inkSecondaryQuiet = dynamic(
    light: 0x515154, dark: 0xC7C7CC, highContrastLight: 0x2C2C2E, highContrastDark: 0xE5E5EA,
    lightAlpha: 0.85, darkAlpha: 0.66, highContrastLightAlpha: 0.82, highContrastDarkAlpha: 0.75)

  /// Fills for past months in the cash-flow chart; the current month uses the full colour.
  public static let positiveSoft = dynamic(
    light: 0x1B774A, dark: 0x4CC985, highContrastLight: 0x0C5F35, highContrastDark: 0x7BE0A8,
    lightAlpha: 0.35, darkAlpha: 0.4, highContrastLightAlpha: 0.55, highContrastDarkAlpha: 0.6)
  public static let inkSoft = dynamic(
    light: 0x1D1D1F, dark: 0xF5F5F7, highContrastLight: 0x000000, highContrastDark: 0xFFFFFF,
    lightAlpha: 0.22, darkAlpha: 0.26, highContrastLightAlpha: 0.4, highContrastDarkAlpha: 0.45)

  /// Pressed states for the two button styles.
  public static let accentPressed = dynamic(light: 0x07636B, dark: 0x3FAAB4, highContrastLight: 0x00474D, highContrastDark: 0x9FE8EE)
  public static let fieldFillPressed = dynamic(
    light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.11, darkAlpha: 0.16,
    highContrastLightAlpha: 0.16, highContrastDarkAlpha: 0.22)
  /// Track behind progress bars.
  public static let track = dynamic(
    light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.12,
    highContrastLightAlpha: 0.16, highContrastDarkAlpha: 0.2)

  /// Colours that draw text. Each reaches 4.5:1 on the canvas and on cards, and 7:1 with
  /// Increase Contrast (`themeTextColoursMeetContrastMinimums`).
  static let textTokens: [(name: String, color: Color)] = [
    ("ink", ink), ("inkSecondary", inkSecondary), ("inkTertiary", inkTertiary),
    ("inkQuiet", inkQuiet), ("inkSecondaryQuiet", inkSecondaryQuiet), ("accent", accent),
    ("positive", positive), ("positiveQuiet", positiveQuiet), ("positiveBlue", positiveBlue),
    ("positiveBlueQuiet", positiveBlueQuiet), ("negative", negative), ("negativeQuiet", negativeQuiet),
    ("warning", warning),
  ]

  /// Every token, for the Increase Contrast check (`themeColoursHaveIncreaseContrastValues`).
  static let allTokens: [(name: String, color: Color)] =
    textTokens + [
      ("canvas", canvas), ("recessed", recessed), ("card", card), ("hairline", hairline),
      ("hairlineSoft", hairlineSoft), ("fieldFill", fieldFill), ("fieldFillPressed", fieldFillPressed),
      ("accentSoft", accentSoft), ("accentPressed", accentPressed), ("onAccent", onAccent),
      ("track", track), ("positiveSoft", positiveSoft), ("inkSoft", inkSoft),
    ]

  /// Tokens that keep their colour under Increase Contrast, and why. The window surfaces
  /// already sit at the ends of the range, white on the accent is already above 7:1 there,
  /// and the category palette is decorative (keys and bars, never text alone).
  static let increaseContrastExceptions: [String: String] = [
    "canvas": "window background", "recessed": "window background",
    "card": "already white in light mode (dark mode changes)", "onAccent": "label on the accent",
  ]

  /// A palette colour with its soft fill (icon tiles, selected chips).
  public struct Swatch: Sendable {
    public let color: Color
    public let soft: Color
  }

  /// Category and account colours: muted, equal in perceived lightness, used only as
  /// small keys, thin bars and soft tiles.
  public static let palette: [Swatch] = paletteHex.map { light, dark in
    Swatch(
      color: dynamic(light: light, dark: dark),
      soft: dynamic(
        light: light, dark: dark, lightAlpha: 0.16, darkAlpha: 0.26,
        highContrastLightAlpha: 0.28, highContrastDarkAlpha: 0.38))
  }

  public static var categoryPalette: [Color] { palette.map(\.color) }

  /// A stable palette swatch for any name, so a category keeps its colour everywhere.
  public static func swatch(for key: String) -> Swatch {
    palette[Int(stableHash(key) % UInt64(palette.count))]
  }

  public static func paletteColor(for key: String) -> Color { swatch(for: key).color }

  /// Account colours: no two accounts alike while the palette lasts, and never the rose that
  /// sits next to a red negative balance. Each name starts at its stable slot and takes the next
  /// free one, in name order, so an account keeps its colour on every screen that lists the
  /// same accounts (sidebar keys, Accounts tiles).
  public static func accountSwatches(for names: [String]) -> [String: Swatch] {
    accountPaletteIndices(for: names).mapValues { palette[$0] }
  }

  /// The palette index behind each account's colour (see `accountSwatches`).
  static func accountPaletteIndices(for names: [String]) -> [String: Int] {
    let slots = palette.indices.filter { $0 != roseIndex }
    var taken = Set<Int>()
    var result: [String: Int] = [:]
    for name in Set(names).sorted() {
      let start = Int(stableHash(name) % UInt64(slots.count))
      let offset = (0..<slots.count).first { !taken.contains((start + $0) % slots.count) } ?? 0
      let slot = (start + offset) % slots.count
      taken.insert(slot)
      // More accounts than colours: start sharing again.
      if taken.count == slots.count { taken.removeAll() }
      result[name] = slots[slot]
    }
    return result
  }

  /// The palette's light and dark values, in order.
  static let paletteHex: [(light: UInt32, dark: UInt32)] = [
    (0x5B7FB8, 0x7D9FD6), (0xC27A46, 0xDF9764), (0x6E9E72, 0x8CBF90), (0xC2A245, 0xDCBD60),
    (0xA7709D, 0xC690BB), (0x5E9EA3, 0x7DBDC2), (0xB5666A, 0xD68589), (0x8B8F97, 0xA3A7AE),
  ]

  /// The palette's rose, kept off account keys because it reads as a warning beside red figures.
  static let roseIndex = paletteHex.firstIndex { $0.light == 0xB5666A } ?? 6

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

  /// The type scale. Every style is a system text style, so it follows the Mac's text size
  /// and display zoom (the accessibility guard forbids fixed point sizes). Money adds tabular
  /// figures (see `MoneyText`).
  public enum Typeface {
    /// The one hero figure on a screen.
    public static let hero = Font.system(.largeTitle, weight: .semibold)
    /// Inspector headline figure.
    public static let figureLarge = Font.system(.title, weight: .semibold)
    /// Key figures in cards.
    public static let figure = Font.system(.title2, weight: .semibold)
    /// Welcome and empty-state titles.
    public static let display = Font.system(.largeTitle, weight: .bold)
    /// Screen titles.
    public static let screenTitle = Font.system(.title3, weight: .bold)
    /// Card and section titles.
    public static let cardTitle = Font.headline
    public static let body = Font.body
    public static let bodyEmphasis = Font.system(.body, weight: .medium)
    public static let secondary = Font.callout
    public static let caption = Font.subheadline
    public static let captionEmphasis = Font.system(.subheadline, weight: .semibold)
  }

  /// Tracking for figures by role: large figures tighten like SF Pro Display.
  static func figureTracking(for size: MoneyText.Size) -> CGFloat {
    switch size {
    case .hero: -0.8
    case .large: -0.5
    case .figure: -0.25
    case .row, .small, .caption: 0
    }
  }

  // MARK: Dynamic colour

  static func dynamic(
    light: UInt32, dark: UInt32, highContrastLight: UInt32? = nil, highContrastDark: UInt32? = nil,
    lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1,
    highContrastLightAlpha: CGFloat? = nil, highContrastDarkAlpha: CGFloat? = nil
  ) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        switch variant(of: appearance) {
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

  /// Tests set this to resolve the Increase Contrast values: AppKit doesn't hand out the
  /// high-contrast appearances by name (`NSAppearance(named:)` answers plain Aqua for them),
  /// only the system applies them when Increase Contrast is on.
  @TaskLocal static var resolvesIncreaseContrast = false

  /// Which of the four looks an appearance asks for.
  static func variant(of appearance: NSAppearance) -> NSAppearance.Name? {
    let match = appearance.bestMatch(from: [
      .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua, .aqua, .darkAqua,
    ])
    let isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
    let isHighContrast =
      resolvesIncreaseContrast || match == .accessibilityHighContrastAqua
      || match == .accessibilityHighContrastDarkAqua
    switch (isDark, isHighContrast) {
    case (false, false): return .aqua
    case (true, false): return .darkAqua
    case (false, true): return .accessibilityHighContrastAqua
    case (true, true): return .accessibilityHighContrastDarkAqua
    }
  }

  static func rgb(_ hex: UInt32, alpha: CGFloat) -> NSColor {
    NSColor(
      srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
  }
}
