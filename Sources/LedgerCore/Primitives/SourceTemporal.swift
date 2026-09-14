import Darwin
import Foundation

public enum SourceTemporalError: Error, Equatable, Sendable, CustomStringConvertible {
  case invalidDate
  case invalidTimeComponent(component: String, value: Int)
  case invalidMillisecond(Int)
  case instantOverflow
  case invalidTimeZoneIdentifier
  case timeZoneIdentifierTooLong(limit: Int, actualByteCount: Int)
  case invalidFixedOffset(Int)
  case nonexistentLocalTime
  case ambiguousLocalTime
  case precisionMismatch
  case inconsistentResolvedOffset

  public var description: String {
    switch self {
    case .invalidDate: "invalid Gregorian local date"
    case .invalidTimeComponent(let component, let value):
      "invalid \(component) component \(value)"
    case .invalidMillisecond(let value): "invalid millisecond component \(value)"
    case .instantOverflow: "UTC instant is outside the supported integer range"
    case .invalidTimeZoneIdentifier: "invalid IANA time-zone identifier"
    case .timeZoneIdentifierTooLong(let limit, let actualByteCount):
      "time-zone identifier exceeds \(limit) bytes (actual \(actualByteCount))"
    case .invalidFixedOffset(let value): "invalid fixed UTC offset \(value)"
    case .nonexistentLocalTime: "local time does not exist in the selected time zone"
    case .ambiguousLocalTime: "local time is ambiguous in the selected time zone"
    case .precisionMismatch: "local components exceed the declared temporal precision"
    case .inconsistentResolvedOffset:
      "instant, local value, and preserved resolved offset are inconsistent"
    }
  }
}

public struct UTCInstant: Codable, Hashable, Comparable, Sendable {
  public let epochMilliseconds: Int64

  public init(epochMilliseconds: Int64) {
    self.epochMilliseconds = epochMilliseconds
  }

  public init(seconds: Int64, millisecond: Int) throws {
    guard millisecond >= 0, millisecond < 1_000 else {
      throw SourceTemporalError.invalidMillisecond(millisecond)
    }
    let (scaled, scaleOverflow) = seconds.multipliedReportingOverflow(by: 1_000)
    let (combined, addOverflow) = scaled.addingReportingOverflow(Int64(millisecond))
    guard !scaleOverflow, !addOverflow else { throw SourceTemporalError.instantOverflow }
    epochMilliseconds = combined
  }

  public static func < (lhs: UTCInstant, rhs: UTCInstant) -> Bool {
    lhs.epochMilliseconds < rhs.epochMilliseconds
  }

  fileprivate var floorSecondAndMillisecond: (second: Int64, millisecond: Int64) {
    let quotient = epochMilliseconds / 1_000
    let remainder = epochMilliseconds % 1_000
    if remainder < 0 {
      return (quotient - 1, remainder + 1_000)
    }
    return (quotient, remainder)
  }

  /// Wall-clock components of an epoch-millisecond count using integer Gregorian arithmetic.
  /// The count is treated as a civil encoding, not as a binary-float UTC instant.
  public var civilComponents:
    (
      year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, millisecond: Int
    )
  {
    GregorianCivil.components(epochMilliseconds: epochMilliseconds)
  }

  public static func currentEpochMilliseconds() -> Int64 {
    var value = timespec()
    clock_gettime(CLOCK_REALTIME, &value)
    let seconds = Int64(value.tv_sec)
    let millis = Int64(value.tv_nsec / 1_000_000)
    return seconds &* 1_000 &+ millis
  }

  fileprivate var foundationDate: Date {
    let parts = floorSecondAndMillisecond
    if parts.millisecond == 0,
      let date = try? SourceTemporal.foundationDate(unixSeconds: parts.second)
    {
      return date
    }
    let value = Double(parts.second) + Double(parts.millisecond) / 1_000
    return Date(timeIntervalSince1970: value)
  }
}

/// Howard Hinnant's civil-from-days algorithm. Days and milliseconds stay integers.
public enum GregorianCivil {
  public static func components(epochMilliseconds: Int64) -> (
    year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, millisecond: Int
  ) {
    var seconds = epochMilliseconds / 1_000
    var millisecond = Int(epochMilliseconds % 1_000)
    if millisecond < 0 {
      seconds -= 1
      millisecond += 1_000
    }
    var days = seconds / 86_400
    var rem = seconds % 86_400
    if rem < 0 {
      days -= 1
      rem += 86_400
    }
    let hour = Int(rem / 3_600)
    rem %= 3_600
    let minute = Int(rem / 60)
    let second = Int(rem % 60)
    let z = days + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
    var year = Int(yoe) + Int(era) * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let day = Int(doy - (153 * mp + 2) / 5 + 1)
    let month = Int(mp < 10 ? mp + 3 : mp - 9)
    year += month <= 2 ? 1 : 0
    return (year, month, day, hour, minute, second, millisecond)
  }
}

public struct SourceLocalDate: Codable, Hashable, Comparable, Sendable {
  public let year: Int
  public let month: Int
  public let day: Int

  public init(year: Int, month: Int, day: Int) throws {
    guard year >= 1, year <= 9_999, month >= 1, month <= 12 else {
      throw SourceTemporalError.invalidDate
    }
    let maximumDay = Self.daysInMonth(year: year, month: month)
    guard day >= 1, day <= maximumDay else { throw SourceTemporalError.invalidDate }
    self.year = year
    self.month = month
    self.day = day
  }

  public static func < (lhs: SourceLocalDate, rhs: SourceLocalDate) -> Bool {
    (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
  }

  private static func daysInMonth(year: Int, month: Int) -> Int {
    switch month {
    case 2: return isLeapYear(year) ? 29 : 28
    case 4, 6, 9, 11: return 30
    default: return 31
    }
  }

  private static func isLeapYear(_ year: Int) -> Bool {
    year.isMultiple(of: 400) || (!year.isMultiple(of: 100) && year.isMultiple(of: 4))
  }

  private enum CodingKeys: String, CodingKey { case year, month, day }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let year = try container.decode(Int.self, forKey: .year)
    let month = try container.decode(Int.self, forKey: .month)
    let day = try container.decode(Int.self, forKey: .day)
    do {
      try self.init(year: year, month: month, day: day)
    } catch {
      throw DecodingError.dataCorruptedError(
        forKey: .day, in: container, debugDescription: "invalid Gregorian local date"
      )
    }
  }
}

public struct SourceLocalDateTime: Codable, Hashable, Comparable, Sendable {
  public let date: SourceLocalDate
  public let hour: Int
  public let minute: Int
  public let second: Int
  public let millisecond: Int

  public init(
    date: SourceLocalDate,
    hour: Int = 0,
    minute: Int = 0,
    second: Int = 0,
    millisecond: Int = 0
  ) throws {
    guard hour >= 0, hour < 24 else {
      throw SourceTemporalError.invalidTimeComponent(component: "hour", value: hour)
    }
    guard minute >= 0, minute < 60 else {
      throw SourceTemporalError.invalidTimeComponent(component: "minute", value: minute)
    }
    guard second >= 0, second < 60 else {
      throw SourceTemporalError.invalidTimeComponent(component: "second", value: second)
    }
    guard millisecond >= 0, millisecond < 1_000 else {
      throw SourceTemporalError.invalidMillisecond(millisecond)
    }
    self.date = date
    self.hour = hour
    self.minute = minute
    self.second = second
    self.millisecond = millisecond
  }

  public static func < (lhs: SourceLocalDateTime, rhs: SourceLocalDateTime) -> Bool {
    if lhs.date != rhs.date { return lhs.date < rhs.date }
    return (lhs.hour, lhs.minute, lhs.second, lhs.millisecond)
      < (rhs.hour, rhs.minute, rhs.second, rhs.millisecond)
  }

  private enum CodingKeys: String, CodingKey {
    case date, hour, minute, second, millisecond
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let date = try container.decode(SourceLocalDate.self, forKey: .date)
    let hour = try container.decode(Int.self, forKey: .hour)
    let minute = try container.decode(Int.self, forKey: .minute)
    let second = try container.decode(Int.self, forKey: .second)
    let millisecond = try container.decode(Int.self, forKey: .millisecond)
    do {
      try self.init(
        date: date, hour: hour, minute: minute, second: second,
        millisecond: millisecond
      )
    } catch {
      throw DecodingError.dataCorruptedError(
        forKey: .hour, in: container, debugDescription: "invalid local time"
      )
    }
  }
}

public struct SourceTimeZone: Codable, Hashable, Sendable {
  public static let maximumIdentifierBytes = 255
  public static let maximumFixedOffsetSeconds = 18 * 60 * 60

  public static let explicitSourceTimeZoneDisclosure =
    "Explicit source time zone required before import"

  private enum Storage: Hashable, Sendable {
    case iana(String)
    case fixedOffset(Int)
  }

  private let storage: Storage

  public init(ianaIdentifier: String) throws {
    try Self.validateIdentifierSyntax(ianaIdentifier)
    guard TimeZone(identifier: ianaIdentifier) != nil else {
      throw SourceTemporalError.invalidTimeZoneIdentifier
    }
    storage = .iana(ianaIdentifier)
  }

  fileprivate init(persistedIANAIdentifier: String) throws {
    try Self.validateIdentifierSyntax(persistedIANAIdentifier)
    storage = .iana(persistedIANAIdentifier)
  }

  public init(fixedOffsetSeconds: Int) throws {
    guard fixedOffsetSeconds >= -Self.maximumFixedOffsetSeconds,
      fixedOffsetSeconds <= Self.maximumFixedOffsetSeconds,
      fixedOffsetSeconds.isMultiple(of: 60),
      TimeZone(secondsFromGMT: fixedOffsetSeconds) != nil
    else {
      throw SourceTemporalError.invalidFixedOffset(fixedOffsetSeconds)
    }
    storage = .fixedOffset(fixedOffsetSeconds)
  }

  public var ianaIdentifier: String? {
    guard case .iana(let identifier) = storage else { return nil }
    return identifier
  }

  public var fixedOffsetSeconds: Int? {
    guard case .fixedOffset(let offset) = storage else { return nil }
    return offset
  }

  fileprivate var foundationValue: TimeZone? {
    switch storage {
    case .iana(let identifier): TimeZone(identifier: identifier)
    case .fixedOffset(let offset): TimeZone(secondsFromGMT: offset)
    }
  }

  private static func validateIdentifierSyntax(_ identifier: String) throws {
    let byteCount = BoundedUTF8.count(identifier, through: Self.maximumIdentifierBytes)
    guard byteCount <= Self.maximumIdentifierBytes else {
      throw SourceTemporalError.timeZoneIdentifierTooLong(
        limit: Self.maximumIdentifierBytes,
        actualByteCount: byteCount
      )
    }
    guard byteCount > 0 else { throw SourceTemporalError.invalidTimeZoneIdentifier }
    for byte in identifier.utf8 {
      let isLetter = (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
      let isDigit = byte >= 48 && byte <= 57
      let isPunctuation = byte == 43 || byte == 45 || byte == 46 || byte == 47 || byte == 95
      guard isLetter || isDigit || isPunctuation else {
        throw SourceTemporalError.invalidTimeZoneIdentifier
      }
    }
    let components = identifier.split(separator: "/", omittingEmptySubsequences: false)
    guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      throw SourceTemporalError.invalidTimeZoneIdentifier
    }
  }

  private enum Kind: String, Codable {
    case iana
    case fixedOffset

    private static let maximumRawValueBytes = 16

    init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      let rawValue = try container.decode(String.self)
      let byteCount = BoundedUTF8.count(rawValue, through: Self.maximumRawValueBytes)
      guard byteCount <= Self.maximumRawValueBytes, let value = Self(rawValue: rawValue) else {
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription: "invalid source time-zone kind"
        )
      }
      self = value
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      try container.encode(rawValue)
    }
  }
  private enum CodingKeys: String, CodingKey { case kind, identifier, offsetSeconds }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch storage {
    case .iana(let identifier):
      try container.encode(Kind.iana, forKey: .kind)
      try container.encode(identifier, forKey: .identifier)
    case .fixedOffset(let offset):
      try container.encode(Kind.fixedOffset, forKey: .kind)
      try container.encode(offset, forKey: .offsetSeconds)
    }
  }

  public init(from decoder: Decoder) throws {
    try self.init(from: decoder, permitUnavailableIANAIdentifier: false)
  }

  fileprivate init(persistedFrom decoder: Decoder) throws {
    try self.init(from: decoder, permitUnavailableIANAIdentifier: true)
  }

  private init(from decoder: Decoder, permitUnavailableIANAIdentifier: Bool) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(Kind.self, forKey: .kind)
    do {
      switch kind {
      case .iana:
        let identifier = try container.decode(String.self, forKey: .identifier)
        if permitUnavailableIANAIdentifier {
          try self.init(persistedIANAIdentifier: identifier)
        } else {
          try self.init(ianaIdentifier: identifier)
        }
      case .fixedOffset:
        try self.init(fixedOffsetSeconds: container.decode(Int.self, forKey: .offsetSeconds))
      }
    } catch {
      throw DecodingError.dataCorruptedError(
        forKey: kind == .iana ? .identifier : .offsetSeconds,
        in: container,
        debugDescription: "invalid validated source time zone"
      )
    }
  }
}

public enum SourceTemporalPrecision: String, Codable, CaseIterable, Sendable {
  case day
  case minute
  case second
  case millisecond

  private static let maximumRawValueBytes = 16

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(String.self)
    let byteCount = BoundedUTF8.count(rawValue, through: Self.maximumRawValueBytes)
    guard byteCount <= Self.maximumRawValueBytes, let value = Self(rawValue: rawValue) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "invalid source temporal precision"
      )
    }
    self = value
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public enum LocalTimeAmbiguityPolicy: String, Codable, CaseIterable, Sendable {
  case reject
  case earlier
  case later

  private static let maximumRawValueBytes = 16

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(String.self)
    let byteCount = BoundedUTF8.count(rawValue, through: Self.maximumRawValueBytes)
    guard byteCount <= Self.maximumRawValueBytes, let value = Self(rawValue: rawValue) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "invalid local-time ambiguity policy"
      )
    }
    self = value
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct SourceTemporal: Codable, Hashable, Sendable {
  public let instant: UTCInstant
  public let localDateTime: SourceLocalDateTime
  public let timeZone: SourceTimeZone
  public let precision: SourceTemporalPrecision
  public let resolvedOffsetSeconds: Int

  public var localDay: SourceLocalDate { localDateTime.date }

  public var timeZoneRulesDrifted: Bool {
    guard let foundationTimeZone = timeZone.foundationValue else { return true }
    return foundationTimeZone.secondsFromGMT(for: instant.foundationDate) != resolvedOffsetSeconds
  }

  public init(
    instant: UTCInstant,
    localDateTime: SourceLocalDateTime,
    timeZone: SourceTimeZone,
    precision: SourceTemporalPrecision,
    resolvedOffsetSeconds: Int
  ) throws {
    try Self.validatePrecision(localDateTime, precision: precision)
    guard resolvedOffsetSeconds >= -SourceTimeZone.maximumFixedOffsetSeconds,
      resolvedOffsetSeconds <= SourceTimeZone.maximumFixedOffsetSeconds
    else {
      throw SourceTemporalError.inconsistentResolvedOffset
    }
    if let fixedOffset = timeZone.fixedOffsetSeconds,
      fixedOffset != resolvedOffsetSeconds
    {
      throw SourceTemporalError.inconsistentResolvedOffset
    }
    let expected = try Self.instant(
      for: localDateTime, resolvedOffsetSeconds: resolvedOffsetSeconds
    )
    guard expected == instant else { throw SourceTemporalError.inconsistentResolvedOffset }

    self.instant = instant
    self.localDateTime = localDateTime
    self.timeZone = timeZone
    self.precision = precision
    self.resolvedOffsetSeconds = resolvedOffsetSeconds
  }

  /// Revalidates a persisted IANA-labelled instant without requiring the current OS tzdata
  /// to still contain that historical identifier. The exact stored offset and local/UTC
  /// relationship remain fully validated, including historical sub-minute offsets.
  public static func validatingPersistedIANA(
    instant: UTCInstant,
    localDateTime: SourceLocalDateTime,
    identifier: String,
    precision: SourceTemporalPrecision,
    resolvedOffsetSeconds: Int
  ) throws -> SourceTemporal {
    try SourceTemporal(
      instant: instant,
      localDateTime: localDateTime,
      timeZone: SourceTimeZone(persistedIANAIdentifier: identifier),
      precision: precision,
      resolvedOffsetSeconds: resolvedOffsetSeconds)
  }

  public init(
    resolving localDateTime: SourceLocalDateTime,
    in timeZone: SourceTimeZone,
    precision: SourceTemporalPrecision,
    ambiguityPolicy: LocalTimeAmbiguityPolicy = .reject
  ) throws {
    try Self.validatePrecision(localDateTime, precision: precision)
    let candidates = try Self.candidates(for: localDateTime, in: timeZone)
      .sorted { $0.instant < $1.instant }
    guard !candidates.isEmpty else { throw SourceTemporalError.nonexistentLocalTime }

    let selected: Candidate
    if candidates.count == 1 {
      selected = candidates[0]
    } else {
      switch ambiguityPolicy {
      case .reject: throw SourceTemporalError.ambiguousLocalTime
      case .earlier: selected = candidates[0]
      case .later: selected = candidates[candidates.count - 1]
      }
    }
    try self.init(
      instant: selected.instant,
      localDateTime: localDateTime,
      timeZone: timeZone,
      precision: precision,
      resolvedOffsetSeconds: selected.offset
    )
  }

  private struct Candidate: Hashable {
    let instant: UTCInstant
    let offset: Int
  }

  private static func validatePrecision(
    _ local: SourceLocalDateTime, precision: SourceTemporalPrecision
  ) throws {
    let valid: Bool
    switch precision {
    case .day:
      valid =
        local.hour == 0 && local.minute == 0 && local.second == 0
        && local.millisecond == 0
    case .minute:
      valid = local.second == 0 && local.millisecond == 0
    case .second:
      valid = local.millisecond == 0
    case .millisecond:
      valid = true
    }
    guard valid else { throw SourceTemporalError.precisionMismatch }
  }

  private static func instant(
    for local: SourceLocalDateTime, resolvedOffsetSeconds: Int
  ) throws -> UTCInstant {
    let naiveSeconds = try naiveEpochSeconds(for: local)
    let (offsetMilliseconds, offsetOverflow) = Int64(resolvedOffsetSeconds)
      .multipliedReportingOverflow(by: 1_000)
    let (naiveMilliseconds, naiveOverflow) = naiveSeconds.multipliedReportingOverflow(by: 1_000)
    let (withFraction, fractionOverflow) = naiveMilliseconds.addingReportingOverflow(
      Int64(local.millisecond)
    )
    let (resolved, resolvedOverflow) = withFraction.subtractingReportingOverflow(offsetMilliseconds)
    guard !offsetOverflow, !naiveOverflow, !fractionOverflow, !resolvedOverflow else {
      throw SourceTemporalError.instantOverflow
    }
    return UTCInstant(epochMilliseconds: resolved)
  }

  private static func naiveEpochSeconds(for local: SourceLocalDateTime) throws -> Int64 {
    let days = daysFromCivil(local.date)
    let (daySeconds, dayOverflow) = days.multipliedReportingOverflow(by: 86_400)
    let secondsWithinDay = Int64(local.hour * 3_600 + local.minute * 60 + local.second)
    let (result, addOverflow) = daySeconds.addingReportingOverflow(secondsWithinDay)
    guard !dayOverflow, !addOverflow else { throw SourceTemporalError.instantOverflow }
    return result
  }

  private static func daysFromCivil(_ date: SourceLocalDate) -> Int64 {
    var year = Int64(date.year)
    let month = Int64(date.month)
    let day = Int64(date.day)
    if month <= 2 { year -= 1 }
    let era = year / 400
    let yearOfEra = year - era * 400
    let adjustedMonth = month + (month > 2 ? -3 : 9)
    let dayOfYear = (153 * adjustedMonth + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
  }

  private static func civilDate(daysSinceEpoch input: Int64) throws -> SourceLocalDate {
    let shifted = input + 719_468
    let era = shifted >= 0 ? shifted / 146_097 : (shifted - 146_096) / 146_097
    let dayOfEra = shifted - era * 146_097
    let yearOfEra =
      (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
    var year = yearOfEra + era * 400
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
    let monthPrime = (5 * dayOfYear + 2) / 153
    let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
    let month = monthPrime + (monthPrime < 10 ? 3 : -9)
    if month <= 2 { year += 1 }
    guard year >= 1, year <= 9_999 else { throw SourceTemporalError.invalidDate }
    return try SourceLocalDate(year: Int(year), month: Int(month), day: Int(day))
  }

  private static func localDateTime(
    for instant: UTCInstant,
    resolvedOffsetSeconds: Int
  ) throws -> SourceLocalDateTime {
    let (offsetMilliseconds, offsetOverflow) = Int64(resolvedOffsetSeconds)
      .multipliedReportingOverflow(by: 1_000)
    let (localMilliseconds, addOverflow) = instant.epochMilliseconds.addingReportingOverflow(
      offsetMilliseconds
    )
    guard !offsetOverflow, !addOverflow else { throw SourceTemporalError.instantOverflow }

    let parts = UTCInstant(epochMilliseconds: localMilliseconds).floorSecondAndMillisecond
    let days = floorDividing(parts.second, by: 86_400)
    let secondsWithinDay = parts.second - days * 86_400
    let date = try civilDate(daysSinceEpoch: days)
    return try SourceLocalDateTime(
      date: date,
      hour: Int(secondsWithinDay / 3_600),
      minute: Int(secondsWithinDay % 3_600 / 60),
      second: Int(secondsWithinDay % 60),
      millisecond: Int(parts.millisecond)
    )
  }

  /// Foundation TimeZone only accepts Date. Whole unix seconds that round-trip through
  /// IEEE-754 binary64 are used; values that cannot are rejected rather than rounded.
  fileprivate static func foundationDate(unixSeconds: Int64) throws -> Date {
    let value = Double(unixSeconds)
    guard value.isFinite, Int64(value) == unixSeconds else {
      throw SourceTemporalError.instantOverflow
    }
    return Date(timeIntervalSince1970: value)
  }

  private static func floorDividing(_ dividend: Int64, by divisor: Int64) -> Int64 {
    let quotient = dividend / divisor
    let remainder = dividend % divisor
    return remainder < 0 ? quotient - 1 : quotient
  }

  private static func candidates(
    for local: SourceLocalDateTime, in sourceTimeZone: SourceTimeZone
  ) throws -> Set<Candidate> {
    guard let foundationTimeZone = sourceTimeZone.foundationValue else {
      throw SourceTemporalError.invalidTimeZoneIdentifier
    }
    let naiveSeconds = try naiveEpochSeconds(for: local)
    let offsets: Set<Int>
    if let fixedOffset = sourceTimeZone.fixedOffsetSeconds {
      offsets = [fixedOffset]
    } else {
      let probes: [Int64] = [0, -172_800, 172_800, -15_768_000, 15_768_000]
      offsets = Set(
        try probes.map { delta in
          let (sum, overflow) = naiveSeconds.addingReportingOverflow(delta)
          guard !overflow else { throw SourceTemporalError.instantOverflow }
          return foundationTimeZone.secondsFromGMT(for: try foundationDate(unixSeconds: sum))
        })
    }

    var matches: Set<Candidate> = []
    for offset in offsets {
      let instant = try instant(for: local, resolvedOffsetSeconds: offset)
      if try localDateTime(for: instant, resolvedOffsetSeconds: offset) == local,
        foundationTimeZone.secondsFromGMT(for: instant.foundationDate) == offset
      {
        matches.insert(Candidate(instant: instant, offset: offset))
      }
    }
    return matches
  }

  private enum CodingKeys: String, CodingKey {
    case instant, localDateTime, timeZone, precision, resolvedOffsetSeconds
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let instant = try container.decode(UTCInstant.self, forKey: .instant)
    let local = try container.decode(SourceLocalDateTime.self, forKey: .localDateTime)
    let timeZone: SourceTimeZone
    do {
      timeZone = try SourceTimeZone(
        persistedFrom: container.superDecoder(forKey: .timeZone)
      )
    } catch {
      throw DecodingError.dataCorruptedError(
        forKey: .timeZone,
        in: container,
        debugDescription: "invalid persisted source time zone"
      )
    }
    let precision = try container.decode(SourceTemporalPrecision.self, forKey: .precision)
    let offset = try container.decode(Int.self, forKey: .resolvedOffsetSeconds)
    do {
      try self.init(
        instant: instant,
        localDateTime: local,
        timeZone: timeZone,
        precision: precision,
        resolvedOffsetSeconds: offset
      )
    } catch {
      throw DecodingError.dataCorruptedError(
        forKey: .resolvedOffsetSeconds,
        in: container,
        debugDescription: "inconsistent preserved temporal projection"
      )
    }
  }
}
