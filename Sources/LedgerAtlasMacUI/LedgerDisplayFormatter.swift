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

  public init(locale: Locale) { self.locale = locale }

  public init(settings: LedgerProductSettings) { self.init(locale: settings.locale) }

  /// Decimal holds 38 significant digits; longer canonical values are shown verbatim.
  static let maximumFormattedDigits = 38

  /// A localized currency string. Fraction digits never drop below the canonical scale,
  /// so no displayed amount is rounded.
  public func amount(_ value: CurrencyAmount) -> String {
    let canonical = value.amount.description
    guard let prepared = numberFormatter(for: value) else { return "\(value.unitCode) \(canonical)" }
    return prepared.formatter.string(from: prepared.decimal as NSDecimalNumber) ?? "\(value.unitCode) \(canonical)"
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

  private static let utc = TimeZone(identifier: "UTC")!

  private static func instant(atNoonOf date: SourceLocalDate) -> Date {
    let days = LedgerPeriodRule.days(from: date)
    return Date(timeIntervalSince1970: TimeInterval(days) * 86_400 + 43_200)
  }
}
