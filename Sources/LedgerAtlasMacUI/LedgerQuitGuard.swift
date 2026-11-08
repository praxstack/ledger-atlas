import AppKit
import Foundation

/// Holds Quit while Ledger Atlas is writing a ledger off the main thread (an import, an upgrade,
/// a restore). `.suddenTerminationDisabled` does not stop Cmd-Q, and a quit in the middle of
/// such a write leaves a half-written file behind (#178). Edits save on the main thread, so a
/// quit can't land in the middle of one; a bulk change and its revert run off it and are held
/// here too (#246).
///
/// Quit asks first. "Quit When Finished" keeps the app running until the last write ends and
/// then quits; "Keep Working" cancels the quit.
///
/// The window can't be closed while a write runs. Closing the app's only window quits it, and
/// a window opened again afterwards would get its own lock and session while the write still
/// holds the ledger (#179 by another route).
@MainActor
public final class LedgerQuitGuard {
  public static let shared = LedgerQuitGuard()

  /// One running write. Ends when `end()` is called; calling it twice is harmless.
  @MainActor
  public final class Work {
    private weak var owner: LedgerQuitGuard?
    private let activity: NSObjectProtocol
    private var ended = false

    fileprivate init(owner: LedgerQuitGuard, activity: NSObjectProtocol) {
      self.owner = owner
      self.activity = activity
    }

    public func end() {
      guard !ended else { return }
      ended = true
      ProcessInfo.processInfo.endActivity(activity)
      owner?.workEnded()
    }
  }

  public private(set) var runningWork = 0
  /// Set after the person chose to quit once the running work ends.
  public private(set) var quitsWhenIdle = false
  private let confirm: @MainActor () -> Bool
  private let replyToTerminate: @MainActor (Bool) -> Void
  private let windows: @MainActor () -> [NSWindow]
  /// Windows whose close button this guard turned off, to turn back on when the writes end.
  private var heldWindows: [NSWindow] = []

  package init(
    confirm: @escaping @MainActor () -> Bool = LedgerQuitGuard.askToQuitWhenFinished,
    replyToTerminate: @escaping @MainActor (Bool) -> Void = {
      NSApplication.shared.reply(toApplicationShouldTerminate: $0)
    },
    windows: @escaping @MainActor () -> [NSWindow] = { NSApplication.shared.windows }
  ) {
    self.confirm = confirm
    self.replyToTerminate = replyToTerminate
    self.windows = windows
  }

  /// Starts a write that Quit must not cut off. Also keeps the Mac awake while it runs.
  public func begin(_ reason: String) -> Work {
    runningWork += 1
    if runningWork == 1 { holdWindowsOpen() }
    let activity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiated, .suddenTerminationDisabled], reason: reason)
    return Work(owner: self, activity: activity)
  }

  /// The answer for `NSApplicationDelegate.applicationShouldTerminate`.
  public func terminateReply() -> NSApplication.TerminateReply {
    guard runningWork > 0 else { return .terminateNow }
    guard !quitsWhenIdle else { return .terminateLater }
    guard confirm() else { return .terminateCancel }
    // The confirmation is modal, so the work may have finished while it was showing.
    guard runningWork > 0 else { return .terminateNow }
    quitsWhenIdle = true
    return .terminateLater
  }

  private func workEnded() {
    runningWork = max(0, runningWork - 1)
    guard runningWork == 0 else { return }
    releaseWindows()
    guard quitsWhenIdle else { return }
    quitsWhenIdle = false
    replyToTerminate(true)
  }

  /// Turns off the close button and ⌘W of every open document window (not panels or sheets).
  private func holdWindowsOpen() {
    for window in windows()
    where window.styleMask.contains(.closable) && !(window is NSPanel) && window.sheetParent == nil
    {
      window.styleMask.remove(.closable)
      heldWindows.append(window)
    }
  }

  private func releaseWindows() {
    for window in heldWindows { window.styleMask.insert(.closable) }
    heldWindows = []
  }

  package static let quitTitle = "Ledger Atlas is still writing a ledger"
  package static let quitMessage =
    "Quitting now would leave the ledger half-written. Ledger Atlas can quit by itself as soon as it finishes."
  package static let quitWhenFinishedLabel = "Quit When Finished"
  package static let keepWorkingLabel = "Keep Working"

  package static func askToQuitWhenFinished() -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = quitTitle
    alert.informativeText = quitMessage
    alert.addButton(withTitle: quitWhenFinishedLabel)
    alert.addButton(withTitle: keepWorkingLabel)
    return alert.runModal() == .alertFirstButtonReturn
  }
}
