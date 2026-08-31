import Foundation
import Testing

@testable import LedgerAtlasMacUI

@Test func productSettingsPersistTypedPresentationAndPeriodValues() {
  let suite = "LedgerAtlasMacUITests.settings.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let original = LedgerProductSettings(
    appearance: .dark, localeIdentifier: "de_DE", firstWeekday: 2,
    periodStartDay: 31, remindersEnabled: true)
  original.save(to: defaults)
  let loaded = LedgerProductSettings.load(from: defaults)
  #expect(loaded.appearance == .dark)
  #expect(loaded.localeIdentifier == "de_DE")
  #expect(loaded.firstWeekday == 2)
  #expect(loaded.periodStartDay == 28)
  #expect(loaded.remindersEnabled)
  #expect(loaded.colorScheme == .dark)
}
