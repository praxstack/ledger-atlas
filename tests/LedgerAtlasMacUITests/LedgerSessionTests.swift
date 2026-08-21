import Foundation
import LedgerAtlasMacUI
import LedgerStore
import Testing

@MainActor
@Test func ledgerSessionStartsEmptyAndLoadsUnavailableFilesOffTheMainView() async {
  let session = LedgerSession()
  #expect(session.screen == LedgerSession.Screen.noLedger)

  session.open(URL(fileURLWithPath: "/definitely-not-a-ledger.sqlite"))
  #expect(session.screen == LedgerSession.Screen.loading)

  for _ in 0..<100 where session.screen == LedgerSession.Screen.loading {
    try? await Task.sleep(for: .milliseconds(1))
  }
  #expect(session.screen == LedgerSession.Screen.unavailable)
}

@MainActor
@Test func latestLedgerOpenWinsWhenAnOlderLoadFinishesLast() async {
  let slow = URL(fileURLWithPath: "/synthetic/slow.sqlite")
  let unavailable = URL(fileURLWithPath: "/synthetic/unavailable.sqlite")
  let gate = LoaderGate()
  let loaded = LedgerSession.Presentation(
    snapshot: .init(
      accounts: [], transactions: [], revisionHistory: [],
      undisplayedImportedEventCount: 0))
  let session = LedgerSession(testingLoader: { url in
    guard url == slow else { return nil }
    gate.blockUntilReleased()
    return loaded
  })

  session.open(slow)
  for _ in 0..<100 where !gate.hasStarted {
    try? await Task.sleep(for: .milliseconds(1))
  }
  #expect(gate.hasStarted)
  session.open(unavailable)
  for _ in 0..<100 where session.screen == .loading {
    try? await Task.sleep(for: .milliseconds(1))
  }
  #expect(session.screen == .unavailable)

  gate.release()
  try? await Task.sleep(for: .milliseconds(20))
  #expect(session.screen == .unavailable)
}

private final class LoaderGate: @unchecked Sendable {
  private let condition = NSCondition()
  private var started = false
  private var released = false

  var hasStarted: Bool {
    condition.withLock { started }
  }

  func blockUntilReleased() {
    condition.lock()
    started = true
    condition.broadcast()
    while !released { condition.wait() }
    condition.unlock()
  }

  func release() {
    condition.withLock {
      released = true
      condition.broadcast()
    }
  }
}

extension NSLocking {
  fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
