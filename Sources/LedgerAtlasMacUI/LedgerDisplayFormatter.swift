import Foundation
import LedgerCore

/// Formats canonical values for display in the user's chosen locale (MACV2-13).
///
/// This type only goes one way: canonical value → display text. It has no parsing API on
/// purpose. Display text depends on locale ("1.234,50 €" vs "€1,234.50"), so reading it
/// back would change financial truth. Inputs are parsed by the entry forms with invariant
/// rules, never from formatted output.
public struct LedgerDisplayFormatter: Sendable {
  public let locale: Locale
  /// Hide amounts (#173): every figure this formatter produces has its digits replaced by
  /// bullets, one per digit, so layouts keep their width and nothing shifts when it is turned
  /// on. Exports never use a hiding formatter.
  public let hidesAmounts: Bool

  public init(locale: Locale, hidesAmounts: Bool = false) {
    self.locale = locale
    self.hidesAmounts = hidesAmounts
  }

  public init(settings: LedgerProductSettings) {
    self.init(locale: settings.locale, hidesAmounts: settings.hidesAmounts)
  }

  /// What VoiceOver says in place of a hidden figure.
  public static let hiddenAmountLabel = "Amount hidden"

  /// `text` with every digit replaced by a bullet when amounts are hidden.
  public func figure(_ text: String) -> String {
    hidesAmounts ? Self.redacted(text) : text
  }

  /// An amount as plain text ("1234.50 INR"), for summaries and captions that don't use the
  /// money typography. Hidden like every other figure.
  public func plain(_ value: ExactDecimal, unitCode: String? = nil) -> String {
    figure(unitCode.map { "\(value.rawLiteral) \($0)" } ?? value.rawLiteral)
  }

  public func plain(_ value: CurrencyAmount) -> String {
    plain(value.amount, unitCode: value.unitCode)
  }

  static func redacted(_ text: String) -> String {
    String(text.map { $0.isNumber ? "\u{2022}" : $0 })
  }

  /// Decimal holds 38 significant digits; longer canonical values are shown verbatim.
  static let maximumFormattedDigits = 38

  /// A localized currency string. Fraction digits never drop below the canonical scale,
  /// so no displayed amount is rounded.
  public func amount(_ value: CurrencyAmount) -> String {
    let canonical = value.amount.description
    guard let prepared = numberFormatter(for: value) else { return figure("\(value.unitCode) \(canonical)") }
    return figure(
      prepared.formatter.string(from: prepared.decimal as NSDecimalNumber) ?? "\(value.unitCode) \(canonical)")
  }

  /// How a signed amount shows its direction.
  public enum SignStyle: Sendable {
    /// Only negative amounts get a sign (balances, totals).
    case negativeOnly
    /// Every non-zero amount gets "+" or "−" (transactions, cash flow).
    case always
    /// No sign at all (a budget's limit, an amount already labelled "spent").
    case never
  }

  /// The amount split for the money typography (`MoneyText`). The sign is the true minus
  /// sign (U+2212), never a hyphen, and `parts.text` is what VoiceOver reads.
  public func parts(_ value: CurrencyAmount, sign style: SignStyle = .negativeOnly) -> MoneyParts {
    let shown = unhiddenParts(value, sign: style)
    guard hidesAmounts else { return shown }
    // The direction is part of the figure too, so a hidden amount shows no sign.
    return MoneyParts(
      sign: .none, leading: shown.leading, whole: Self.redacted(shown.whole),
      fraction: Self.redacted(shown.fraction), trailing: shown.trailing)
  }

  private func unhiddenParts(_ value: CurrencyAmount, sign style: SignStyle) -> MoneyParts {
    let negative = value.amount.isNegative
    let sign: MoneyParts.Sign =
      switch style {
      case .never: .none
      case .negativeOnly: negative ? .minus : .none
      case .always: negative ? .minus : (value.amount.isPositive ? .plus : .none)
      }
    let canonical = value.amount.description
    let magnitude = canonical.hasPrefix("-") ? String(canonical.dropFirst()) : canonical
    guard let unsigned = try? CurrencyAmount(unitCode: value.unitCode, amount: ExactDecimal(magnitude)),
      let prepared = numberFormatter(for: unsigned),
      let text = prepared.formatter.string(from: prepared.decimal as NSDecimalNumber)
    else {
      return MoneyParts(sign: sign, leading: "\(value.unitCode) ", whole: magnitude, fraction: "", trailing: "")
    }
    return MoneyParts(
      formatted: text, decimalSeparator: prepared.formatter.currencyDecimalSeparator, sign: sign)
  }

  /// Rupee amounts always use Indian digit grouping (₹4,83,676.30), whatever the display
  /// locale, because that is how rupee figures are read. Other currencies follow `locale`.
  func numberingLocale(for unitCode: String) -> Locale {
    guard unitCode == "INR", locale.region?.identifier != "IN" else { return locale }
    let language = locale.language.languageCode?.identifier ?? "en"
    return Locale(identifier: "\(language)_IN")
  }

  private func numberFormatter(for value: CurrencyAmount) -> (formatter: NumberFormatter, decimal: Decimal)? {
    let canonical = value.amount.description
    let digits = canonical.filter(\.isNumber)
    guard digits.count <= Self.maximumFormattedDigits,
      let decimal = Decimal(string: canonical, locale: Locale(identifier: "en_US_POSIX"))
    else { return nil }
    let scale = canonical.split(separator: ".", maxSplits: 1).dropFirst().first?.count ?? 0
    let formatter = NumberFormatter()
    formatter.locale = numberingLocale(for: value.unitCode)
    formatter.numberStyle = .currency
    formatter.currencyCode = value.unitCode
    if value.unitCode == "INR" { formatter.currencySymbol = "₹" }
    let fraction = max(formatter.maximumFractionDigits, scale)
    formatter.minimumFractionDigits = fraction
    formatter.maximumFractionDigits = fraction
    return (formatter, decimal)
  }

  /// A localized date. The civil date is formatted as itself: no time zone can move it to
  /// the previous or next day.
  public func date(_ date: SourceLocalDate, style: DateFormatter.Style = .medium) -> String {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = Self.utc
    formatter.dateStyle = style
    formatter.timeStyle = .none
    return formatter.string(from: Self.instant(atNoonOf: date))
  }

  /// "Nov" for chart axes, in the display locale.
  public func shortMonth(_ date: SourceLocalDate) -> String {
    templated("MMM", date)
  }

  /// "November 2026" for screen subtitles.
  public func monthTitle(_ date: SourceLocalDate) -> String {
    templated("MMMMyyyy", date)
  }

  private func templated(_ template: String, _ date: SourceLocalDate) -> String {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = Self.utc
    formatter.setLocalizedDateFormatFromTemplate(template)
    return formatter.string(from: Self.instant(atNoonOf: date))
  }

  /// A short axis label: lakh and crore for rupees ("₹4.5L", "₹1.2Cr"), thousands and
  /// millions otherwise ("$450K", "$1.2M"). Only for chart axes; figures use `parts`.
  public func compactAxis(_ value: Double, unitCode: String) -> String {
    let symbol = currencySymbol(for: unitCode)
    // A hidden axis says nothing about scale: every label is the same.
    if hidesAmounts { return symbol + "\u{2022}\u{2022}\u{2022}" }
    let sign = value < 0 ? "\u{2212}" : ""
    let magnitude = abs(value)
    let steps: [(Double, String)] =
      unitCode == "INR" ? [(1e7, "Cr"), (1e5, "L"), (1e3, "K")] : [(1e9, "B"), (1e6, "M"), (1e3, "K")]
    for (size, suffix) in steps where magnitude >= size {
      let scaled = magnitude / size
      let text = scaled >= 10 ? String(Int(scaled.rounded())) : String(format: "%.1f", scaled)
      return sign + symbol + text.replacingOccurrences(of: ".0", with: "") + suffix
    }
    return sign + symbol + String(Int(magnitude.rounded()))
  }

  /// The currency symbol the formatter uses for `unitCode` ("₹", "$", "€").
  public func currencySymbol(for unitCode: String) -> String {
    guard let amount = try? CurrencyAmount(unitCode: unitCode, amount: ExactDecimal("0")) else {
      return unitCode
    }
    let parts = unhiddenParts(amount, sign: .never)
    let symbol = parts.leading.isEmpty ? parts.trailing : parts.leading
    return symbol.trimmingCharacters(in: .whitespaces)
  }

  private static let utc = TimeZone(identifier: "UTC")!

  private static func instant(atNoonOf date: SourceLocalDate) -> Date {
    let days = LedgerPeriodRule.days(from: date)
    return Date(timeIntervalSince1970: TimeInterval(days) * 86_400 + 43_200)
  }
}
