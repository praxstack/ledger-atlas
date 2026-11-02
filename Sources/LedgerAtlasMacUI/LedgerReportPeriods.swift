import Foundation
import LedgerCore

/// A half-open range of civil dates: `start` is included, `end` is not.
public struct LedgerLocalDateRange: Equatable, Hashable, Sendable {
  public let start: SourceLocalDate
  public let end: SourceLocalDate

  public func contains(_ date: SourceLocalDate) -> Bool { start <= date && date < end }
}

/// Report period boundaries (MACV2-13).
///
/// Boundaries are computed on civil dates (year, month, day), never on instants. A
/// transaction stored as 25 Oct stays in the same period when the Mac's locale or time
/// zone changes. Only "today" depends on a time zone, and callers pass it explicitly.
public struct LedgerPeriodRule: Equatable, Hashable, Sendable {
  /// 1…31. A month shorter than this starts its period on its last day.
  public let monthStartDay: Int
  /// 1 = Sunday … 7 = Saturday.
  public let firstWeekday: Int

  public init(monthStartDay: Int = 1, firstWeekday: Int = 1) {
    self.monthStartDay = min(max(monthStartDay, 1), 31)
    self.firstWeekday = min(max(firstWeekday, 1), 7)
  }

  /// The monthly period that contains `date`.
  public func monthPeriod(containing date: SourceLocalDate) -> LedgerLocalDateRange {
    let thisStart = monthStart(year: date.year, month: date.month)
    if date >= thisStart {
      let (year, month) = Self.adding(months: 1, toYear: date.year, month: date.month)
      return LedgerLocalDateRange(start: thisStart, end: monthStart(year: year, month: month))
    }
    let (year, month) = Self.adding(months: -1, toYear: date.year, month: date.month)
    return LedgerLocalDateRange(start: monthStart(year: year, month: month), end: thisStart)
  }

  public func monthPeriod(after period: LedgerLocalDateRange) -> LedgerLocalDateRange {
    monthPeriod(containing: period.end)
  }

  public func monthPeriod(before period: LedgerLocalDateRange) -> LedgerLocalDateRange {
    monthPeriod(containing: Self.date(fromDays: Self.days(from: period.start) - 1))
  }

  /// The seven-day week that contains `date`, starting on `firstWeekday`.
  public func weekPeriod(containing date: SourceLocalDate) -> LedgerLocalDateRange {
    let days = Self.days(from: date)
    let back = (Self.weekday(ofDays: days) - firstWeekday + 7) % 7
    return LedgerLocalDateRange(
      start: Self.date(fromDays: days - back), end: Self.date(fromDays: days - back + 7))
  }

  /// The civil date of `instant` in `timeZone`. This is the only time-zone-dependent step.
  public static func today(in timeZone: TimeZone, now instant: Date = Date()) -> SourceLocalDate {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let parts = calendar.dateComponents([.year, .month, .day], from: instant)
    // Gregorian components from Calendar are always a valid date.
    return try! SourceLocalDate(year: parts.year!, month: parts.month!, day: parts.day!)
  }

  /// 1 = Sunday … 7 = Saturday.
  public static func weekday(of date: SourceLocalDate) -> Int { weekday(ofDays: days(from: date)) }

  private func monthStart(year: Int, month: Int) -> SourceLocalDate {
    let day = min(monthStartDay, Self.daysInMonth(year: year, month: month))
    return try! SourceLocalDate(year: year, month: month, day: day)
  }

  // MARK: Civil-date arithmetic (proleptic Gregorian, days since 1970-01-01)

  static func days(from date: SourceLocalDate) -> Int {
    let y = date.month <= 2 ? date.year - 1 : date.year
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let mp = (date.month + 9) % 12
    let doy = (153 * mp + 2) / 5 + date.day - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146_097 + doe - 719_468
  }

  static func date(fromDays days: Int) -> SourceLocalDate {
    let z = days + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let day = doy - (153 * mp + 2) / 5 + 1
    let month = mp < 10 ? mp + 3 : mp - 9
    let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
    return try! SourceLocalDate(year: year, month: month, day: day)
  }

  private static func weekday(ofDays days: Int) -> Int {
    // 1970-01-01 was a Thursday (5 in Sunday-first numbering).
    ((days % 7 + 7 + 4) % 7) + 1
  }

  static func daysInMonth(year: Int, month: Int) -> Int {
    switch month {
    case 2: (year.isMultiple(of: 400) || (!year.isMultiple(of: 100) && year.isMultiple(of: 4))) ? 29 : 28
    case 4, 6, 9, 11: 30
    default: 31
    }
  }

  private static func adding(months: Int, toYear year: Int, month: Int) -> (Int, Int) {
    let index = year * 12 + (month - 1) + months
    return (index / 12, index % 12 + 1)
  }
}
