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
    let digits = canonical.filter(\.isNumber)
    guard digits.count <= Self.maximumFormattedDigits,
      let decimal = Decimal(string: canonical, locale: Locale(identifier: "en_US_POSIX"))
    else { return "\(value.unitCode) \(canonical)" }
    let scale = canonical.split(separator: ".", maxSplits: 1).dropFirst().first?.count ?? 0
    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.numberStyle = .currency
    formatter.currencyCode = value.unitCode
    let fraction = max(formatter.maximumFractionDigits, scale)
    formatter.minimumFractionDigits = fraction
    formatter.maximumFractionDigits = fraction
    return formatter.string(from: decimal as NSDecimalNumber) ?? "\(value.unitCode) \(canonical)"
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
