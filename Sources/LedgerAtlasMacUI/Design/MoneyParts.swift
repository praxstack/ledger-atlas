import Foundation

/// A formatted amount split into the parts the money typography styles differently:
/// the sign and currency symbol, the whole units, and the fraction (".30").
///
/// Splitting happens on already-formatted text, so the formatter stays the only source of
/// truth for grouping, symbol placement and separators. Joining the parts gives back the
/// exact formatted string, with the sign in front.
public struct MoneyParts: Equatable, Sendable {
  public enum Sign: String, Sendable {
    case none = ""
    case plus = "+"
    case minus = "\u{2212}"
  }

  public var sign: Sign
  /// Text before the digits, usually the currency symbol ("₹", "US$", "USD ").
  public var leading: String
  /// Whole units with grouping ("4,83,676").
  public var whole: String
  /// Decimal separator and fraction digits (".30"), or empty.
  public var fraction: String
  /// Text after the digits ("€" or " USD" in some locales).
  public var trailing: String

  public var text: String { sign.rawValue + leading + whole + fraction + trailing }

  /// Splits `formatted` (an unsigned, locale-formatted currency string) at its digits.
  /// `decimalSeparator` is the formatter's currency decimal separator.
  public init(formatted: String, decimalSeparator: String, sign: Sign) {
    self.sign = sign
    let chars = Array(formatted)
    guard let first = chars.firstIndex(where: \.isNumber),
      let last = chars.lastIndex(where: \.isNumber)
    else {
      leading = formatted
      whole = ""
      fraction = ""
      trailing = ""
      return
    }
    leading = String(chars[..<first])
    trailing = String(chars[(last + 1)...])
    let digits = String(chars[first...last])
    if !decimalSeparator.isEmpty, let range = digits.range(of: decimalSeparator, options: .backwards) {
      whole = String(digits[..<range.lowerBound])
      fraction = String(digits[range.lowerBound...])
    } else {
      whole = digits
      fraction = ""
    }
  }

  public init(sign: Sign, leading: String, whole: String, fraction: String, trailing: String) {
    self.sign = sign
    self.leading = leading
    self.whole = whole
    self.fraction = fraction
    self.trailing = trailing
  }
}
