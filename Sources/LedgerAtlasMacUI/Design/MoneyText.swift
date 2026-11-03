import LedgerCore
import SwiftUI

extension EnvironmentValues {
  /// The formatter every money and date view reads. The root view sets it from Settings.
  @Entry public var ledgerFormatter = LedgerDisplayFormatter(locale: Locale(identifier: "en_US"))
  /// How money in and money out are tinted, from Settings.
  @Entry public var ledgerAmountColors: LedgerProductSettings.AmountColors = .incomeGreen
}

/// An amount set the Ledger Atlas way: tabular figures, the currency symbol and the fraction
/// quieter than the whole units, a true minus sign, and colour only for money in.
///
/// VoiceOver reads the plain formatted amount, sign included.
public struct MoneyText: View {
  public enum Size: Sendable {
    /// The one hero figure on a screen (44 pt).
    case hero
    /// Inspector headline (32 pt).
    case large
    /// Key figures in cards (20 pt).
    case figure
    /// Table rows (13 pt medium).
    case row
    /// Secondary text and sidebar balances (12.5 pt).
    case small
    /// Captions (11.5 pt).
    case caption

    var points: CGFloat {
      switch self {
      case .hero: 44
      case .large: 32
      case .figure: 20
      case .row: 13
      case .small: 12.5
      case .caption: 11.5
      }
    }

    var weight: Font.Weight {
      switch self {
      case .hero, .large, .figure: .semibold
      case .row: .medium
      case .small, .caption: .regular
      }
    }
  }

  /// Which colour the amount takes.
  public enum Tone: Sendable {
    /// Money in is positive-coloured, everything else is ink; negative balances are red.
    case automatic
    /// Always ink, whatever the sign.
    case neutral
    /// Always secondary ink.
    case secondary
  }

  private let amount: CurrencyAmount
  private let size: Size
  private let sign: LedgerDisplayFormatter.SignStyle
  private let tone: Tone
  /// For balances, a negative amount is a problem (red); for a transaction it is just spending.
  private let negativeIsAlert: Bool

  @Environment(\.ledgerFormatter) private var formatter
  @Environment(\.ledgerAmountColors) private var amountColors

  public init(
    _ amount: CurrencyAmount, size: Size = .row, sign: LedgerDisplayFormatter.SignStyle = .negativeOnly,
    tone: Tone = .automatic, negativeIsAlert: Bool = false
  ) {
    self.amount = amount
    self.size = size
    self.sign = sign
    self.tone = tone
    self.negativeIsAlert = negativeIsAlert
  }

  public var body: some View {
    let parts = formatter.parts(amount, sign: sign)
    MoneyText.compose(parts, size: size, color: color(for: parts))
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(parts.text)
  }

  private func color(for parts: MoneyParts) -> Color {
    switch tone {
    case .neutral: return LedgerTheme.ink
    case .secondary: return LedgerTheme.inkSecondary
    case .automatic:
      if amount.amount.isNegative, negativeIsAlert || (sign == .always && amountColors.tintsSpending) {
        return LedgerTheme.negative
      }
      guard amount.amount.isPositive, sign == .always else { return LedgerTheme.ink }
      switch amountColors {
      case .monochrome: return LedgerTheme.ink
      case .incomeBlueExpenseRed: return LedgerTheme.positiveBlue
      case .incomeGreen, .incomeGreenExpenseRed: return LedgerTheme.positive
      }
    }
  }

  /// Builds the styled text. The symbol and fraction drop to about half strength so the whole
  /// units read first; they keep the same colour so the figure stays one object.
  static func compose(_ parts: MoneyParts, size: Size, color: Color) -> Text {
    let font = Font.system(size: size.points, weight: size.weight).monospacedDigit()
    let tracking = LedgerTheme.figureTracking(forSize: size.points)
    let quiet = color.opacity(size.points >= 18 ? 0.42 : 0.55)
    let head = Text(parts.sign.rawValue).font(font).foregroundStyle(color)
    let symbol = Text(parts.leading).font(font).foregroundStyle(quiet)
    let whole = Text(parts.whole).font(font).foregroundStyle(color)
    let fraction = Text(parts.fraction + parts.trailing).font(font).foregroundStyle(quiet)
    return (head + symbol + whole + fraction).tracking(tracking)
  }
}

extension LedgerProductSettings.AmountColors {
  /// Whether spending is tinted red. The default keeps spending in plain ink.
  public var tintsSpending: Bool { self == .incomeGreenExpenseRed || self == .incomeBlueExpenseRed }
}
