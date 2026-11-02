import Foundation

/// Calendar math for recurrences and installments. Every occurrence is computed from the anchor
/// date, never from the previous occurrence, so a month-end anchor does not drift
/// (31 Jan → 28 Feb → 31 Mar, not → 28 Mar).
public enum LedgerSchedule {
  /// Upper bound on occurrences produced by one catch-up (about 54 years of a daily rule).
  public static let maximumOccurrences = 20_000

  /// The `index`-th occurrence (0 is the anchor itself).
  public static func occurrence(
    _ index: Int, from anchor: SourceLocalDate, frequency: LedgerRecurrenceFrequency,
    interval: Int, dayOfMonth: Int? = nil
  ) throws -> SourceLocalDate {
    guard index >= 0, interval > 0 else { throw LedgerCommandError.invalidRecurrence }
    let (steps, overflow) = index.multipliedReportingOverflow(by: interval)
    guard !overflow else { throw LedgerCommandError.recurrenceRangeTooLong }
    switch frequency {
    case .daily:
      return try addingDays(steps, to: anchor)
    case .weekly:
      let (days, overflow) = steps.multipliedReportingOverflow(by: 7)
      guard !overflow else { throw LedgerCommandError.recurrenceRangeTooLong }
      return try addingDays(days, to: anchor)
    case .monthly, .yearly:
      let (months, overflow) =
        frequency == .monthly ? (steps, false) : steps.multipliedReportingOverflow(by: 12)
      guard !overflow, months <= 12 * 10_000 else {
        throw LedgerCommandError.recurrenceRangeTooLong
      }
      let total = anchor.year * 12 + (anchor.month - 1) + months
      let year = total / 12
      let month = total % 12 + 1
      guard year <= 9_999 else { throw LedgerCommandError.recurrenceRangeTooLong }
      let wanted = dayOfMonth ?? anchor.day
      return try SourceLocalDate(
        year: year, month: month, day: min(wanted, daysInMonth(year: year, month: month)))
    }
  }

  /// Dates the rule produces from its start through `end`, honouring `until` and skipped dates.
  public static func dates(for rule: LedgerRecurrenceRule, through end: SourceLocalDate) throws
    -> [SourceLocalDate]
  {
    var result: [SourceLocalDate] = []
    let skipped = Set(rule.skippedDates)
    let last = rule.until.map { min($0, end) } ?? end
    var index = 0
    while true {
      let date = try occurrence(
        index, from: rule.start, frequency: rule.frequency, interval: rule.interval,
        dayOfMonth: rule.dayOfMonth)
      if date > last { break }
      guard index < maximumOccurrences else { throw LedgerCommandError.recurrenceRangeTooLong }
      if !skipped.contains(date) { result.append(date) }
      index += 1
    }
    return result
  }

  public static func addingDays(_ days: Int, to date: SourceLocalDate) throws -> SourceLocalDate {
    let (day, overflow) = dayNumber(date).addingReportingOverflow(days)
    guard !overflow else { throw LedgerCommandError.recurrenceRangeTooLong }
    let civil = civilDate(fromDayNumber: day)
    guard civil.year >= 1, civil.year <= 9_999 else {
      throw LedgerCommandError.recurrenceRangeTooLong
    }
    return try SourceLocalDate(year: civil.year, month: civil.month, day: civil.day)
  }

  public static func daysInMonth(year: Int, month: Int) -> Int {
    switch month {
    case 2:
      let leap = year.isMultiple(of: 400) || (!year.isMultiple(of: 100) && year.isMultiple(of: 4))
      return leap ? 29 : 28
    case 4, 6, 9, 11: return 30
    default: return 31
    }
  }

  /// Days since 1970-01-01 in the proleptic Gregorian calendar (Howard Hinnant's algorithm).
  static func dayNumber(_ date: SourceLocalDate) -> Int {
    let year = date.month <= 2 ? date.year - 1 : date.year
    let era = (year >= 0 ? year : year - 399) / 400
    let yearOfEra = year - era * 400
    let shiftedMonth = date.month > 2 ? date.month - 3 : date.month + 9
    let dayOfYear = (153 * shiftedMonth + 2) / 5 + date.day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
  }

  static func civilDate(fromDayNumber number: Int) -> (year: Int, month: Int, day: Int) {
    let shifted = number + 719_468
    let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
    let dayOfEra = shifted - era * 146_097
    let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
    let shiftedMonth = (5 * dayOfYear + 2) / 153
    let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
    let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
    return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
  }
}
