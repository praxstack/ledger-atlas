import Foundation
import LedgerCore
import Testing

@Suite("Ledger schedule")
struct LedgerScheduleTests {
  private static func date(_ year: Int, _ month: Int, _ day: Int) throws -> SourceLocalDate {
    try SourceLocalDate(year: year, month: month, day: day)
  }

  private static func rule(
    _ frequency: LedgerRecurrenceFrequency, start: SourceLocalDate, interval: Int = 1,
    dayOfMonth: Int? = nil, until: SourceLocalDate? = nil, skipped: [SourceLocalDate] = []
  ) throws -> LedgerRecurrenceRule {
    let origin = try LedgerOrigin(id: String(repeating: "1", count: 64), label: "local")
    return try LedgerRecurrenceRule(
      id: String(repeating: "2", count: 64), origin: origin,
      accountID: String(repeating: "a", count: 64), categoryID: nil, kind: .expense,
      amount: CurrencyAmount(unitCode: "USD", amount: ExactDecimal("1")), frequency: frequency,
      interval: interval, dayOfMonth: dayOfMonth, timeZone: SourceTimeZone(fixedOffsetSeconds: 0),
      start: start, until: until, skippedDates: skipped)
  }

  @Test("month-end anchors do not drift (LA-030)")
  func monthEndDoesNotDrift() throws {
    let dates = try LedgerSchedule.dates(
      for: Self.rule(.monthly, start: Self.date(2026, 1, 31)), through: Self.date(2026, 6, 30))
    #expect(dates.map(\.day) == [31, 28, 31, 30, 31, 30])
    let leap = try LedgerSchedule.dates(
      for: Self.rule(.yearly, start: Self.date(2024, 2, 29)), through: Self.date(2028, 12, 31))
    #expect(leap.map { "\($0.year)-\($0.month)-\($0.day)" }
      == ["2024-2-29", "2025-2-28", "2026-2-28", "2027-2-28", "2028-2-29"])
    let pinned = try LedgerSchedule.dates(
      for: Self.rule(.monthly, start: Self.date(2026, 1, 15), interval: 2, dayOfMonth: 30),
      through: Self.date(2026, 7, 31))
    #expect(pinned.map { "\($0.month)-\($0.day)" } == ["1-30", "3-30", "5-30", "7-30"])
  }

  @Test("daily and weekly steps cross months, years and leap days")
  func dailyAndWeekly() throws {
    #expect(
      try LedgerSchedule.addingDays(1, to: Self.date(2024, 2, 28)) == Self.date(2024, 2, 29))
    #expect(
      try LedgerSchedule.addingDays(366, to: Self.date(2024, 1, 1)) == Self.date(2025, 1, 1))
    #expect(
      try LedgerSchedule.addingDays(-1, to: Self.date(2026, 1, 1)) == Self.date(2025, 12, 31))
    let weekly = try LedgerSchedule.dates(
      for: Self.rule(.weekly, start: Self.date(2026, 12, 24), interval: 1),
      through: Self.date(2027, 1, 14))
    #expect(weekly.map { "\($0.month)-\($0.day)" } == ["12-24", "12-31", "1-7", "1-14"])
  }

  @Test("until and skipped dates are honoured")
  func untilAndSkipped() throws {
    let dates = try LedgerSchedule.dates(
      for: Self.rule(
        .daily, start: Self.date(2026, 3, 1), until: Self.date(2026, 3, 5),
        skipped: [Self.date(2026, 3, 3)]),
      through: Self.date(2026, 12, 31))
    #expect(dates.map(\.day) == [1, 2, 4, 5])
    #expect(
      try LedgerSchedule.dates(
        for: Self.rule(.daily, start: Self.date(2026, 3, 1)), through: Self.date(2026, 2, 1))
        .isEmpty)
  }

  @Test("long catch-ups are allowed up to the bound (LA-028)")
  func longCatchUp() throws {
    let threeYears = try LedgerSchedule.dates(
      for: Self.rule(.daily, start: Self.date(2023, 1, 1)), through: Self.date(2025, 12, 31))
    #expect(threeYears.count == 1_096)
    #expect(throws: LedgerCommandError.recurrenceRangeTooLong) {
      try LedgerSchedule.dates(
        for: Self.rule(.daily, start: Self.date(1900, 1, 1)), through: Self.date(2026, 1, 1))
    }
  }

  @Test("a day whose midnight is skipped by DST still has a start (LA-029)")
  func dstGapAtMidnight() throws {
    // Havana springs forward at 00:00 on 8 March 2026, so 00:00 does not exist that day.
    let havana = try SourceTimeZone(ianaIdentifier: "America/Havana")
    let gapDay = try Self.date(2026, 3, 8)
    #expect(throws: SourceTemporalError.nonexistentLocalTime) {
      try SourceTemporal(
        resolving: SourceLocalDateTime(date: gapDay), in: havana, precision: .day)
    }
    let start = try SourceTemporal(startOf: gapDay, in: havana)
    #expect(start.localDay == gapDay)
    #expect(start.precision == .day)
    // The day starts at the jump: 05:00 UTC, which is 01:00 local after the change.
    #expect(start.instant.epochMilliseconds % 86_400_000 == 5 * 3_600_000)
    // Ordinary days resolve exactly as before.
    let ordinary = try Self.date(2026, 3, 9)
    #expect(
      try SourceTemporal(startOf: ordinary, in: havana)
        == SourceTemporal(
          resolving: SourceLocalDateTime(date: ordinary), in: havana, precision: .day))
    // A day that was skipped entirely still has no start.
    let apia = try SourceTimeZone(ianaIdentifier: "Pacific/Apia")
    #expect(throws: SourceTemporalError.nonexistentLocalTime) {
      try SourceTemporal(startOf: Self.date(2011, 12, 30), in: apia)
    }
  }
}
