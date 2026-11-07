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
    /// The one hero figure on a screen.
    case hero
    /// Inspector headline.
    case large
    /// Key figures in cards.
    case figure
    /// Table rows.
    case row
    /// Secondary text and sidebar balances.
    case small
    /// Captions.
    case caption

    /// A system text style per role, so figures follow the Mac's text size.
    var font: Font {
      switch self {
      case .hero: LedgerTheme.Typeface.hero
      case .large: LedgerTheme.Typeface.figureLarge
      case .figure: LedgerTheme.Typeface.figure
      case .row: LedgerTheme.Typeface.bodyEmphasis
      case .small: LedgerTheme.Typeface.secondary
      case .caption: LedgerTheme.Typeface.caption
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
    let colors = palette(for: parts)
    MoneyText.compose(parts, size: size, color: colors.main, quiet: colors.quiet)
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(formatter.hidesAmounts ? LedgerDisplayFormatter.hiddenAmountLabel : parts.text)
  }

  /// The figure's colour and its quiet partner (symbol, paise). Both are theme tokens, so they
  /// follow Increase Contrast.
  private func palette(for parts: MoneyParts) -> (main: Color, quiet: Color) {
    let ink = (LedgerTheme.ink, LedgerTheme.inkQuiet)
    switch tone {
    case .neutral: return ink
    case .secondary: return (LedgerTheme.inkSecondary, LedgerTheme.inkSecondaryQuiet)
    case .automatic:
      // A hidden amount keeps plain ink: a colour would still tell money in from money out.
      if formatter.hidesAmounts { return ink }
      if amount.amount.isNegative, negativeIsAlert || (sign == .always && amountColors.tintsSpending) {
        return (LedgerTheme.negative, LedgerTheme.negativeQuiet)
      }
      guard amount.amount.isPositive, sign == .always else { return ink }
      switch amountColors {
      case .monochrome: return ink
      case .incomeBlueExpenseRed: return (LedgerTheme.positiveBlue, LedgerTheme.positiveBlueQuiet)
      case .incomeGreen, .incomeGreenExpenseRed: return (LedgerTheme.positive, LedgerTheme.positiveQuiet)
      }
    }
  }

  /// Builds the styled text. The symbol and fraction take the quiet colour so the whole units
  /// read first, while the figure stays one object.
  static func compose(_ parts: MoneyParts, size: Size, color: Color, quiet: Color) -> Text {
    let font = size.font.monospacedDigit()
    let head = Text(parts.sign.rawValue).font(font).foregroundStyle(color)
    let symbol = Text(parts.leading).font(font).foregroundStyle(quiet)
    let whole = Text(parts.whole).font(font).foregroundStyle(color)
    let fraction = Text(parts.fraction + parts.trailing).font(font).foregroundStyle(quiet)
    return (head + symbol + whole + fraction).tracking(LedgerTheme.figureTracking(for: size))
  }
}

extension LedgerProductSettings.AmountColors {
  /// Whether spending is tinted red. The default keeps spending in plain ink.
  public var tintsSpending: Bool { self == .incomeGreenExpenseRed || self == .incomeBlueExpenseRed }
}
