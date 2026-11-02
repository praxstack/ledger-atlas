import Foundation
import LedgerCore
import Testing

#if canImport(SwiftUI)
  import SwiftUI
#endif

@testable import LedgerAtlasMacUI

private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
  let suite = "LedgerAtlasMacUITests.settings.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  try body(defaults)
}

private func day(_ year: Int, _ month: Int, _ day: Int) -> SourceLocalDate {
  try! SourceLocalDate(year: year, month: month, day: day)
}

@Test func productSettingsPersistTypedPresentationAndPeriodValues() {
  withDefaults { defaults in
    let original = LedgerProductSettings(
      appearance: .dark, localeIdentifier: "de_DE", timeZoneIdentifier: "Asia/Kolkata",
      firstWeekday: 2, periodStartDay: 25, startScreen: .insights,
      amountColors: .monochrome, carryOverEnabled: true, motion: .reduced,
      remindersEnabled: true, reminderHour: 21)
    original.save(to: defaults)
    let loaded = LedgerProductSettings.load(from: defaults)
    #expect(loaded == original)
    #expect(loaded.periodRule == LedgerPeriodRule(monthStartDay: 25, firstWeekday: 2))
    #expect(loaded.timeZone.identifier == "Asia/Kolkata")
    #expect(loaded.reduceMotion(systemReduceMotion: false))
    #expect(LedgerProductSettings().reduceMotion(systemReduceMotion: true))
    #expect(!LedgerProductSettings().reduceMotion(systemReduceMotion: false))
    #if canImport(SwiftUI)
      #expect(loaded.colorScheme == .dark)
      #expect(LedgerProductSettings().colorScheme == nil)
    #endif
  }
}

@Test func productSettingsDecodeOlderAndDamagedValuesFieldByField() throws {
  // A v1 payload (before start screen, colours, carry-over…) keeps its values.
  let v1 = Data(
    #"{"appearance":"dark","localeIdentifier":"en_GB","firstWeekday":2,"periodStartDay":25,"remindersEnabled":true}"#
      .utf8)
  let upgraded = try JSONDecoder().decode(LedgerProductSettings.self, from: v1)
  #expect(upgraded.appearance == .dark && upgraded.localeIdentifier == "en_GB")
  #expect(upgraded.firstWeekday == 2 && upgraded.periodStartDay == 25 && upgraded.remindersEnabled)
  #expect(upgraded.startScreen == .ledger && upgraded.reminderHour == 9 && upgraded.timeZoneIdentifier == nil)

  // One bad field falls back alone; the others survive.
  let damaged = Data(
    #"{"appearance":"neon","localeIdentifier":"xx_NOPE","timeZoneIdentifier":"Mars/Base","firstWeekday":9,"periodStartDay":40,"startScreen":"settings","reminderHour":30,"carryOverEnabled":true}"#
      .utf8)
  let repaired = try JSONDecoder().decode(LedgerProductSettings.self, from: damaged)
  #expect(repaired == LedgerProductSettings(carryOverEnabled: true))
}

@Test func invalidSettingsKeepTheLastKnownGoodValueAndNameTheFieldToFocus() {
  var settings = LedgerProductSettings(localeIdentifier: "en_GB", periodStartDay: 25)
  let lastGood = settings

  var candidate = settings
  candidate.periodStartDay = 0
  candidate.localeIdentifier = "de_DE"
  #expect(settings.apply(candidate) == .periodStartDay)
  #expect(settings == lastGood)

  candidate = settings
  candidate.timeZoneIdentifier = "Not/AZone"
  #expect(candidate.validationErrors()[.timeZoneIdentifier] != nil)
  #expect(settings.apply(candidate) == .timeZoneIdentifier)

  candidate = settings
  candidate.localeIdentifier = ""
  candidate.reminderHour = 24
  #expect(candidate.firstInvalidField == .localeIdentifier)
  #expect(Set(candidate.validationErrors().keys) == [.localeIdentifier, .reminderHour])

  candidate = settings
  candidate.startScreen = .onboarding
  #expect(settings.apply(candidate) == .startScreen)
  #expect(settings == lastGood)

  candidate = settings
  candidate.localeIdentifier = "ja_JP"
  candidate.periodStartDay = 31
  #expect(settings.apply(candidate) == nil)
  #expect(settings.localeIdentifier == "ja_JP" && settings.periodStartDay == 31)

  // Saving an invalid value is refused, so the stored copy stays the last good one.
  withDefaults { defaults in
    settings.save(to: defaults)
    var invalid = settings
    invalid.reminderHour = 99
    invalid.save(to: defaults)
    #expect(LedgerProductSettings.load(from: defaults) == settings)
  }
}

@Test func monthPeriodsHonourTheStartDayAndClampShortMonths() {
  let rule = LedgerPeriodRule(monthStartDay: 25)
  #expect(rule.monthPeriod(containing: day(2026, 11, 2)) == .init(start: day(2026, 10, 25), end: day(2026, 11, 25)))
  #expect(rule.monthPeriod(containing: day(2026, 11, 25)) == .init(start: day(2026, 11, 25), end: day(2026, 12, 25)))
  #expect(rule.monthPeriod(containing: day(2026, 12, 31)) == .init(start: day(2026, 12, 25), end: day(2027, 1, 25)))
  #expect(rule.monthPeriod(containing: day(2027, 1, 1)) == .init(start: day(2026, 12, 25), end: day(2027, 1, 25)))

  let calendarMonth = LedgerPeriodRule()
  #expect(
    calendarMonth.monthPeriod(containing: day(2026, 2, 28)) == .init(start: day(2026, 2, 1), end: day(2026, 3, 1)))

  // Start day 31: February starts on its last day, and periods still tile with no gaps.
  let late = LedgerPeriodRule(monthStartDay: 31)
  #expect(late.monthPeriod(containing: day(2028, 3, 1)) == .init(start: day(2028, 2, 29), end: day(2028, 3, 31)))
  #expect(late.monthPeriod(containing: day(2026, 2, 27)) == .init(start: day(2026, 1, 31), end: day(2026, 2, 28)))
  var period = late.monthPeriod(containing: day(2026, 1, 15))
  for _ in 0..<36 {
    let next = late.monthPeriod(after: period)
    #expect(next.start == period.end)
    #expect(late.monthPeriod(before: next) == period)
    period = next
  }
}

@Test func weekPeriodsStartOnTheChosenWeekday() {
  // 2 Nov 2026 is a Monday.
  #expect(LedgerPeriodRule.weekday(of: day(2026, 11, 2)) == 2)
  #expect(LedgerPeriodRule.weekday(of: day(1970, 1, 1)) == 5)
  #expect(LedgerPeriodRule.weekday(of: day(2000, 2, 29)) == 3)
  let sunday = LedgerPeriodRule(firstWeekday: 1)
  let monday = LedgerPeriodRule(firstWeekday: 2)
  #expect(sunday.weekPeriod(containing: day(2026, 11, 2)) == .init(start: day(2026, 11, 1), end: day(2026, 11, 8)))
  #expect(monday.weekPeriod(containing: day(2026, 11, 1)) == .init(start: day(2026, 10, 26), end: day(2026, 11, 2)))
  #expect(monday.weekPeriod(containing: day(2027, 1, 1)) == .init(start: day(2026, 12, 28), end: day(2027, 1, 4)))
}

@Test func storedPeriodBoundariesIgnoreTheMacsTimeZone() {
  // Same stored civil date, different machine time zones: identical boundaries.
  let rule = LedgerPeriodRule(monthStartDay: 25, firstWeekday: 2)
  let stored = day(2026, 10, 25)
  var results: Set<LedgerLocalDateRange> = []
  let original = NSTimeZone.default
  defer { NSTimeZone.default = original }
  for zone in ["Pacific/Kiritimati", "Asia/Kolkata", "UTC", "America/Los_Angeles", "Pacific/Pago_Pago"] {
    NSTimeZone.default = TimeZone(identifier: zone)!
    results.insert(rule.monthPeriod(containing: stored))
    #expect(LedgerDisplayFormatter(locale: Locale(identifier: "en_US")).date(stored, style: .short) == "10/25/26")
  }
  #expect(results.count == 1)

  // Only "today" depends on the zone, and only through an explicit argument.
  let instant = Date(timeIntervalSince1970: 1_793_490_600)  // 2026-10-31T23:50:00Z
  #expect(LedgerPeriodRule.today(in: TimeZone(identifier: "UTC")!, now: instant) == day(2026, 10, 31))
  #expect(LedgerPeriodRule.today(in: TimeZone(identifier: "Asia/Kolkata")!, now: instant) == day(2026, 11, 1))

  // Civil-day arithmetic round-trips from year 1 to 9999.
  for offset in stride(from: -719_162, through: 2_932_896, by: 997) {
    #expect(LedgerPeriodRule.days(from: LedgerPeriodRule.date(fromDays: offset)) == offset)
  }
}

@Test func displayFormattingIsLocalisedOneWayAndNeverRounds() throws {
  let amount = try CurrencyAmount(unitCode: "EUR", amount: ExactDecimal("1234.5"))
  let german = LedgerDisplayFormatter(locale: Locale(identifier: "de_DE")).amount(amount)
  let american = LedgerDisplayFormatter(locale: Locale(identifier: "en_US")).amount(amount)
  #expect(german.contains("1.234,50"))
  #expect(american.contains("1,234.50"))
  // The display string is not a canonical literal, which is why nothing parses it back.
  #expect(throws: (any Error).self) { try ExactDecimal(german) }
  #expect(amount.amount.description == "1234.5")

  // Extra canonical precision is shown, not rounded away.
  let precise = try CurrencyAmount(unitCode: "INR", amount: ExactDecimal("10.125"))
  #expect(LedgerDisplayFormatter(locale: Locale(identifier: "en_IN")).amount(precise).contains("10.125"))

  // Longer than Decimal can hold: shown verbatim with its unit.
  let huge = try CurrencyAmount(unitCode: "USD", amount: ExactDecimal(String(repeating: "9", count: 40)))
  #expect(LedgerDisplayFormatter(locale: Locale(identifier: "en_US")).amount(huge) == "USD " + String(repeating: "9", count: 40))

  // A civil date prints as the same calendar day in every locale.
  let date = day(2026, 10, 25)
  #expect(LedgerDisplayFormatter(locale: Locale(identifier: "en_US")).date(date, style: .short) == "10/25/26")
  #expect(LedgerDisplayFormatter(locale: Locale(identifier: "de_DE")).date(date, style: .short) == "25.10.26")
}
