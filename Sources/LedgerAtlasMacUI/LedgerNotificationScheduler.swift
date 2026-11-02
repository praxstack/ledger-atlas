import Foundation
import UserNotifications

public enum LedgerNotificationScheduler {
  public static let reminderIdentifier = "com.praxstack.ledgeratlas.daily-reminder"

  @MainActor
  public static func setDailyReminder(enabled: Bool, hour: Int = 9) async -> Bool {
    let center = UNUserNotificationCenter.current()
    guard enabled else {
      center.removePendingNotificationRequests(withIdentifiers: [reminderIdentifier])
      return true
    }
    do {
      guard try await center.requestAuthorization(options: [.alert, .sound]) else { return false }
      var components = DateComponents()
      components.hour = min(max(hour, 0), 23)
      components.minute = 0
      let request = UNNotificationRequest(
        identifier: reminderIdentifier,
        content: reminderContent(),
        trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true))
      try await center.add(request)
      return true
    } catch {
      return false
    }
  }

  /// The reminder is the same fixed text every day, so it shows nothing from the ledger on a
  /// lock screen or in Notification Center, whether or not the app is locked.
  static func reminderContent() -> UNMutableNotificationContent {
    let content = UNMutableNotificationContent()
    content.title = "Ledger Atlas"
    content.body = "Review your Ledger Atlas activity."
    content.sound = .default
    return content
  }
}
