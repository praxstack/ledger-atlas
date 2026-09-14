import Foundation
import SwiftUI

public struct LedgerProductSettings: Codable, Equatable, Sendable {
  public enum Appearance: String, CaseIterable, Codable, Sendable {
    case system
    case light
    case dark
  }

  public var appearance: Appearance
  public var localeIdentifier: String
  public var firstWeekday: Int
  public var periodStartDay: Int
  public var remindersEnabled: Bool

  public var colorScheme: ColorScheme? {
    switch appearance {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }

  public init(
    appearance: Appearance = .system, localeIdentifier: String = "en_US",
    firstWeekday: Int = 1, periodStartDay: Int = 1, remindersEnabled: Bool = false
  ) {
    self.appearance = appearance
    self.localeIdentifier = localeIdentifier
    self.firstWeekday = min(max(firstWeekday, 1), 7)
    self.periodStartDay = min(max(periodStartDay, 1), 28)
    self.remindersEnabled = remindersEnabled
  }

  public static func load(from defaults: UserDefaults = .standard) -> Self {
    guard let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(Self.self, from: data)
    else { return .init() }
    return .init(
      appearance: value.appearance, localeIdentifier: value.localeIdentifier,
      firstWeekday: value.firstWeekday, periodStartDay: value.periodStartDay,
      remindersEnabled: value.remindersEnabled)
  }

  public func save(to defaults: UserDefaults = .standard) {
    guard let data = try? JSONEncoder().encode(self) else { return }
    defaults.set(data, forKey: Self.key)
  }

  private static let key = "ledger-atlas.product-settings.v1"
}
