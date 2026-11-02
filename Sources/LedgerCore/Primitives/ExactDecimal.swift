public enum RoundingPolicy: String, Codable, CaseIterable, Sendable {
  case towardZero
  case awayFromZero
  case floor
  case ceiling
  case halfUp
  case halfEven

  private static let maximumRawValueBytes = 32

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(String.self)
    let byteCount = BoundedUTF8.count(rawValue, through: Self.maximumRawValueBytes)
    guard byteCount <= Self.maximumRawValueBytes, let value = Self(rawValue: rawValue) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "invalid rounding policy"
      )
    }
    self = value
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public enum ExactDecimalError: Error, Equatable, Sendable, CustomStringConvertible {
  case emptyLiteral(position: Int)
  case literalTooLong(limit: Int, actualByteCount: Int)
  case invalidCharacter(position: Int)
  case multipleDecimalSeparators(position: Int)
  case missingDigits(position: Int)
  case tooManyDigits(limit: Int, actual: Int)
  case scaleTooLarge(limit: Int, actual: Int)
  case divisionByZero

  public var description: String {
    switch self {
    case .emptyLiteral(let position):
      "decimal literal is empty at byte \(position)"
    case .literalTooLong(let limit, let actualByteCount):
      "decimal literal exceeds \(limit) bytes (actual \(actualByteCount))"
    case .invalidCharacter(let position):
      "decimal literal has an invalid character at byte \(position)"
    case .multipleDecimalSeparators(let position):
      "decimal literal has another separator at byte \(position)"
    case .missingDigits(let position):
      "decimal literal has no digits at byte \(position)"
    case .tooManyDigits(let limit, let actual):
      "decimal magnitude exceeds \(limit) digits (actual \(actual))"
    case .scaleTooLarge(let limit, let actual):
      "decimal scale exceeds \(limit) digits (actual \(actual))"
    case .divisionByZero:
      "division by zero"
    }
  }
}

public struct ExactDecimal: Sendable, CustomStringConvertible, Codable, Hashable, Comparable {
  public static let maximumDigits = 128
  public static let maximumScale = 64
  private static let maximumLiteralBytes = maximumDigits + maximumScale + 3

  public let rawLiteral: String
  public let sourceScale: Int

  private let sign: Int8
  private let digits: [UInt8]
  private let scale: Int

  private enum MagnitudeComparison {
    case ascending
    case same
    case descending
  }

  public init(_ literal: String) throws {
    let byteCount = BoundedUTF8.count(literal, through: Self.maximumLiteralBytes)
    guard byteCount > 0 else {
      throw ExactDecimalError.emptyLiteral(position: 0)
    }
    guard byteCount <= Self.maximumLiteralBytes else {
      throw ExactDecimalError.literalTooLong(
        limit: Self.maximumLiteralBytes, actualByteCount: byteCount
      )
    }

    let bytes = Array(literal.utf8)
    var index = 0
    var parsedSign: Int8 = 1
    if bytes[index] == 45 || bytes[index] == 43 {
      parsedSign = bytes[index] == 45 ? -1 : 1
      index += 1
    }
    guard index < bytes.count else {
      throw ExactDecimalError.missingDigits(position: index)
    }

    var parsedDigits: [UInt8] = []
    parsedDigits.reserveCapacity(bytes.count)
    var separatorPosition: Int?
    var fractionalDigits = 0
    var sawDigit = false

    while index < bytes.count {
      let byte = bytes[index]
      if byte >= 48, byte <= 57 {
        parsedDigits.append(byte - 48)
        sawDigit = true
        if separatorPosition != nil { fractionalDigits += 1 }
      } else if byte == 46 {
        guard separatorPosition == nil else {
          throw ExactDecimalError.multipleDecimalSeparators(position: index)
        }
        separatorPosition = index
      } else {
        throw ExactDecimalError.invalidCharacter(position: index)
      }
      index += 1
    }

    guard sawDigit else {
      throw ExactDecimalError.missingDigits(position: bytes.count)
    }
    guard fractionalDigits <= Self.maximumScale else {
      throw ExactDecimalError.scaleTooLarge(
        limit: Self.maximumScale, actual: fractionalDigits
      )
    }

    let normalized = Self.normalized(
      sign: parsedSign, digits: parsedDigits, scale: fractionalDigits)
    try Self.validateResourceInvariant(digits: normalized.digits, scale: normalized.scale)
    rawLiteral = literal
    sourceScale = fractionalDigits
    sign = normalized.sign
    digits = normalized.digits
    scale = normalized.scale
  }

  private init(sign: Int8, digits: [UInt8], scale: Int) throws {
    let normalized = Self.normalized(sign: sign, digits: digits, scale: scale)
    try Self.validateResourceInvariant(digits: normalized.digits, scale: normalized.scale)
    self.sign = normalized.sign
    self.digits = normalized.digits
    self.scale = normalized.scale
    sourceScale = normalized.scale
    rawLiteral = Self.render(
      sign: normalized.sign, digits: normalized.digits, scale: normalized.scale)
  }

  public var description: String {
    Self.render(sign: sign, digits: digits, scale: scale)
  }

  public func adding(_ other: ExactDecimal) throws -> ExactDecimal {
    let targetScale = max(scale, other.scale)
    let lhs = digits + repeatElement(0, count: targetScale - scale)
    let rhs = other.digits + repeatElement(0, count: targetScale - other.scale)

    if sign == 0 { return try ExactDecimal(sign: other.sign, digits: rhs, scale: targetScale) }
    if other.sign == 0 { return try ExactDecimal(sign: sign, digits: lhs, scale: targetScale) }
    if sign == other.sign {
      return try ExactDecimal(
        sign: sign, digits: Self.addMagnitudes(lhs, rhs), scale: targetScale
      )
    }

    switch Self.compareMagnitudes(lhs, rhs) {
    case .same:
      return try ExactDecimal(sign: 0, digits: [0], scale: 0)
    case .descending:
      return try ExactDecimal(
        sign: sign, digits: Self.subtractMagnitudes(lhs, rhs), scale: targetScale
      )
    case .ascending:
      return try ExactDecimal(
        sign: other.sign, digits: Self.subtractMagnitudes(rhs, lhs), scale: targetScale
      )
    }
  }

  public func subtracting(_ other: ExactDecimal) throws -> ExactDecimal {
    try adding(other.negated())
  }

  /// True for values greater than zero.
  public var isPositive: Bool { sign > 0 }

  /// True for values less than zero.
  public var isNegative: Bool { sign < 0 }

  public func multiplied(by other: ExactDecimal) throws -> ExactDecimal {
    if sign == 0 || other.sign == 0 {
      return try ExactDecimal(sign: 0, digits: [0], scale: 0)
    }
    return try ExactDecimal(
      sign: sign == other.sign ? 1 : -1,
      digits: Self.multiplyMagnitudes(digits, other.digits),
      scale: scale + other.scale
    )
  }

  public func divided(
    by other: ExactDecimal,
    scale resultScale: Int,
    rounding policy: RoundingPolicy
  ) throws -> ExactDecimal {
    guard other.sign != 0 else { throw ExactDecimalError.divisionByZero }
    guard resultScale >= 0, resultScale <= Self.maximumScale else {
      throw ExactDecimalError.scaleTooLarge(limit: Self.maximumScale, actual: resultScale)
    }
    if sign == 0 { return try ExactDecimal(sign: 0, digits: [0], scale: 0) }

    let exponent = resultScale + other.scale - scale
    var numerator = digits
    var denominator = other.digits
    if exponent >= 0 {
      numerator += repeatElement(0, count: exponent)
    } else {
      denominator += repeatElement(0, count: -exponent)
    }

    var (quotient, remainder) = Self.divideMagnitudes(numerator, by: denominator)
    let resultSign: Int8 = sign == other.sign ? 1 : -1
    if Self.shouldRoundUp(
      quotient: quotient,
      remainder: remainder,
      denominator: denominator,
      sign: resultSign,
      policy: policy
    ) {
      quotient = Self.addMagnitudes(quotient, [1])
    }
    remainder.removeAll(keepingCapacity: false)
    return try ExactDecimal(sign: resultSign, digits: quotient, scale: resultScale)
  }

  public static func == (lhs: ExactDecimal, rhs: ExactDecimal) -> Bool {
    lhs.sign == rhs.sign && lhs.scale == rhs.scale && lhs.digits == rhs.digits
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(sign)
    hasher.combine(scale)
    hasher.combine(digits)
  }

  public static func < (lhs: ExactDecimal, rhs: ExactDecimal) -> Bool {
    if lhs.sign != rhs.sign { return lhs.sign < rhs.sign }
    if lhs.sign == 0 { return false }
    let targetScale = max(lhs.scale, rhs.scale)
    let lhsDigits = lhs.digits + repeatElement(0, count: targetScale - lhs.scale)
    let rhsDigits = rhs.digits + repeatElement(0, count: targetScale - rhs.scale)
    let comparison = compareMagnitudes(lhsDigits, rhsDigits)
    return lhs.sign > 0 ? comparison == .ascending : comparison == .descending
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawLiteral)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let literal = try container.decode(String.self)
    do {
      try self.init(literal)
    } catch {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "invalid bounded exact decimal"
      )
    }
  }

  private func negated() -> ExactDecimal {
    ExactDecimal(uncheckedSign: -sign, digits: digits, scale: scale, rawLiteral: description)
  }

  private init(uncheckedSign: Int8, digits: [UInt8], scale: Int, rawLiteral: String) {
    sign = uncheckedSign
    self.digits = digits
    self.scale = scale
    self.rawLiteral = rawLiteral
    sourceScale = scale
  }

  private static func validateResourceInvariant(digits: [UInt8], scale: Int) throws {
    guard scale <= maximumScale else {
      throw ExactDecimalError.scaleTooLarge(limit: maximumScale, actual: scale)
    }
    guard digits.count <= maximumDigits else {
      throw ExactDecimalError.tooManyDigits(limit: maximumDigits, actual: digits.count)
    }
  }

  private static func normalized(
    sign: Int8, digits input: [UInt8], scale inputScale: Int
  ) -> (sign: Int8, digits: [UInt8], scale: Int) {
    var digits = input
    while digits.count > 1, digits.first == 0 { digits.removeFirst() }
    if digits.isEmpty || digits.allSatisfy({ $0 == 0 }) { return (0, [0], 0) }
    var scale = inputScale
    while scale > 0, digits.last == 0 {
      digits.removeLast()
      scale -= 1
    }
    return (sign < 0 ? -1 : 1, digits, scale)
  }

  private static func render(sign: Int8, digits: [UInt8], scale: Int) -> String {
    if sign == 0 { return "0" }
    let digitString = String(decoding: digits.map { $0 + 48 }, as: UTF8.self)
    let body: String
    if scale == 0 {
      body = digitString
    } else if scale >= digits.count {
      body = "0." + String(repeating: "0", count: scale - digits.count) + digitString
    } else {
      let split = digitString.index(digitString.endIndex, offsetBy: -scale)
      body = String(digitString[..<split]) + "." + String(digitString[split...])
    }
    return sign < 0 ? "-" + body : body
  }

  private static func compareMagnitudes(
    _ lhs: [UInt8], _ rhs: [UInt8]
  ) -> MagnitudeComparison {
    let left = trimmingLeadingZeros(lhs)
    let right = trimmingLeadingZeros(rhs)
    if left.count != right.count { return left.count < right.count ? .ascending : .descending }
    for (a, b) in zip(left, right) where a != b {
      return a < b ? .ascending : .descending
    }
    return .same
  }

  private static func trimmingLeadingZeros(_ input: [UInt8]) -> [UInt8] {
    guard let firstNonzero = input.firstIndex(where: { $0 != 0 }) else { return [0] }
    return Array(input[firstNonzero...])
  }

  private static func addMagnitudes(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
    var left = lhs.reversed().makeIterator()
    var right = rhs.reversed().makeIterator()
    var result: [UInt8] = []
    var carry: UInt8 = 0
    while true {
      let a = left.next()
      let b = right.next()
      if a == nil, b == nil, carry == 0 { break }
      let sum = (a ?? 0) + (b ?? 0) + carry
      result.append(sum % 10)
      carry = sum / 10
    }
    return result.reversed()
  }

  private static func subtractMagnitudes(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
    let left = Array(lhs.reversed())
    let right = Array(rhs.reversed())
    var result: [UInt8] = []
    var borrow = 0
    for index in left.indices {
      var value = Int(left[index]) - borrow - (index < right.count ? Int(right[index]) : 0)
      if value < 0 {
        value += 10
        borrow = 1
      } else {
        borrow = 0
      }
      result.append(UInt8(value))
    }
    return trimmingLeadingZeros(result.reversed())
  }

  private static func multiplyMagnitudes(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
    var result = Array(repeating: 0, count: lhs.count + rhs.count)
    for leftIndex in lhs.indices.reversed() {
      for rightIndex in rhs.indices.reversed() {
        let index = leftIndex + rightIndex + 1
        let product = Int(lhs[leftIndex]) * Int(rhs[rightIndex]) + result[index]
        result[index] = product % 10
        result[index - 1] += product / 10
      }
    }
    for index in result.indices.reversed() where result[index] >= 10 {
      let carry = result[index] / 10
      result[index] %= 10
      if index > 0 { result[index - 1] += carry }
    }
    return trimmingLeadingZeros(result.map(UInt8.init))
  }

  private static func divideMagnitudes(
    _ numerator: [UInt8], by denominator: [UInt8]
  ) -> (quotient: [UInt8], remainder: [UInt8]) {
    var quotient: [UInt8] = []
    var remainder: [UInt8] = [0]
    for digit in numerator {
      remainder = trimmingLeadingZeros(remainder + [digit])
      var quotientDigit: UInt8 = 0
      while compareMagnitudes(remainder, denominator) != .ascending {
        remainder = subtractMagnitudes(remainder, denominator)
        quotientDigit += 1
      }
      quotient.append(quotientDigit)
    }
    return (trimmingLeadingZeros(quotient), trimmingLeadingZeros(remainder))
  }

  private static func shouldRoundUp(
    quotient: [UInt8],
    remainder: [UInt8],
    denominator: [UInt8],
    sign: Int8,
    policy: RoundingPolicy
  ) -> Bool {
    let hasRemainder = remainder != [0]
    switch policy {
    case .towardZero: return false
    case .awayFromZero: return hasRemainder
    case .floor: return hasRemainder && sign < 0
    case .ceiling: return hasRemainder && sign > 0
    case .halfUp, .halfEven:
      guard hasRemainder else { return false }
      let comparison = compareMagnitudes(multiplyMagnitudes(remainder, [2]), denominator)
      if comparison == .descending { return true }
      if comparison == .ascending { return false }
      return policy == .halfUp || (quotient.last ?? 0) % 2 == 1
    }
  }
}
