import Foundation

#if canImport(AppKit)
  import AppKit
#endif
#if canImport(SwiftUI)
  import SwiftUI
#endif

/// Typed presentation and behaviour settings (MACV2-13).
///
/// Settings change how values are shown, never the stored values themselves. Nothing here
/// parses display text back into amounts or dates; see `LedgerDisplayFormatter`.
public struct LedgerProductSettings: Codable, Equatable, Sendable {
  public enum Appearance: String, CaseIterable, Codable, Sendable {
    case system
    case light
    case dark
  }

  /// How income and expense amounts are tinted. Colour is never the only signal:
  /// amounts always keep their sign.
  public enum AmountColors: String, CaseIterable, Codable, Sendable {
    /// Money in is green; spending stays in plain text colour. Red is kept for overspending.
    case incomeGreen
    case incomeGreenExpenseRed
    case incomeBlueExpenseRed
    case monochrome
  }

  public enum Motion: String, CaseIterable, Codable, Sendable {
    case followSystem
    case reduced
  }

  /// Fields that can hold an invalid value. Settings UI focuses the reported field.
  public enum Field: String, CaseIterable, Hashable, Sendable {
    case localeIdentifier
    case timeZoneIdentifier
    case firstWeekday
    case periodStartDay
    case startScreen
    case reminderHour
  }

  /// Destinations a user can pick as the screen shown after a ledger opens.
  public static let startScreenChoices: [AppDestination] = [
    .overview, .ledger, .accounts, .insights, .budgets, .categories,
  ]

  public static let periodStartDays = 1...31
  public static let reminderHours = 0...23

  public var appearance: Appearance
  public var localeIdentifier: String
  /// `nil` follows the Mac's time zone. Stored dates are civil dates and never shift.
  public var timeZoneIdentifier: String?
  /// 1 = Sunday … 7 = Saturday, matching `Calendar.firstWeekday`.
  public var firstWeekday: Int
  /// Day of the month a monthly period starts. Months shorter than this start on their last day.
  public var periodStartDay: Int
  public var startScreen: AppDestination
  public var amountColors: AmountColors
  /// Carry a period's unspent budget and balance into the next period.
  public var carryOverEnabled: Bool
  public var motion: Motion
  public var remindersEnabled: Bool
  public var reminderHour: Int
  /// Hide amounts (#173, ⇧⌘H): every figure on screen shows as bullets. Exports, the
  /// loopback portal and App Intent results are not covered, and Settings says so.
  public var hidesAmounts: Bool

  /// What Hide amounts covers, as Settings states it.
  public static let hideAmountsScope =
    "Every amount, balance and chart figure on screen shows as the same row of bullets, whatever its size (⇧⌘H). Charts keep their shape. Hide amounts does not apply to exports: PDF statements, spreadsheets, portable packages, the local web portal and Shortcuts results still show amounts. A form you open to enter or change an amount still shows that amount."
  /// Shown in place of the Insights accessible table while amounts are hidden.
  public static let hiddenTableNotice =
    "Amounts are hidden. Turn off Hide amounts (⇧⌘H) to read this table."
  /// Said beside each export while amounts are hidden.
  public static let hideAmountsExportNotice = "Hide amounts does not apply to exports."

  public init(
    appearance: Appearance = .system, localeIdentifier: String = "en_US",
    timeZoneIdentifier: String? = nil,
    firstWeekday: Int = 1, periodStartDay: Int = 1,
    startScreen: AppDestination = .overview, amountColors: AmountColors = .incomeGreen,
    carryOverEnabled: Bool = false, motion: Motion = .followSystem,
    remindersEnabled: Bool = false, reminderHour: Int = 9, hidesAmounts: Bool = false
  ) {
    self.appearance = appearance
    self.localeIdentifier = localeIdentifier
    self.timeZoneIdentifier = timeZoneIdentifier
    self.firstWeekday = min(max(firstWeekday, 1), 7)
    self.periodStartDay = min(max(periodStartDay, Self.periodStartDays.lowerBound), Self.periodStartDays.upperBound)
    self.startScreen = startScreen
    self.amountColors = amountColors
    self.carryOverEnabled = carryOverEnabled
    self.motion = motion
    self.remindersEnabled = remindersEnabled
    self.reminderHour = min(max(reminderHour, Self.reminderHours.lowerBound), Self.reminderHours.upperBound)
    self.hidesAmounts = hidesAmounts
  }

  // MARK: Validation

  /// Every invalid field with a message the settings screen can show next to it.
  public func validationErrors() -> [Field: String] {
    var errors: [Field: String] = [:]
    if !Self.isKnownLocale(localeIdentifier) {
      errors[.localeIdentifier] = "Choose a locale from the list."
    }
    if let timeZoneIdentifier, TimeZone(identifier: timeZoneIdentifier) == nil {
      errors[.timeZoneIdentifier] = "Choose a time zone from the list."
    }
    if !(1...7).contains(firstWeekday) {
      errors[.firstWeekday] = "Choose a weekday."
    }
    if !Self.periodStartDays.contains(periodStartDay) {
      errors[.periodStartDay] = "Use a day from 1 to 31."
    }
    if !Self.startScreenChoices.contains(startScreen) {
      errors[.startScreen] = "Choose a start screen from the list."
    }
    if !Self.reminderHours.contains(reminderHour) {
      errors[.reminderHour] = "Use an hour from 0 to 23."
    }
    return errors
  }

  /// The first invalid field in display order, or nil when everything is valid.
  public var firstInvalidField: Field? {
    let errors = validationErrors()
    return Field.allCases.first { errors[$0] != nil }
  }

  /// Applies `candidate` only if it is fully valid. On failure the current (last known good)
  /// value is kept and the field to focus is returned.
  @discardableResult
  public mutating func apply(_ candidate: LedgerProductSettings) -> Field? {
    if let field = candidate.firstInvalidField { return field }
    self = candidate
    return nil
  }

  // MARK: Derived presentation values

  public var locale: Locale { Locale(identifier: localeIdentifier) }

  public var timeZone: TimeZone {
    timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
  }

  public var periodRule: LedgerPeriodRule {
    LedgerPeriodRule(monthStartDay: periodStartDay, firstWeekday: firstWeekday)
  }

  public func reduceMotion(systemReduceMotion: Bool) -> Bool {
    motion == .reduced || systemReduceMotion
  }

  // MARK: Persistence

  public static func load(from defaults: UserDefaults = .standard) -> Self {
    guard let data = defaults.data(forKey: key),
      let value = try? JSONDecoder().decode(Self.self, from: data)
    else { return .init() }
    return value
  }

  public func save(to defaults: UserDefaults = .standard) {
    guard firstInvalidField == nil, let data = try? JSONEncoder().encode(self) else { return }
    defaults.set(data, forKey: Self.key)
  }

  // The key keeps its v1 name: new fields are additive and decode with defaults.
  private static let key = "ledger-atlas.product-settings.v1"

  private enum CodingKeys: String, CodingKey {
    case appearance, localeIdentifier, timeZoneIdentifier, firstWeekday, periodStartDay
    case startScreen, amountColors, carryOverEnabled, motion, remindersEnabled, reminderHour
    case hidesAmounts
  }

  /// Decodes field by field. A missing or invalid field falls back to its default instead of
  /// discarding every other stored preference.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = Self()
    func value<T: Decodable>(_ key: CodingKeys, _ fallback: T, valid: (T) -> Bool = { _ in true }) -> T {
      guard let decoded = try? c.decodeIfPresent(T.self, forKey: key), valid(decoded) else { return fallback }
      return decoded
    }
    appearance = value(.appearance, defaults.appearance)
    localeIdentifier = value(.localeIdentifier, defaults.localeIdentifier, valid: Self.isKnownLocale)
    timeZoneIdentifier = value(.timeZoneIdentifier, Optional<String>.none) {
      $0.map { TimeZone(identifier: $0) != nil } ?? true
    }
    firstWeekday = value(.firstWeekday, defaults.firstWeekday) { (1...7).contains($0) }
    periodStartDay = value(.periodStartDay, defaults.periodStartDay) { Self.periodStartDays.contains($0) }
    startScreen = value(.startScreen, defaults.startScreen) { Self.startScreenChoices.contains($0) }
    amountColors = value(.amountColors, defaults.amountColors)
    carryOverEnabled = value(.carryOverEnabled, defaults.carryOverEnabled)
    motion = value(.motion, defaults.motion)
    remindersEnabled = value(.remindersEnabled, defaults.remindersEnabled)
    reminderHour = value(.reminderHour, defaults.reminderHour) { Self.reminderHours.contains($0) }
    hidesAmounts = value(.hidesAmounts, defaults.hidesAmounts)
  }

  private static func isKnownLocale(_ identifier: String) -> Bool {
    !identifier.isEmpty && Locale.availableIdentifiers.contains(identifier)
  }
}

extension AppDestination: Codable {}

#if canImport(SwiftUI)
  extension LedgerProductSettings {
    public var colorScheme: ColorScheme? {
      switch appearance {
      case .system: nil
      case .light: .light
      case .dark: .dark
      }
    }
  }
#endif

#if canImport(AppKit)
  extension LedgerProductSettings.Appearance {
    /// The AppKit appearance for this choice. `nil` follows the Mac's own setting.
    public var appearanceName: NSAppearance.Name? {
      switch self {
      case .system: nil
      case .light: .aqua
      case .dark: .darkAqua
      }
    }
  }
#endif
