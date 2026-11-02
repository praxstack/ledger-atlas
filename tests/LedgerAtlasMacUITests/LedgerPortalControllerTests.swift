import Foundation
import Testing

@testable import LedgerAtlasMacUI

private let projection = LedgerPortalProjection(state: .ready, accountCount: 3, transactionCount: 7)

private func ledger(_ name: String) -> URL {
  URL(fileURLWithPath: "/tmp/ledger-atlas-portal-tests/\(name).sqlite")
}

/// True when the portal answered with the projection; false when nothing is listening.
private func answers(_ url: URL) async -> Bool {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.timeoutIntervalForRequest = 2
  guard let (_, response) = try? await URLSession(configuration: configuration).data(from: url)
  else { return false }
  return (response as? HTTPURLResponse)?.statusCode == 200
}

@MainActor
@Test func portalStopsWhenTheAppLocksAndCannotStartWhileLocked() async throws {
  let controller = LedgerPortalController(portal: LedgerLoopbackPortal(idleTimeout: 60))
  defer { controller.stop() }
  let url = try await controller.start(projection: projection, ledger: ledger("a"))
  #expect(await answers(url))

  controller.lockDidChange(isLocked: true)
  #expect(controller.url == nil)
  #expect(controller.lastStopReason == .locked)
  #expect(!(await answers(url)))
  await #expect(throws: LedgerPortalController.Error.locked) {
    _ = try await controller.start(projection: projection, ledger: ledger("a"))
  }

  controller.lockDidChange(isLocked: false)
  let again = try await controller.start(projection: projection, ledger: ledger("a"))
  #expect(await answers(again))
}

@MainActor
@Test func portalStopsWhenADifferentLedgerOpensOrTheLedgerCloses() async throws {
  let controller = LedgerPortalController(portal: LedgerLoopbackPortal(idleTimeout: 60))
  defer { controller.stop() }
  let url = try await controller.start(projection: projection, ledger: ledger("a"))

  controller.ledgerDidChange(to: URL(fileURLWithPath: "/tmp/ledger-atlas-portal-tests/./a.sqlite"))
  #expect(controller.isRunning)  // the same ledger, spelled differently
  controller.ledgerDidChange(to: ledger("b"))
  #expect(controller.url == nil)
  #expect(controller.lastStopReason == .ledgerChanged)
  #expect(!(await answers(url)))

  _ = try await controller.start(projection: projection, ledger: ledger("b"))
  controller.ledgerDidChange(to: nil)
  #expect(controller.lastStopReason == .ledgerChanged)
  #expect(!controller.isRunning)
}

@MainActor
@Test func controllerNoticesWhenThePortalStopsOnItsOwn() async throws {
  let controller = LedgerPortalController(portal: LedgerLoopbackPortal(idleTimeout: 1))
  defer { controller.stop() }
  _ = try await controller.start(projection: projection, ledger: ledger("a"))
  for _ in 0..<50 where controller.isRunning {
    try await Task.sleep(for: .milliseconds(100))
  }
  #expect(!controller.isRunning)
  #expect(controller.lastStopReason == .stoppedByPortal)
}

@Test func stoppedPortalSaysWhyWithoutPrivateDetail() {
  #expect(LocalAccessSurface.stoppedText(.locked) == "Portal stopped because Ledger Atlas locked.")
  #expect(
    LocalAccessSurface.stoppedText(.ledgerChanged)
      == "Portal stopped because a different ledger opened.")
  #expect(LocalAccessSurface.stoppedText(nil) == "Portal is stopped.")
}

@Test func dailyReminderShowsOnlyFixedText() {
  let content = LedgerNotificationScheduler.reminderContent()
  #expect(content.title == "Ledger Atlas")
  #expect(content.body == "Review your Ledger Atlas activity.")
  #expect(content.subtitle.isEmpty)
  #expect(content.userInfo.isEmpty)
}
