import Foundation
import UserNotifications

/// Opening the daily reminder opens the entry form with Upcoming beside it (#171), so the cue
/// leads straight to an entry. The form opens on a day with nothing due too. The app delegate
/// makes this the notification centre's delegate at launch.
public final class LedgerReminderResponder: NSObject, UNUserNotificationCenterDelegate,
  @unchecked Sendable
{
  public static let shared = LedgerReminderResponder()
  package static let didOpenReminder = Notification.Name("LedgerAtlas.reminder.didOpen")
  /// An opened reminder older than this is dropped, so a reminder opened while no ledger could
  /// be shown never surprises the person later.
  package static let lifetime: TimeInterval = 10 * 60
  /// When the reminder was opened, until the open ledger takes it.
  @MainActor private static var openedAt: Date?

  public func install() {
    UNUserNotificationCenter.current().delegate = self
  }

  public func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    guard response.notification.request.identifier == LedgerNotificationScheduler.reminderIdentifier,
      response.actionIdentifier == UNNotificationDefaultActionIdentifier
    else { return }
    await Self.reminderOpened()
  }

  @MainActor package static func reminderOpened(at now: Date = Date()) {
    openedAt = now
    NotificationCenter.default.post(name: didOpenReminder, object: nil)
  }

  /// Whether an opened reminder is waiting; a fresh one is taken, a stale one dropped.
  @MainActor package static func take(at now: Date = Date()) -> Bool {
    guard let opened = openedAt else { return false }
    openedAt = nil
    return now.timeIntervalSince(opened) <= lifetime && opened <= now.addingTimeInterval(60)
  }

  @MainActor package static var isWaiting: Bool { openedAt != nil }
}
