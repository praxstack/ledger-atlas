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

@MainActor
@Test func securityScopedLedgerAccessLastsUntilTheSessionCloses() async {
  let url = URL(fileURLWithPath: "/synthetic/ledger.sqlite")
  let counts = ScopeCounts()
  let loaded = LedgerSession.Presentation(
    snapshot: .init(
      accounts: [], transactions: [], revisionHistory: [], undisplayedImportedEventCount: 0))
  let session = LedgerSession(
    testingLoader: { _ in loaded },
    testingScopeStarter: { _ in
      counts.start()
      return true
    },
    testingScopeStopper: { _ in counts.stop() })

  #expect(session.open(url, requiresSecurityScope: true))
  for _ in 0..<100 where session.screen == LedgerSession.Screen.loading {
    try? await Task.sleep(for: .milliseconds(1))
  }
  #expect(session.screen == LedgerSession.Screen.loaded)
  #expect(counts.started == 1)
  #expect(counts.stopped == 0)

  session.close()
  #expect(counts.stopped == 1)
}

@MainActor
@Test func validatedLifecycleSnapshotLoadsImmediatelyAndRetainsItsSecurityScope() {
  let url = URL(fileURLWithPath: "/synthetic/validated.sqlite")
  let counts = ScopeCounts()
  let snapshot = LedgerStore.LedgerReadSnapshot(
    accounts: [], transactions: [], revisionHistory: [], undisplayedImportedEventCount: 0)
  let session = LedgerSession(
    testingScopeStarter: { _ in
      counts.start()
      return true
    },
    testingScopeStopper: { _ in counts.stop() })

  #expect(session.openValidated(url, snapshot: snapshot, requiresSecurityScope: true))
  #expect(session.screen == .loaded)
  #expect(counts.started == 1)
  #expect(counts.stopped == 0)

  session.close()
  #expect(counts.stopped == 1)
}

@MainActor
@Test func deniedSecurityScopedLedgerAccessFailsClosed() {
  let session = LedgerSession(
    testingLoader: { _ in fatalError("denied URL must not load") },
    testingScopeStarter: { _ in false })

  #expect(
    !session.open(URL(fileURLWithPath: "/synthetic/denied.sqlite"), requiresSecurityScope: true))
  #expect(session.screen == .unavailable)
}

@MainActor
@Test func closeDefersScopeReleaseUntilABlockedReadFinishes() async {
  let url = URL(fileURLWithPath: "/synthetic/blocked.sqlite")
  let gate = LoaderGate()
  let counts = ScopeCounts()
  let session = LedgerSession(
    testingLoader: { _ in
      gate.blockUntilReleased()
      return nil
    },
    testingScopeStarter: { _ in
      counts.start()
      return true
    },
    testingScopeStopper: { _ in counts.stop() })

  #expect(session.open(url, requiresSecurityScope: true))
  for _ in 0..<100 where !gate.hasStarted { try? await Task.sleep(for: .milliseconds(1)) }
  session.close()
  #expect(counts.stopped == 0)

  gate.release()
  for _ in 0..<100 where counts.stopped == 0 { try? await Task.sleep(for: .milliseconds(1)) }
  #expect(counts.stopped == 1)
}

@MainActor
@Test func replacingABlockedOpenRetainsItsScopeUntilItsReadFinishes() async {
  let blocked = URL(fileURLWithPath: "/synthetic/blocked.sqlite")
  let replacement = URL(fileURLWithPath: "/synthetic/replacement.sqlite")
  let gate = LoaderGate()
  let counts = ScopeCounts()
  let session = LedgerSession(
    testingLoader: { url in
      if url == blocked { gate.blockUntilReleased() }
      return nil
    },
    testingScopeStarter: { _ in
      counts.start()
      return true
    },
    testingScopeStopper: { _ in counts.stop() })

  #expect(session.open(blocked, requiresSecurityScope: true))
  for _ in 0..<100 where !gate.hasStarted { try? await Task.sleep(for: .milliseconds(1)) }
  #expect(session.open(replacement, requiresSecurityScope: true))
  for _ in 0..<100 where session.screen == .loading { try? await Task.sleep(for: .milliseconds(1)) }
  for _ in 0..<100 where counts.stopped < 1 { try? await Task.sleep(for: .milliseconds(1)) }
  #expect(counts.stopped == 1)

  gate.release()
  for _ in 0..<100 where counts.stopped < 2 { try? await Task.sleep(for: .milliseconds(1)) }
  #expect(counts.stopped == 2)
}

@MainActor
@Test func deallocatedSessionReleasesItsScopeAfterABlockedReadFinishes() async {
  let url = URL(fileURLWithPath: "/synthetic/blocked.sqlite")
  let gate = LoaderGate()
  let counts = ScopeCounts()
  var session: LedgerSession? = LedgerSession(
    testingLoader: { _ in
      gate.blockUntilReleased()
      return nil
    },
    testingScopeStarter: { _ in
      counts.start()
      return true
    },
    testingScopeStopper: { _ in counts.stop() })
  weak let releasedSession = session

  #expect(session?.open(url, requiresSecurityScope: true) == true)
  for _ in 0..<100 where !gate.hasStarted { try? await Task.sleep(for: .milliseconds(1)) }
  session = nil
  #expect(releasedSession == nil)
  #expect(counts.stopped == 0)

  gate.release()
  for _ in 0..<100 where counts.stopped == 0 { try? await Task.sleep(for: .milliseconds(1)) }
  #expect(counts.stopped == 1)
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

private final class ScopeCounts: @unchecked Sendable {
  private let lock = NSLock()
  private var startCount = 0
  private var stopCount = 0

  var started: Int { lock.withLock { startCount } }
  var stopped: Int { lock.withLock { stopCount } }
  func start() { lock.withLock { startCount += 1 } }
  func stop() { lock.withLock { stopCount += 1 } }
}

extension NSLocking {
  fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
