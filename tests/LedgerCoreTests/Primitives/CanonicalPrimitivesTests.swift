import Foundation
import LedgerCore
import Testing

@Test func exactDecimalPreservesSourceAndUsesExactArithmetic() throws {
  let value = try ExactDecimal("0012.3400")
  #expect(value.rawLiteral == "0012.3400")
  #expect(value.sourceScale == 4)
  #expect(value.description == "12.34")
  #expect(try value.adding(ExactDecimal("0.66")) == ExactDecimal("13"))
  #expect(try value.subtracting(ExactDecimal("2.34")) == ExactDecimal("10"))
  #expect(try value.multiplied(by: ExactDecimal("2.5")) == ExactDecimal("30.85"))
  #expect(
    try ExactDecimal("1").divided(by: ExactDecimal("8"), scale: 2, rounding: .halfEven)
      == ExactDecimal("0.12"))
  #expect(
    try ExactDecimal("1").divided(by: ExactDecimal("8"), scale: 2, rounding: .halfUp)
      == ExactDecimal("0.13"))
}

@Test func exactDecimalBoundaryIsClosedUnderIdentityOperations() throws {
  let literal = "0." + String(repeating: "0", count: ExactDecimal.maximumScale - 1) + "1"
  let boundary = try ExactDecimal(literal)
  #expect(try ExactDecimal(boundary.description) == boundary)
  #expect(try boundary.adding(ExactDecimal("0")) == boundary)
  #expect(try boundary.subtracting(ExactDecimal("0")) == boundary)
  #expect(try boundary.multiplied(by: ExactDecimal("1")) == boundary)

  let maximum = try ExactDecimal(String(repeating: "9", count: ExactDecimal.maximumDigits))
  #expect(try ExactDecimal(maximum.description) == maximum)
  #expect(try maximum.adding(ExactDecimal("0")) == maximum)
  #expect(try maximum.multiplied(by: ExactDecimal("1")) == maximum)
  #expect(throws: ExactDecimalError.self) { try maximum.adding(ExactDecimal("1")) }
  #expect(throws: ExactDecimalError.self) {
    try ExactDecimal("0." + String(repeating: "0", count: ExactDecimal.maximumScale) + "1")
  }
}

@Test func exactDecimalErrorsNeverEchoHostileLiteral() {
  let sentinel = "PRIVATE_SENTINEL_7c31" + String(repeating: "9", count: 500)
  do {
    _ = try ExactDecimal(sentinel)
    Issue.record("Expected invalid decimal")
  } catch {
    let rendered = String(describing: error) + String(reflecting: error)
    #expect(!rendered.contains("PRIVATE_SENTINEL_7c31"))
    #expect(rendered.count < 240)
  }
}

@Test func boundedPrimitiveInputsRejectSyntheticHugeStrings() throws {
  let huge = String(repeating: "A", count: 1_000_000)
  #expect(throws: ExactDecimalError.self) { try ExactDecimal(huge) }
  #expect(throws: CurrencyAmountError.self) {
    try CurrencyAmount(unitCode: huge, amount: ExactDecimal("1"))
  }
  #expect(throws: SourceTemporalError.self) {
    try SourceTimeZone(ianaIdentifier: huge)
  }
}

@Test func exactDecimalCodableRoundTripUsesAValidatedLiteral() throws {
  let original = try ExactDecimal("-42.500")
  let decoded = try JSONDecoder().decode(ExactDecimal.self, from: JSONEncoder().encode(original))
  #expect(decoded == original)
  #expect(decoded.rawLiteral == original.rawLiteral)
  #expect(decoded.sourceScale == 3)
}

@Test func exactDecimalRoundingIsSignAwareAndDivisionFailsLoudly() throws {
  let negative = try ExactDecimal("-1")
  let eight = try ExactDecimal("8")
  #expect(try negative.divided(by: eight, scale: 2, rounding: .towardZero) == ExactDecimal("-0.12"))
  #expect(
    try negative.divided(by: eight, scale: 2, rounding: .awayFromZero) == ExactDecimal("-0.13"))
  #expect(try negative.divided(by: eight, scale: 2, rounding: .floor) == ExactDecimal("-0.13"))
  #expect(try negative.divided(by: eight, scale: 2, rounding: .ceiling) == ExactDecimal("-0.12"))
  #expect(throws: ExactDecimalError.self) {
    try negative.divided(by: ExactDecimal("0"), scale: 2, rounding: .halfEven)
  }
}

@Test func currencyAmountRequiresBoundedValidatedUnitsAndMatchingArithmetic() throws {
  let lhs = try CurrencyAmount(unitCode: "USD", amount: ExactDecimal("10.25"))
  let rhs = try CurrencyAmount(unitCode: "USD", amount: ExactDecimal("1.75"))
  #expect(try lhs.adding(rhs).amount == ExactDecimal("12"))
  #expect(try lhs.subtracting(rhs).amount == ExactDecimal("8.5"))
  #expect(throws: CurrencyAmountError.self) {
    try lhs.adding(CurrencyAmount(unitCode: "EUR", amount: ExactDecimal("1")))
  }
  #expect(throws: CurrencyAmountError.self) {
    try CurrencyAmount(
      unitCode: String(repeating: "A", count: 1_000_000), amount: ExactDecimal("1"))
  }
}

@Test func sourceLocalDateRejectsImpossibleDirectAndCodableValues() throws {
  #expect(throws: SourceTemporalError.self) { try SourceLocalDate(year: 2025, month: 2, day: 31) }
  let hostile = Data(#"{"year":2025,"month":2,"day":31}"#.utf8)
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(SourceLocalDate.self, from: hostile)
  }
  let valid = try SourceLocalDate(year: 2024, month: 2, day: 29)
  #expect(
    try JSONDecoder().decode(SourceLocalDate.self, from: JSONEncoder().encode(valid)) == valid)
}

@Test func sourceTimeZoneCannotConstructOrDecodeInvalidValues() throws {
  #expect(throws: SourceTemporalError.self) {
    try SourceTimeZone(ianaIdentifier: "Mars/Olympus_Mons")
  }
  #expect(throws: SourceTemporalError.self) {
    try SourceTimeZone(fixedOffsetSeconds: 18 * 60 * 60 + 1)
  }
  #expect(throws: SourceTemporalError.self) {
    try SourceTimeZone(fixedOffsetSeconds: Int.min)
  }
  let hostileIANA = Data(#"{"kind":"iana","identifier":"Mars/Olympus_Mons"}"#.utf8)
  let hostileOffset = Data(#"{"kind":"fixedOffset","offsetSeconds":999999}"#.utf8)
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(SourceTimeZone.self, from: hostileIANA)
  }
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(SourceTimeZone.self, from: hostileOffset)
  }
  let hostileMinimumOffset = Data(
    #"{"kind":"fixedOffset","offsetSeconds":-9223372036854775808}"#.utf8
  )
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(SourceTimeZone.self, from: hostileMinimumOffset)
  }
  let values = [
    try SourceTimeZone(ianaIdentifier: "America/New_York"),
    try SourceTimeZone(fixedOffsetSeconds: 5 * 60 * 60 + 30 * 60),
  ]
  for value in values {
    #expect(
      try JSONDecoder().decode(SourceTimeZone.self, from: JSONEncoder().encode(value)) == value)
  }
}

@Test func sourceTemporalHandlesDSTGapsAndOverlapsExplicitly() throws {
  let zone = try SourceTimeZone(ianaIdentifier: "America/New_York")
  let gap = try SourceLocalDateTime(
    date: SourceLocalDate(year: 2025, month: 3, day: 9), hour: 2, minute: 30
  )
  #expect(throws: SourceTemporalError.self) {
    try SourceTemporal(resolving: gap, in: zone, precision: .minute)
  }

  let overlap = try SourceLocalDateTime(
    date: SourceLocalDate(year: 2025, month: 11, day: 2), hour: 1, minute: 30
  )
  #expect(throws: SourceTemporalError.self) {
    try SourceTemporal(resolving: overlap, in: zone, precision: .minute)
  }
  let earlier = try SourceTemporal(
    resolving: overlap, in: zone, precision: .minute, ambiguityPolicy: .earlier
  )
  let later = try SourceTemporal(
    resolving: overlap, in: zone, precision: .minute, ambiguityPolicy: .later
  )
  #expect(earlier.instant < later.instant)
  #expect(earlier.resolvedOffsetSeconds == -4 * 60 * 60)
  #expect(later.resolvedOffsetSeconds == -5 * 60 * 60)
}

@Test func sourceTemporalResolvesNegativeEpochSubsecondWithoutTruncation() throws {
  let local = try SourceLocalDateTime(
    date: SourceLocalDate(year: 1969, month: 12, day: 31),
    hour: 23,
    minute: 59,
    second: 59,
    millisecond: 999
  )
  let temporal = try SourceTemporal(
    resolving: local,
    in: SourceTimeZone(fixedOffsetSeconds: 0),
    precision: .millisecond
  )
  #expect(temporal.instant.epochMilliseconds == -1)
  #expect(!temporal.timeZoneRulesDrifted)
}

@Test func sourceTemporalDriftCheckUsesNegativeSubsecondInstant() throws {
  let local = try SourceLocalDateTime(
    date: SourceLocalDate(year: 1969, month: 10, day: 26),
    hour: 1,
    minute: 59,
    second: 59,
    millisecond: 999
  )
  let temporal = try SourceTemporal(
    instant: UTCInstant(epochMilliseconds: -5_767_200_001),
    localDateTime: local,
    timeZone: SourceTimeZone(ianaIdentifier: "America/New_York"),
    precision: .millisecond,
    resolvedOffsetSeconds: -4 * 60 * 60
  )
  #expect(!temporal.timeZoneRulesDrifted)
}

@Test func sourceTemporalUsesProlepticGregorianAcross1582Cutover() throws {
  let expectedEpochMilliseconds: [Int64] = [
    -12_220_111_503_211,
    -12_220_025_103_211,
    -12_219_938_703_211,
    -12_219_852_303_211,
    -12_219_765_903_211,
    -12_219_679_503_211,
    -12_219_593_103_211,
    -12_219_506_703_211,
    -12_219_420_303_211,
    -12_219_333_903_211,
  ]
  let utc = try SourceTimeZone(fixedOffsetSeconds: 0)

  for (index, expected) in expectedEpochMilliseconds.enumerated() {
    let local = try SourceLocalDateTime(
      date: SourceLocalDate(year: 1582, month: 10, day: index + 5),
      hour: 12,
      minute: 34,
      second: 56,
      millisecond: 789
    )
    let direct = try SourceTemporal(
      instant: UTCInstant(epochMilliseconds: expected),
      localDateTime: local,
      timeZone: utc,
      precision: .millisecond,
      resolvedOffsetSeconds: 0
    )
    #expect(direct.instant.epochMilliseconds == expected)

    let decoded = try JSONDecoder().decode(
      SourceTemporal.self,
      from: JSONEncoder().encode(direct)
    )
    #expect(decoded == direct)
    #expect(decoded.instant.epochMilliseconds == expected)

    let resolved = try SourceTemporal(
      resolving: local,
      in: utc,
      precision: .millisecond
    )
    #expect(resolved.instant.epochMilliseconds == expected)
  }

  let supportedBoundaries: [(SourceLocalDateTime, Int64)] = [
    (
      try SourceLocalDateTime(date: SourceLocalDate(year: 1, month: 1, day: 1)),
      -62_135_596_800_000
    ),
    (
      try SourceLocalDateTime(
        date: SourceLocalDate(year: 9_999, month: 12, day: 31),
        hour: 23,
        minute: 59,
        second: 59,
        millisecond: 999
      ),
      253_402_300_799_999
    ),
  ]
  for (local, expected) in supportedBoundaries {
    let resolved = try SourceTemporal(
      resolving: local,
      in: utc,
      precision: .millisecond
    )
    #expect(resolved.instant.epochMilliseconds == expected)
  }
}

@Test func sourceTemporalDecodingRetainsUnavailableHistoricalTimeZone() throws {
  let unavailableIdentifier = "Synthetic/Retired_Zone"
  #expect(throws: SourceTemporalError.self) {
    try SourceTimeZone(ianaIdentifier: unavailableIdentifier)
  }
  let standalonePayload = Data(
    #"{"kind":"iana","identifier":"Synthetic/Retired_Zone"}"#.utf8
  )
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(SourceTimeZone.self, from: standalonePayload)
  }

  let payload = Data(
    #"{"instant":{"epochMilliseconds":1736958645125},"localDateTime":{"date":{"year":2025,"month":1,"day":15},"hour":12,"minute":30,"second":45,"millisecond":125},"timeZone":{"kind":"iana","identifier":"Synthetic/Retired_Zone"},"precision":"millisecond","resolvedOffsetSeconds":-14400}"#
      .utf8
  )
  let temporal = try JSONDecoder().decode(SourceTemporal.self, from: payload)
  #expect(temporal.timeZone.ianaIdentifier == unavailableIdentifier)
  #expect(temporal.resolvedOffsetSeconds == -4 * 60 * 60)
  #expect(temporal.timeZoneRulesDrifted)

  let roundTripped = try JSONDecoder().decode(
    SourceTemporal.self,
    from: JSONEncoder().encode(temporal)
  )
  #expect(roundTripped == temporal)

  let sentinel = "PRIVATE_SENTINEL_IANA_913a"
  let malformed = Data(
    #"{"instant":{"epochMilliseconds":1736958645125},"localDateTime":{"date":{"year":2025,"month":1,"day":15},"hour":12,"minute":30,"second":45,"millisecond":125},"timeZone":{"kind":"iana","identifier":"Synthetic//PRIVATE_SENTINEL_IANA_913a Zone"},"precision":"millisecond","resolvedOffsetSeconds":-14400}"#
      .utf8
  )
  do {
    _ = try JSONDecoder().decode(SourceTemporal.self, from: malformed)
    Issue.record("Expected malformed persisted time-zone identifier")
  } catch {
    let rendered = String(describing: error) + String(reflecting: error)
    #expect(!rendered.contains(sentinel))
    #expect(rendered.count < 400)
  }
}

@Test func primitiveEnumDecodingDoesNotEchoHostileRawValues() {
  let sentinel = "PRIVATE_SENTINEL_ENUM_4f02"
  let payloads: [(String, () throws -> Void)] = [
    (
      "rounding",
      { _ = try JSONDecoder().decode(RoundingPolicy.self, from: Data("\"\(sentinel)\"".utf8)) }
    ),
    (
      "precision",
      {
        _ = try JSONDecoder().decode(
          SourceTemporalPrecision.self, from: Data("\"\(sentinel)\"".utf8))
      }
    ),
    (
      "ambiguity",
      {
        _ = try JSONDecoder().decode(
          LocalTimeAmbiguityPolicy.self, from: Data("\"\(sentinel)\"".utf8))
      }
    ),
    (
      "time-zone kind",
      {
        _ = try JSONDecoder().decode(
          SourceTimeZone.self,
          from: Data("{\"kind\":\"\(sentinel)\",\"identifier\":\"UTC\"}".utf8)
        )
      }
    ),
  ]

  for (name, decode) in payloads {
    do {
      try decode()
      Issue.record("Expected invalid \(name) raw value")
    } catch {
      let rendered = String(describing: error) + String(reflecting: error)
      #expect(!rendered.contains(sentinel))
      #expect(rendered.count < 400)
    }
  }
}

@Test func sourceTemporalPersistsResolvedOffsetProvenance() throws {
  let local = try SourceLocalDateTime(
    date: SourceLocalDate(year: 2025, month: 1, day: 15),
    hour: 12, minute: 30, second: 45, millisecond: 125
  )
  let zone = try SourceTimeZone(ianaIdentifier: "America/New_York")
  let temporal = try SourceTemporal(
    resolving: local, in: zone, precision: .millisecond, ambiguityPolicy: .reject
  )
  #expect(temporal.resolvedOffsetSeconds == -5 * 60 * 60)
  #expect(temporal.localDay == local.date)
  #expect(!temporal.timeZoneRulesDrifted)
  let data = try JSONEncoder().encode(temporal)
  let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect(json["resolvedOffsetSeconds"] as? Int == -5 * 60 * 60)
  let decoded = try JSONDecoder().decode(SourceTemporal.self, from: data)
  #expect(decoded == temporal)
  #expect(decoded.resolvedOffsetSeconds == temporal.resolvedOffsetSeconds)
  #expect(decoded.timeZone == zone)
}

@Test func sourceTemporalRejectsTamperedOffsetProvenance() {
  let hostile = Data(
    #"{"instant":{"epochMilliseconds":1736958645125},"localDateTime":{"date":{"year":2025,"month":1,"day":15},"hour":12,"minute":30,"second":45,"millisecond":125},"timeZone":{"kind":"iana","identifier":"America/New_York"},"precision":"millisecond","resolvedOffsetSeconds":0}"#
      .utf8)
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(SourceTemporal.self, from: hostile)
  }
}

@Test func utcInstantChecksMillisecondAndOverflowBounds() throws {
  #expect(try UTCInstant(seconds: 1, millisecond: 2).epochMilliseconds == 1_002)
  #expect(throws: SourceTemporalError.self) { try UTCInstant(seconds: 0, millisecond: 1_000) }
  #expect(throws: SourceTemporalError.self) { try UTCInstant(seconds: Int64.max, millisecond: 0) }
}
