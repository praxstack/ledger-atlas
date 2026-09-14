public enum CurrencyAmountError: Error, Equatable, Sendable, CustomStringConvertible {
  case unitCodeLengthOutOfRange(minimum: Int, maximum: Int, actualByteCount: Int)
  case invalidUnitCodeByte(position: Int)
  case unitMismatch

  public var description: String {
    switch self {
    case .unitCodeLengthOutOfRange(let minimum, let maximum, let actualByteCount):
      "currency unit must use \(minimum)...\(maximum) UTF-8 bytes (actual \(actualByteCount))"
    case .invalidUnitCodeByte(let position):
      "currency unit has an invalid byte at position \(position)"
    case .unitMismatch:
      "currency arithmetic requires identical units"
    }
  }
}

public struct CurrencyAmount: Codable, Hashable, Sendable {
  public static let minimumUnitCodeBytes = 3
  public static let maximumUnitCodeBytes = 16

  public let unitCode: String
  public let amount: ExactDecimal

  public init(unitCode: String, amount: ExactDecimal) throws {
    let byteCount = BoundedUTF8.count(unitCode, through: Self.maximumUnitCodeBytes)
    guard byteCount >= Self.minimumUnitCodeBytes,
      byteCount <= Self.maximumUnitCodeBytes
    else {
      throw CurrencyAmountError.unitCodeLengthOutOfRange(
        minimum: Self.minimumUnitCodeBytes,
        maximum: Self.maximumUnitCodeBytes,
        actualByteCount: byteCount
      )
    }

    let bytes = Array(unitCode.utf8)
    for (position, byte) in bytes.enumerated() {
      let isUppercaseLetter = byte >= 65 && byte <= 90
      let isDigit = byte >= 48 && byte <= 57
      guard isUppercaseLetter || isDigit else {
        throw CurrencyAmountError.invalidUnitCodeByte(position: position)
      }
    }
    guard let first = bytes.first, first >= 65, first <= 90 else {
      throw CurrencyAmountError.invalidUnitCodeByte(position: 0)
    }

    self.unitCode = unitCode
    self.amount = amount
  }

  public func adding(_ other: CurrencyAmount) throws -> CurrencyAmount {
    guard unitCode == other.unitCode else { throw CurrencyAmountError.unitMismatch }
    return try CurrencyAmount(unitCode: unitCode, amount: amount.adding(other.amount))
  }

  public func subtracting(_ other: CurrencyAmount) throws -> CurrencyAmount {
    guard unitCode == other.unitCode else { throw CurrencyAmountError.unitMismatch }
    return try CurrencyAmount(unitCode: unitCode, amount: amount.subtracting(other.amount))
  }

  private enum CodingKeys: String, CodingKey {
    case unitCode
    case amount
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let unitCode = try container.decode(String.self, forKey: .unitCode)
    let amount = try container.decode(ExactDecimal.self, forKey: .amount)
    do {
      try self.init(unitCode: unitCode, amount: amount)
    } catch {
      throw DecodingError.dataCorruptedError(
        forKey: .unitCode,
        in: container,
        debugDescription: "invalid bounded currency unit"
      )
    }
  }
}
