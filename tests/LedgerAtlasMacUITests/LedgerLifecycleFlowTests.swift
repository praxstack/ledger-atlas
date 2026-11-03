import CSQLite
import Darwin
import Foundation
import LedgerCore
import LedgerStore
import Testing

@testable import LedgerAtlasMacUI

@MainActor
@Test func supersededLifecyclePublicationRemainsUserVisible() {
  let created = LedgerLifecycleOutcome(
    kind: .created, recoveryImageExists: false, message: nil, retryOperation: nil)
  let upgraded = LedgerLifecycleOutcome(
    kind: .upgraded, recoveryImageExists: true,
    message: "Ledger upgraded. A validated recovery image is available.", retryOperation: nil)
  let publishedFailure = LedgerLifecycleOutcome(
    kind: .failed, recoveryImageExists: true,
    message: "Ledger upgrade was published, but cleanup did not finish.", retryOperation: .open)
  let cancelled = LedgerLifecycleOutcome(
    kind: .cancelled, recoveryImageExists: false, message: nil, retryOperation: nil)

  #expect(
    LedgerAtlasRootView.supersededPublicationMessage(for: created)?.contains("created") == true)
  #expect(
    LedgerAtlasRootView.supersededPublicationMessage(for: upgraded)?.contains("upgraded") == true)
  #expect(
    LedgerAtlasRootView.supersededPublicationMessage(for: publishedFailure)
      == "An earlier ledger request finished: Ledger upgrade was published, but cleanup did not finish."
  )
  #expect(LedgerAtlasRootView.supersededPublicationMessage(for: cancelled) == nil)
}

@MainActor
@Test func backupFailureCopyDistinguishesCompletedPublication() {
  #expect(
    LedgerAtlasRootView.backupFailureMessage(
      for: LedgerStore.Error.backupPublicationCompleted)
      == "Backup was published, but durability or final validation did not finish. Verify the destination before retrying."
  )
  #expect(
    LedgerAtlasRootView.backupFailureMessage(
      for: LedgerStore.Error.incompatibleCanonicalStore)
      == "Backup could not be saved.")
}

@MainActor
@Test func createLedgerValidatesReopensThenPersistsTheBookmark() async throws {
  try await withFlowDirectory { directory in
    let destination = directory.appendingPathComponent("created.sqlite")
    let (bookmarks, defaults, suite) = try makeBookmarkStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let states = WidgetStates()
    let journey = LedgerJourney()
    let session = LedgerSession(testingScopeStarter: { _ in true })

    let outcome = await LedgerAtlasRootView.performLedgerLifecycle(
      .create, at: destination, bookmarkStore: bookmarks,
      widgetPublisher: .init(write: { states.append($0.state) }), journey: journey,
      session: session, scopeStarter: { _ in true }, scopeStopper: { _ in })

    #expect(outcome.kind == .created)
    #expect(outcome.recoveryImageExists == false)
    #expect(try LedgerStoreLifecycle.inspect(at: destination) == .current)
    #expect(bookmarks.reopen(.canonicalLedger) == .resolved(destination))
    #expect(session.screen == .loaded)
    #expect(journey.phase == .imported)
    #expect(states.values == [.ready])
  }
}

@MainActor
@Test func bookmarkFailureNeverPublishesReadyAndRetainsWidgetFailure() async throws {
  try await withFlowDirectory { directory in
    let destination = directory.appendingPathComponent("created.sqlite")
    let suite = "LedgerAtlasMacUITests.lifecycle.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let bookmarks = SecurityScopedBookmarkStore(
      defaults: defaults,
      makeBookmark: { _ in throw FlowTestError.injected },
      resolveBookmark: { URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)) })
    let attemptedStates = WidgetStates()
    let persistedStates = WidgetStates()
    let journey = LedgerJourney()
    let session = LedgerSession(testingScopeStarter: { _ in true })

    let outcome = await LedgerAtlasRootView.performLedgerLifecycle(
      .create, at: destination, bookmarkStore: bookmarks,
      widgetPublisher: .init(write: { projection in
        attemptedStates.append(projection.state)
        guard projection.state == .ready else { throw FlowTestError.injected }
        persistedStates.append(projection.state)
      }), journey: journey,
      session: session, scopeStarter: { _ in true }, scopeStopper: { _ in })

    #expect(outcome.kind == .failed)
    #expect(!outcome.recoveryImageExists)
    #expect(
      outcome.message
        == "Ledger was created, but access could not be retained. Choose Open Ledger to continue."
    )
    #expect(outcome.retryOperation == .open)
    #expect(try LedgerStoreLifecycle.inspect(at: destination) == .current)
    #expect(bookmarks.reopen(.canonicalLedger) == .missing)
    #expect(session.screen == .noLedger)
    #expect(journey.ledgerURL == nil)
    #expect(attemptedStates.values == [.reopenRequired])
    #expect(!persistedStates.values.contains(.ready))
  }
}

@MainActor
@Test func savedBookmarkAutoReopenUsesTheCurrentLedgerLifecyclePath() async throws {
  try await withFlowDirectory { directory in
    let destination = directory.appendingPathComponent("current.sqlite")
    _ = try LedgerStoreLifecycle.create(at: destination)
    let (bookmarks, defaults, suite) = try makeBookmarkStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    try bookmarks.save(destination)
    let states = WidgetStates()
    let journey = LedgerJourney()
    let session = LedgerSession(testingScopeStarter: { _ in true })
    let operations = OperationLog()

    let outcome = await LedgerAtlasRootView.reopenSavedLedger(
      bookmarkStore: bookmarks,
      widgetPublisher: .init(write: { states.append($0.state) }), journey: journey,
      session: session, scopeStarter: { _ in true }, scopeStopper: { _ in },
      lifecycle: { operation, url in
        operations.append(operation)
        return try LedgerStoreLifecycle.open(at: url)
      })

    #expect(outcome.kind == .opened)
    #expect(operations.values == [.open])
    #expect(bookmarks.reopen(.canonicalLedger) == .resolved(destination))
    #expect(session.screen == .loaded)
    #expect(journey.phase == .imported)
    #expect(states.values == [.ready])
  }
}

@MainActor
@Test func openLedgerUsesLifecycleForAnExplicitCurrentSelection() async throws {
  try await withFlowDirectory { directory in
    let destination = directory.appendingPathComponent("current.sqlite")
    _ = try LedgerStoreLifecycle.create(at: destination)
    let (bookmarks, defaults, suite) = try makeBookmarkStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let journey = LedgerJourney()
    let session = LedgerSession(testingScopeStarter: { _ in true })
    let operations = OperationLog()

    let outcome = await LedgerAtlasRootView.performLedgerSelection(
      .open, url: destination, bookmarkStore: bookmarks,
      widgetPublisher: .init(write: { _ in }), journey: journey, session: session,
      scopeStarter: { _ in true }, scopeStopper: { _ in },
      lifecycle: { operation, url in
        operations.append(operation)
        return try LedgerStoreLifecycle.open(at: url)
      })

    #expect(outcome.kind == .opened)
    #expect(operations.values == [.open])
    #expect(bookmarks.reopen(.canonicalLedger) == .resolved(destination))
  }
}

@MainActor
@Test func staleBookmarkAutoReopenRenewsOnlyAfterLifecycleSuccess() async throws {
  try await withFlowDirectory { directory in
    let destination = directory.appendingPathComponent("stale.sqlite")
    _ = try LedgerStoreLifecycle.create(at: destination)
    let suite = "LedgerAtlasMacUITests.lifecycle.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var writes = 0
    let bookmarks = SecurityScopedBookmarkStore(
      defaults: defaults,
      makeBookmark: { _ in
        writes += 1
        return Data("bookmark-\(writes)".utf8)
      },
      resolveBookmarkResult: { _ in .init(url: destination, isStale: writes == 1) })
    try bookmarks.save(destination)

    let outcome = await LedgerAtlasRootView.reopenSavedLedger(
      bookmarkStore: bookmarks, widgetPublisher: .init(write: { _ in }),
      journey: LedgerJourney(), session: LedgerSession(testingScopeStarter: { _ in true }),
      scopeStarter: { _ in true }, scopeStopper: { _ in })

    #expect(outcome.kind == .opened)
    #expect(writes == 2)
    #expect(bookmarks.reopen(.canonicalLedger) == .resolved(destination))
  }
}

@MainActor
@Test func openLedgerUpgradesV10AndReportsTheValidatedRecoveryImage() async throws {
  try await withFlowDirectory { directory in
    let destination = directory.appendingPathComponent("legacy.sqlite")
    let accountID = try writeV10Ledger(to: destination)
    let legacyBytes = try Data(contentsOf: destination)
    let (bookmarks, defaults, suite) = try makeBookmarkStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let states = WidgetStates()
    let journey = LedgerJourney()
    let session = LedgerSession(testingScopeStarter: { _ in true })

    let outcome = await LedgerAtlasRootView.performLedgerLifecycle(
      .open, at: destination, bookmarkStore: bookmarks,
      widgetPublisher: .init(write: { states.append($0.state) }), journey: journey,
      session: session, scopeStarter: { _ in true }, scopeStopper: { _ in })

    #expect(outcome.kind == .upgraded)
    #expect(outcome.recoveryImageExists)
    #expect(outcome.message == "Ledger upgraded. A validated recovery image is available.")
    #expect(journey.snapshot?.accounts.map(\.id) == [accountID])
    #expect(
      try Data(contentsOf: LedgerStoreLifecycle.recoveryImageURL(for: destination)) == legacyBytes)
    #expect(bookmarks.reopen(.canonicalLedger) == .resolved(destination))
    #expect(states.values == [.ready])
  }
}

@MainActor
@Test func snapshotFailureAfterCreationReportsTheCompletedLedgerAndOpenRetry() async throws {
  try await withFlowDirectory { directory in
    let destination = directory.appendingPathComponent("created.sqlite")
    let (bookmarks, defaults, suite) = try makeBookmarkStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let states = WidgetStates()

    let outcome = await LedgerAtlasRootView.performLedgerLifecycle(
      .create, at: destination, bookmarkStore: bookmarks,
      widgetPublisher: .init(write: { states.append($0.state) }), journey: LedgerJourney(),
      session: LedgerSession(testingScopeStarter: { _ in true }), scopeStarter: { _ in true },
      scopeStopper: { _ in }, snapshotReader: { _ in throw FlowTestError.injected })

    #expect(outcome.kind == .failed)
    #expect(!outcome.recoveryImageExists)
    #expect(outcome.retryOperation == .open)
    #expect(
      outcome.message
        == "Ledger was created, but its contents could not be validated. Choose Open Ledger to inspect or retry."
    )
    #expect(try LedgerStoreLifecycle.inspect(at: destination) == .current)
    #expect(bookmarks.reopen(.canonicalLedger) == .missing)
    #expect(states.values == [.reopenRequired])
  }
}

@MainActor
@Test func snapshotFailureAfterUpgradePreservesValidatedRecoveryTruth() async throws {
  try await withFlowDirectory { directory in
    let destination = directory.appendingPathComponent("legacy.sqlite")
    _ = try writeV10Ledger(to: destination)
    let legacyBytes = try Data(contentsOf: destination)
    let (bookmarks, defaults, suite) = try makeBookmarkStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let states = WidgetStates()

    let outcome = await LedgerAtlasRootView.performLedgerLifecycle(
      .open, at: destination, bookmarkStore: bookmarks,
      widgetPublisher: .init(write: { states.append($0.state) }), journey: LedgerJourney(),
      session: LedgerSession(testingScopeStarter: { _ in true }), scopeStarter: { _ in true },
      scopeStopper: { _ in }, snapshotReader: { _ in throw FlowTestError.injected })

    #expect(outcome.kind == .failed)
    #expect(outcome.recoveryImageExists)
    #expect(outcome.retryOperation == .open)
    #expect(
      outcome.message
        == "Ledger was upgraded, but its contents could not be validated. A validated recovery image is available. Choose Open Ledger to retry."
    )
    #expect(try LedgerStoreLifecycle.inspect(at: destination) == .current)
    #expect(
      try Data(contentsOf: LedgerStoreLifecycle.recoveryImageURL(for: destination)) == legacyBytes)
    #expect(bookmarks.reopen(.canonicalLedger) == .missing)
    #expect(states.values == [.reopenRequired])
  }
}

@MainActor
@Test func readyWidgetFailureAfterCreationPreservesTheReadyLedgerAndBookmark() async throws {
  try await withFlowDirectory { directory in
    let destination = directory.appendingPathComponent("created.sqlite")
    let (bookmarks, defaults, suite) = try makeBookmarkStore()
    defer { defaults.removePersistentDomain(forName: suite) }

    let journey = LedgerJourney()
    let session = LedgerSession(testingScopeStarter: { _ in true })
    let outcome = await LedgerAtlasRootView.performLedgerLifecycle(
      .create, at: destination, bookmarkStore: bookmarks,
      widgetPublisher: .init(write: { _ in throw FlowTestError.injected }),
      journey: journey, session: session,
      scopeStarter: { _ in true }, scopeStopper: { _ in })

    #expect(outcome.kind == .created)
    #expect(!outcome.recoveryImageExists)
    #expect(outcome.retryOperation == nil)
    // A widget that can't be updated is only logged: no message, and the ledger stays open.
    #expect(outcome.message == nil)
    #expect(try LedgerStoreLifecycle.inspect(at: destination) == .current)
    #expect(bookmarks.reopen(.canonicalLedger) == .resolved(destination))
    #expect(session.screen == .loaded)
    #expect(journey.ledgerURL == destination)
  }
}

@MainActor
@Test func readyWidgetFailureAfterUpgradePreservesLedgerBookmarkAndRecoveryTruth() async throws {
  try await withFlowDirectory { directory in
    let destination = directory.appendingPathComponent("legacy.sqlite")
    _ = try writeV10Ledger(to: destination)
    let legacyBytes = try Data(contentsOf: destination)
    let (bookmarks, defaults, suite) = try makeBookmarkStore()
    defer { defaults.removePersistentDomain(forName: suite) }

    let journey = LedgerJourney()
    let session = LedgerSession(testingScopeStarter: { _ in true })
    let outcome = await LedgerAtlasRootView.performLedgerLifecycle(
      .open, at: destination, bookmarkStore: bookmarks,
      widgetPublisher: .init(write: { _ in throw FlowTestError.injected }),
      journey: journey, session: session,
      scopeStarter: { _ in true }, scopeStopper: { _ in })

    #expect(outcome.kind == .upgraded)
    #expect(outcome.recoveryImageExists)
    #expect(outcome.retryOperation == nil)
    #expect(
      outcome.message
        == "Ledger upgraded. A validated recovery image is available."
    )
    #expect(try LedgerStoreLifecycle.inspect(at: destination) == .current)
    #expect(
      try Data(contentsOf: LedgerStoreLifecycle.recoveryImageURL(for: destination)) == legacyBytes)
    #expect(bookmarks.reopen(.canonicalLedger) == .resolved(destination))
    #expect(session.screen == .loaded)
    #expect(journey.ledgerURL == destination)
  }
}

@MainActor
@Test func upgradedLifecycleStoreRejectsAPathSwapBeforeBackup() async throws {
  try await withFlowDirectory { directory in
    let destination = directory.appendingPathComponent("legacy.sqlite")
    _ = try writeV10Ledger(to: destination)
    let replacement = directory.appendingPathComponent("replacement.sqlite")
    let parked = directory.appendingPathComponent("parked.sqlite")
    let backup = directory.appendingPathComponent("backup.sqlite")
    let (bookmarks, defaults, suite) = try makeBookmarkStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let journey = LedgerJourney()
    let session = LedgerSession(testingScopeStarter: { _ in true })

    let outcome = await LedgerAtlasRootView.performLedgerLifecycle(
      .open, at: destination, bookmarkStore: bookmarks,
      widgetPublisher: .init(write: { _ in }), journey: journey, session: session,
      scopeStarter: { _ in true }, scopeStopper: { _ in })
    #expect(outcome.kind == .upgraded)
    _ = try LedgerStoreLifecycle.create(at: replacement)
    try FileManager.default.moveItem(at: destination, to: parked)
    try FileManager.default.moveItem(at: replacement, to: destination)

    #expect(throws: LedgerApplication.Error.invalidCommand) {
      try journey.backupCanonicalLedger(to: backup)
    }
    #expect(!FileManager.default.fileExists(atPath: backup.path))
    #expect(bookmarks.reopen(.canonicalLedger) == .resolved(destination))
  }
}

@MainActor
@Test func blockedLifecycleKeepsTheMainActorResponsiveAndScopeActiveUntilApplication() async throws
{
  try await withFlowDirectory { directory in
    let destination = directory.appendingPathComponent("current.sqlite")
    _ = try LedgerStoreLifecycle.create(at: destination)
    let (bookmarks, defaults, suite) = try makeBookmarkStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let journey = LedgerJourney()
    let session = LedgerSession(testingScopeStarter: { _ in true })
    let gate = LifecycleGate()
    let events = EventLog()

    let pending = Task { @MainActor in
      await LedgerAtlasRootView.performLedgerLifecycle(
        .open, at: destination, bookmarkStore: bookmarks,
        widgetPublisher: .init(write: { _ in }), journey: journey, session: session,
        scopeStarter: { _ in
          events.append("start")
          return true
        },
        scopeStopper: { _ in events.append("stop") },
        lifecycle: { _, url in
          await gate.block()
          events.append("lifecycle-sync-start")
          Task { @MainActor in events.append("lifecycle-heartbeat") }
          usleep(100_000)
          let result = try LedgerStoreLifecycle.open(at: url)
          events.append("lifecycle-sync-end")
          return result
        },
        snapshotReader: { store in
          events.append("snapshot-sync-start")
          Task { @MainActor in events.append("snapshot-heartbeat") }
          usleep(100_000)
          let snapshot = try store.readSnapshot()
          events.append("snapshot-sync-end")
          return snapshot
        })
    }

    await gate.waitUntilStarted()
    Task { @MainActor in events.append("heartbeat") }
    await Task.yield()
    #expect(events.values.filter { $0.hasPrefix("stop") }.isEmpty)
    #expect(events.values.contains("heartbeat"))
    #expect(session.screen == .noLedger)
    #expect(journey.ledgerURL == nil)
    await gate.release()

    let outcome = await pending.value
    await Task.yield()
    #expect(outcome.kind == .opened)
    #expect(
      events.values.firstIndex(of: "lifecycle-heartbeat")! < events.values.firstIndex(
        of: "lifecycle-sync-end")!)
    #expect(
      events.values.firstIndex(of: "snapshot-heartbeat")! < events.values.firstIndex(
        of: "snapshot-sync-end")!)
    #expect(events.values.first == "start")
    #expect(events.values.last == "stop")
    #expect(session.screen == .loaded)
    #expect(journey.ledgerURL == destination)
    session.close()
  }
}

@MainActor
@Test func staleAutomaticReopenSuccessCannotOverwriteANewerSelection() async throws {
  try await withFlowDirectory { directory in
    let saved = directory.appendingPathComponent("saved.sqlite")
    let selected = directory.appendingPathComponent("selected.sqlite")
    _ = try LedgerStoreLifecycle.create(at: saved)
    _ = try LedgerStoreLifecycle.create(at: selected)
    let (bookmarks, defaults, suite) = try makeBookmarkStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    try bookmarks.save(saved)
    let journey = LedgerJourney()
    let session = LedgerSession(testingScopeStarter: { _ in true })
    let gate = LifecycleGate()
    let current = IntBox(1)

    let stale = Task { @MainActor in
      await LedgerAtlasRootView.reopenSavedLedger(
        bookmarkStore: bookmarks, widgetPublisher: .init(write: { _ in }), journey: journey,
        session: session, scopeStarter: { _ in true }, scopeStopper: { _ in },
        lifecycle: { _, url in
          await gate.block()
          return try LedgerStoreLifecycle.open(at: url)
        }, isCurrent: { current.value == 1 })
    }
    await gate.waitUntilStarted()
    current.value = 2

    let latest = await LedgerAtlasRootView.performLedgerLifecycle(
      .open, at: selected, bookmarkStore: bookmarks,
      widgetPublisher: .init(write: { _ in }), journey: journey, session: session,
      scopeStarter: { _ in true }, scopeStopper: { _ in }, isCurrent: { current.value == 2 })
    await gate.release()
    let staleOutcome = await stale.value

    #expect(latest.kind == .opened)
    // The stale result is not applied to the active session, but the caller still receives the
    // completed core truth instead of a false cancellation after publication.
    #expect(staleOutcome.kind == .opened)
    #expect(bookmarks.reopen(.canonicalLedger) == .resolved(selected))
    #expect(journey.ledgerURL == selected)
    #expect(session.screen == .loaded)
  }
}

@MainActor
@Test func staleAutomaticReopenFailureCannotTearDownANewerSelection() async throws {
  try await withFlowDirectory { directory in
    let saved = directory.appendingPathComponent("saved.sqlite")
    let selected = directory.appendingPathComponent("selected.sqlite")
    _ = try LedgerStoreLifecycle.create(at: saved)
    _ = try LedgerStoreLifecycle.create(at: selected)
    let (bookmarks, defaults, suite) = try makeBookmarkStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    try bookmarks.save(saved)
    let journey = LedgerJourney()
    let session = LedgerSession(testingScopeStarter: { _ in true })
    let gate = LifecycleGate()
    let current = IntBox(1)

    let stale = Task { @MainActor in
      await LedgerAtlasRootView.reopenSavedLedger(
        bookmarkStore: bookmarks, widgetPublisher: .init(write: { _ in }), journey: journey,
        session: session, scopeStarter: { _ in true }, scopeStopper: { _ in },
        lifecycle: { _, _ in
          await gate.block()
          throw FlowTestError.injected
        }, isCurrent: { current.value == 1 })
    }
    await gate.waitUntilStarted()
    current.value = 2

    let latest = await LedgerAtlasRootView.performLedgerLifecycle(
      .open, at: selected, bookmarkStore: bookmarks,
      widgetPublisher: .init(write: { _ in }), journey: journey, session: session,
      scopeStarter: { _ in true }, scopeStopper: { _ in }, isCurrent: { current.value == 2 })
    await gate.release()
    let staleOutcome = await stale.value

    #expect(latest.kind == .opened)
    #expect(staleOutcome.kind == .cancelled)
    #expect(bookmarks.reopen(.canonicalLedger) == .resolved(selected))
    #expect(journey.ledgerURL == selected)
    #expect(session.screen == .loaded)
  }
}

@MainActor
@Test func cancellingASupersededUpgradeLeavesTheOldLedgerByteIdentical() async throws {
  try await withFlowDirectory { directory in
    let saved = directory.appendingPathComponent("saved-v10.sqlite")
    _ = try writeV10Ledger(to: saved)
    let savedBytes = try Data(contentsOf: saved)
    let selected = directory.appendingPathComponent("selected.sqlite")
    _ = try LedgerStoreLifecycle.create(at: selected)
    let (bookmarks, defaults, suite) = try makeBookmarkStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    try bookmarks.save(saved)
    let journey = LedgerJourney()
    let session = LedgerSession(testingScopeStarter: { _ in true })
    let gate = BlockingLifecycleGate()
    let current = IntBox(1)

    let stale = Task { @MainActor in
      await LedgerAtlasRootView.reopenSavedLedger(
        bookmarkStore: bookmarks, widgetPublisher: .init(write: { _ in }), journey: journey,
        session: session, scopeStarter: { _ in true }, scopeStopper: { _ in },
        lifecycle: { _, url in
          try LedgerStoreLifecycle.open(at: url) { phase in
            if phase == .afterSourceAuthenticated { gate.block() }
          }
        }, isCurrent: { current.value == 1 })
    }
    for _ in 0..<1_000 where !gate.hasStarted {
      try? await Task.sleep(for: .milliseconds(1))
    }
    #expect(gate.hasStarted)
    current.value = 2
    stale.cancel()

    let latest = await LedgerAtlasRootView.performLedgerLifecycle(
      .open, at: selected, bookmarkStore: bookmarks,
      widgetPublisher: .init(write: { _ in }), journey: journey, session: session,
      scopeStarter: { _ in true }, scopeStopper: { _ in }, isCurrent: { current.value == 2 })
    gate.release()
    let staleOutcome = await stale.value

    #expect(latest.kind == .opened)
    #expect(staleOutcome.kind == .cancelled)
    #expect(try Data(contentsOf: saved) == savedBytes)
    #expect(
      !FileManager.default.fileExists(
        atPath: LedgerStoreLifecycle.recoveryImageURL(for: saved).path))
    #expect(bookmarks.reopen(.canonicalLedger) == .resolved(selected))
    #expect(journey.ledgerURL == selected)
    #expect(session.screen == .loaded)
  }
}

@MainActor
@Test func failedUpgradeClosesTheOldSessionPreservesBookmarkAndUsesNeutralRetryCopy() async throws {
  try await withFlowDirectory { directory in
    let prior = directory.appendingPathComponent("prior.sqlite")
    let priorResult = try LedgerStoreLifecycle.create(at: prior)
    let priorBytes = try Data(contentsOf: prior)
    let selected = directory.appendingPathComponent("selected.sqlite")
    _ = try writeV10Ledger(to: selected)
    let selectedBytes = try Data(contentsOf: selected)
    let (bookmarks, defaults, suite) = try makeBookmarkStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    try bookmarks.save(prior)
    let states = WidgetStates()
    let journey = LedgerJourney()
    let session = LedgerSession(testingScopeStarter: { _ in true })
    let priorSnapshot = try journey.openValidatedLedger(priorResult.store, at: prior)
    #expect(session.openValidated(prior, snapshot: priorSnapshot))

    let outcome = await LedgerAtlasRootView.performLedgerLifecycle(
      .open, at: selected, bookmarkStore: bookmarks,
      widgetPublisher: .init(write: { states.append($0.state) }), journey: journey,
      session: session, scopeStarter: { _ in true }, scopeStopper: { _ in },
      lifecycle: { _, url in
        try LedgerStoreLifecycle.open(at: url) { phase in
          if phase == .afterRecoveryPublished { throw FlowTestError.injected }
        }
      })

    #expect(outcome.kind == .failed)
    #expect(outcome.recoveryImageExists)
    #expect(
      outcome.message
        == "Ledger upgrade did not finish. A validated recovery image is available. Choose Open Ledger to retry."
    )
    #expect(outcome.retryOperation == .open)
    #expect(!outcome.message!.contains(prior.path))
    #expect(!outcome.message!.contains(selected.path))
    #expect(bookmarks.reopen(.canonicalLedger) == .resolved(prior))
    #expect(try Data(contentsOf: prior) == priorBytes)
    #expect(try Data(contentsOf: selected) == selectedBytes)
    #expect(
      try Data(contentsOf: LedgerStoreLifecycle.recoveryImageURL(for: selected)) == selectedBytes)
    #expect(session.screen == .noLedger)
    #expect(journey.ledgerURL == nil)
    #expect(states.values == [.reopenRequired])
  }
}

@MainActor
@Test func recoveryPublicationFailureWithoutValidatedImageUsesTruthfulCopy() async throws {
  try await withFlowDirectory { directory in
    let destination = directory.appendingPathComponent("legacy.sqlite")
    let (bookmarks, defaults, suite) = try makeBookmarkStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let states = WidgetStates()
    let journey = LedgerJourney()
    let session = LedgerSession(testingScopeStarter: { _ in true })

    let outcome = await LedgerAtlasRootView.performLedgerLifecycle(
      .open, at: destination, bookmarkStore: bookmarks,
      widgetPublisher: .init(write: { states.append($0.state) }), journey: journey,
      session: session, scopeStarter: { _ in true }, scopeStopper: { _ in },
      lifecycle: { _, _ in
        throw LedgerStoreLifecycle.Error.publicationCompleted(
          phase: .recoveryPublished, recoveryImageExists: false)
      })

    #expect(outcome.kind == .failed)
    #expect(!outcome.recoveryImageExists)
    #expect(outcome.retryOperation == .open)
    #expect(
      outcome.message
        == "Ledger upgrade did not finish. No recovery image passed validation. Choose Open Ledger to retry."
    )
    #expect(!outcome.message!.contains("validated recovery image is available"))
    #expect(bookmarks.reopen(.canonicalLedger) == .missing)
    #expect(session.screen == .noLedger)
    #expect(journey.ledgerURL == nil)
    #expect(states.values == [.reopenRequired])
  }
}

@MainActor
@Test func createPublicationFailureReportsThatTheLedgerAlreadyExists() async throws {
  try await withFlowDirectory { directory in
    let destination = directory.appendingPathComponent("created.sqlite")
    let (bookmarks, defaults, suite) = try makeBookmarkStore()
    defer { defaults.removePersistentDomain(forName: suite) }

    let outcome = await LedgerAtlasRootView.performLedgerLifecycle(
      .create, at: destination, bookmarkStore: bookmarks,
      widgetPublisher: .init(write: { _ in }), journey: LedgerJourney(),
      session: LedgerSession(testingScopeStarter: { _ in true }),
      scopeStarter: { _ in true }, scopeStopper: { _ in },
      lifecycle: { _, url in
        try LedgerStoreLifecycle.create(at: url) { phase in
          if phase == .afterPublication { throw FlowTestError.injected }
        }
      })

    #expect(outcome.kind == .failed)
    #expect(!outcome.recoveryImageExists)
    #expect(outcome.retryOperation == .open)
    #expect(
      outcome.message
        == "Ledger was created, but it could not be reopened. Choose Open Ledger to continue.")
    #expect(try LedgerStoreLifecycle.inspect(at: destination) == .current)
    #expect(bookmarks.reopen(.canonicalLedger) == .missing)
  }
}

@MainActor
@Test func upgradePublicationFailureReportsCurrentLedgerAndValidatedRecovery() async throws {
  try await withFlowDirectory { directory in
    let destination = directory.appendingPathComponent("legacy.sqlite")
    _ = try writeV10Ledger(to: destination)
    let legacyBytes = try Data(contentsOf: destination)
    let (bookmarks, defaults, suite) = try makeBookmarkStore()
    defer { defaults.removePersistentDomain(forName: suite) }

    let outcome = await LedgerAtlasRootView.performLedgerLifecycle(
      .open, at: destination, bookmarkStore: bookmarks,
      widgetPublisher: .init(write: { _ in }), journey: LedgerJourney(),
      session: LedgerSession(testingScopeStarter: { _ in true }),
      scopeStarter: { _ in true }, scopeStopper: { _ in },
      lifecycle: { _, url in
        try LedgerStoreLifecycle.open(at: url) { phase in
          if phase == .afterPublication { throw FlowTestError.injected }
        }
      })

    #expect(outcome.kind == .failed)
    #expect(outcome.recoveryImageExists)
    #expect(outcome.retryOperation == .open)
    #expect(
      outcome.message
        == "Ledger upgrade was published, but opening or cleanup did not finish. A validated recovery image is available. Choose Open Ledger to retry."
    )
    #expect(try LedgerStoreLifecycle.inspect(at: destination) == .current)
    #expect(
      try Data(contentsOf: LedgerStoreLifecycle.recoveryImageURL(for: destination)) == legacyBytes)
    #expect(bookmarks.reopen(.canonicalLedger) == .missing)
  }
}

@MainActor
@Test func publishedUpgradeNeverCallsAnUnsafeRecoveryValidated() async throws {
  try await withFlowDirectory { directory in
    let destination = directory.appendingPathComponent("legacy.sqlite")
    _ = try writeV10Ledger(to: destination)
    let recovery = LedgerStoreLifecycle.recoveryImageURL(for: destination)
    let (bookmarks, defaults, suite) = try makeBookmarkStore()
    defer {
      _ = chmod(recovery.path, mode_t(S_IRUSR | S_IWUSR))
      defaults.removePersistentDomain(forName: suite)
    }

    let outcome = await LedgerAtlasRootView.performLedgerLifecycle(
      .open, at: destination, bookmarkStore: bookmarks,
      widgetPublisher: .init(write: { _ in }), journey: LedgerJourney(),
      session: LedgerSession(testingScopeStarter: { _ in true }),
      scopeStarter: { _ in true }, scopeStopper: { _ in },
      lifecycle: { _, url in
        try LedgerStoreLifecycle.open(at: url) { phase in
          guard phase == .afterPublication,
            chmod(recovery.path, mode_t(S_IRUSR | S_IWUSR | S_IRGRP)) == 0
          else { return }
        }
      })

    #expect(outcome.kind == .failed)
    #expect(!outcome.recoveryImageExists)
    #expect(outcome.retryOperation == .open)
    #expect(
      outcome.message
        == "Ledger upgrade was published, but the recovery image failed validation. The current ledger was not rolled back. Repair or replace the recovery image, then choose Open Ledger to retry."
    )
    #expect(try LedgerStoreLifecycle.inspect(at: destination) == .current)
    #expect(bookmarks.reopen(.canonicalLedger) == .missing)
  }
}

@MainActor
@Test func corruptOrSymlinkRecoveryNeverClaimsValidationOrReplacesTheBookmark() async throws {
  try await withFlowDirectory { directory in
    let prior = directory.appendingPathComponent("prior.sqlite")
    _ = try LedgerStoreLifecycle.create(at: prior)
    let priorBytes = try Data(contentsOf: prior)
    let (bookmarks, defaults, suite) = try makeBookmarkStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    try bookmarks.save(prior)

    for name in ["corrupt", "symlink"] {
      let selected = directory.appendingPathComponent("\(name).sqlite")
      _ = try writeV10Ledger(to: selected)
      let selectedBytes = try Data(contentsOf: selected)
      let recovery = LedgerStoreLifecycle.recoveryImageURL(for: selected)
      if name == "corrupt" {
        try Data("not a ledger".utf8).write(to: recovery)
        #expect(chmod(recovery.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
      } else {
        let sibling = directory.appendingPathComponent("unrelated.sqlite")
        _ = try LedgerStoreLifecycle.create(at: sibling)
        try FileManager.default.createSymbolicLink(at: recovery, withDestinationURL: sibling)
      }
      let outcome = await LedgerAtlasRootView.performLedgerLifecycle(
        .open, at: selected, bookmarkStore: bookmarks,
        widgetPublisher: .init(write: { _ in }), journey: LedgerJourney(),
        session: LedgerSession(testingScopeStarter: { _ in true }), scopeStarter: { _ in true },
        scopeStopper: { _ in })

      #expect(outcome.kind == .failed)
      #expect(!outcome.recoveryImageExists)
      #expect(outcome.message == "Ledger could not be opened. Choose Open Ledger to retry.")
      #expect(bookmarks.reopen(.canonicalLedger) == .resolved(prior))
      #expect(try Data(contentsOf: prior) == priorBytes)
      #expect(try Data(contentsOf: selected) == selectedBytes)
    }
  }
}

@MainActor
@Test func injectedCreateFailureKeepsThePriorBookmarkAndSourceUntouched() async throws {
  try await withFlowDirectory { directory in
    let prior = directory.appendingPathComponent("prior.sqlite")
    _ = try LedgerStoreLifecycle.create(at: prior)
    let priorBytes = try Data(contentsOf: prior)
    let destination = directory.appendingPathComponent("new.sqlite")
    let (bookmarks, defaults, suite) = try makeBookmarkStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    try bookmarks.save(prior)

    let outcome = await LedgerAtlasRootView.performLedgerLifecycle(
      .create, at: destination, bookmarkStore: bookmarks,
      widgetPublisher: .init(write: { _ in }), journey: LedgerJourney(),
      session: LedgerSession(testingScopeStarter: { _ in true }), scopeStarter: { _ in true },
      scopeStopper: { _ in }, lifecycle: { _, _ in throw FlowTestError.injected })

    #expect(outcome.kind == .failed)
    #expect(!outcome.recoveryImageExists)
    #expect(outcome.message == "Ledger could not be created. Choose Create Ledger to retry.")
    #expect(outcome.retryOperation == .create)
    #expect(bookmarks.reopen(.canonicalLedger) == .resolved(prior))
    #expect(try Data(contentsOf: prior) == priorBytes)
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }
}

@MainActor
@Test func failedLifecycleReportsOnlyItsOwnFailureWhenTheWidgetAlsoFails() async throws {
  try await withFlowDirectory { directory in
    let destination = directory.appendingPathComponent("missing.sqlite")
    let (bookmarks, defaults, suite) = try makeBookmarkStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let journey = LedgerJourney()
    let session = LedgerSession(testingScopeStarter: { _ in true })

    let outcome = await LedgerAtlasRootView.performLedgerLifecycle(
      .open, at: destination, bookmarkStore: bookmarks,
      widgetPublisher: .init(write: { _ in throw FlowTestError.injected }), journey: journey,
      session: session, scopeStarter: { _ in true }, scopeStopper: { _ in },
      lifecycle: { _, _ in throw FlowTestError.injected })

    let expected = "Ledger could not be opened. Choose Open Ledger to retry."
    #expect(outcome.kind == .failed)
    #expect(outcome.message == expected)
    #expect(journey.lastFailure == expected)
    #expect(session.screen == .noLedger)
    #expect(journey.ledgerURL == nil)
  }
}

@MainActor
@Test func deniedScopeReportsOnlyItsOwnFailureWhenTheWidgetAlsoFails() async throws {
  try await withFlowDirectory { directory in
    let (bookmarks, defaults, suite) = try makeBookmarkStore()
    defer { defaults.removePersistentDomain(forName: suite) }

    let outcome = await LedgerAtlasRootView.performLedgerLifecycle(
      .create, at: directory.appendingPathComponent("denied.sqlite"), bookmarkStore: bookmarks,
      widgetPublisher: .init(write: { _ in throw FlowTestError.injected }),
      journey: LedgerJourney(), session: LedgerSession(testingScopeStarter: { _ in true }),
      scopeStarter: { _ in false }, scopeStopper: { _ in })

    #expect(
      outcome.message
        == "Ledger access was not granted to create the ledger. Choose Create Ledger to retry."
    )
  }
}

@MainActor
@Test func corruptBookmarkReportsOnlyItsOwnFailureWhenTheWidgetAlsoFails() async throws {
  let suite = "LedgerAtlasMacUITests.lifecycle.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  defaults.set(
    Data("corrupt".utf8),
    forKey: "\(SecurityScopedBookmarkStore.defaultKey).canonicalLedger")
  let bookmarks = SecurityScopedBookmarkStore(
    defaults: defaults, makeBookmark: { Data($0.path.utf8) },
    resolveBookmark: { _ in throw FlowTestError.injected })

  let outcome = await LedgerAtlasRootView.reopenSavedLedger(
    bookmarkStore: bookmarks,
    widgetPublisher: .init(write: { _ in throw FlowTestError.injected }),
    journey: LedgerJourney(), session: LedgerSession(testingScopeStarter: { _ in true }),
    scopeStarter: { _ in true }, scopeStopper: { _ in })

  #expect(
    outcome.message
      == "Ledger access needs to be selected again. Choose Open Ledger to retry."
  )
}

@MainActor
@Test func deniedScopeClosesTheOldSessionAndUsesTheOperationSpecificRetry() async throws {
  try await withFlowDirectory { directory in
    let prior = directory.appendingPathComponent("prior.sqlite")
    let priorResult = try LedgerStoreLifecycle.create(at: prior)
    let (bookmarks, defaults, suite) = try makeBookmarkStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    try bookmarks.save(prior)
    let states = WidgetStates()
    let journey = LedgerJourney()
    let session = LedgerSession(testingScopeStarter: { _ in true })
    let priorSnapshot = try journey.openValidatedLedger(priorResult.store, at: prior)
    #expect(session.openValidated(prior, snapshot: priorSnapshot))
    for (operation, expectedMessage) in [
      (
        .create,
        "Ledger access was not granted to create the ledger. Choose Create Ledger to retry."
      ),
      (.open, "Ledger access was not granted to open the ledger. Choose Open Ledger to retry."),
    ] as [(LedgerLifecycleOperation, String)] {
      let lifecycleCalled = BoolBox()
      let outcome = await LedgerAtlasRootView.performLedgerLifecycle(
        operation, at: directory.appendingPathComponent("denied-\(operation).sqlite"),
        bookmarkStore: bookmarks, widgetPublisher: .init(write: { states.append($0.state) }),
        journey: journey, session: session, scopeStarter: { _ in false }, scopeStopper: { _ in },
        lifecycle: { _, _ in
          lifecycleCalled.value = true
          throw FlowTestError.injected
        })

      #expect(outcome.kind == .failed)
      #expect(outcome.message == expectedMessage)
      #expect(outcome.retryOperation == operation)
      #expect(!lifecycleCalled.value)
      #expect(bookmarks.reopen(.canonicalLedger) == .resolved(prior))
      #expect(session.screen == .noLedger)
      #expect(journey.ledgerURL == nil)
    }
    #expect(states.values == [.permissionDenied, .permissionDenied])
  }
}

@MainActor
@Test func cancelledSelectionLeavesThePriorSessionBookmarkAndWidgetUntouched() async throws {
  try await withFlowDirectory { directory in
    let prior = directory.appendingPathComponent("prior.sqlite")
    let priorResult = try LedgerStoreLifecycle.create(at: prior)
    let (bookmarks, defaults, suite) = try makeBookmarkStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    try bookmarks.save(prior)
    let states = WidgetStates()
    let journey = LedgerJourney()
    let session = LedgerSession(testingScopeStarter: { _ in true })
    let priorSnapshot = try journey.openValidatedLedger(priorResult.store, at: prior)
    #expect(session.openValidated(prior, snapshot: priorSnapshot))

    let outcome = await LedgerAtlasRootView.performLedgerSelection(
      .open, url: nil, bookmarkStore: bookmarks,
      widgetPublisher: .init(write: { states.append($0.state) }), journey: journey,
      session: session, scopeStarter: { _ in true }, scopeStopper: { _ in })

    #expect(outcome.kind == .cancelled)
    #expect(bookmarks.reopen(.canonicalLedger) == .resolved(prior))
    #expect(session.screen == .loaded)
    #expect(journey.ledgerURL == prior)
    #expect(states.values.isEmpty)
  }
}

@MainActor
@Test func nativeLedgerActionsHaveFixedAccessibleLabelsAndPanelCopy() {
  #expect(LedgerAtlasRootView.createLedgerActionLabel == "Create Ledger")
  #expect(LedgerAtlasRootView.openLedgerActionLabel == "Open Ledger")
  #expect(
    LedgerAtlasRootView.createLedgerPanelMessage
      == "Name the new ledger. Ledger Atlas keeps it in its own storage; use Backup to save copies anywhere.")
  #expect(
    LedgerAtlasRootView.openLedgerPanelMessage
      == "Choose a Ledger Atlas ledger. A ledger from elsewhere is copied into Ledger Atlas; the original is not changed.")
  #expect(LedgerLifecycleOperation.create.retryButtonTitle == "Create Ledger…")
  #expect(LedgerLifecycleOperation.create.retryAccessibilityLabel == "Create Ledger")
  #expect(LedgerLifecycleOperation.open.retryButtonTitle == "Open Ledger…")
  #expect(
    LedgerLifecycleGuidance.noLedger.text(retrying: .create)
      == "Choose Create Ledger to retry. Recovery is reported only after the ledger is validated.")
  #expect(
    LedgerLifecycleGuidance.unavailable.text(retrying: .open)
      == "Choose Open Ledger to retry. Recovery is reported only after the ledger is validated.")
}

@MainActor
private func withFlowDirectory(_ body: (URL) async throws -> Void) async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try await body(directory)
}

private func makeBookmarkStore() throws
  -> (SecurityScopedBookmarkStore, UserDefaults, String)
{
  let suite = "LedgerAtlasMacUITests.lifecycle.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  return (
    SecurityScopedBookmarkStore(
      defaults: defaults, makeBookmark: { Data($0.path.utf8) },
      resolveBookmark: { URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)) }),
    defaults, suite
  )
}

private final class WidgetStates: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [RedactedWidgetProjection.State] = []

  var values: [RedactedWidgetProjection.State] { lock.withLock { storage } }
  func append(_ state: RedactedWidgetProjection.State) { lock.withLock { storage.append(state) } }
}

private final class OperationLog: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [LedgerLifecycleOperation] = []

  var values: [LedgerLifecycleOperation] { lock.withLock { storage } }
  func append(_ operation: LedgerLifecycleOperation) { lock.withLock { storage.append(operation) } }
}

private final class BoolBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = false

  var value: Bool {
    get { lock.withLock { storage } }
    set { lock.withLock { storage = newValue } }
  }
}

private actor LifecycleGate {
  private var started = false
  private var released = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func block() async {
    started = true
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    guard !released else { return }
    await withCheckedContinuation { releaseWaiters.append($0) }
  }

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func release() {
    released = true
    let waiters = releaseWaiters
    releaseWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }
}

private final class BlockingLifecycleGate: @unchecked Sendable {
  private let condition = NSCondition()
  private var started = false
  private var released = false

  var hasStarted: Bool { condition.withLock { started } }

  func block() {
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

private final class EventLog: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []

  var values: [String] { lock.withLock { storage } }
  func append(_ event: String) { lock.withLock { storage.append(event) } }
}

private final class IntBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Int

  init(_ value: Int) { storage = value }
  var value: Int {
    get { lock.withLock { storage } }
    set { lock.withLock { storage = newValue } }
  }
}

private func writeV10Ledger(to url: URL) throws -> String {
  var database: OpaquePointer?
  guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
    throw FlowTestError.sqlite
  }
  defer { sqlite3_close(database) }
  for object in CanonicalLedgerSchema.legacyV10Objects {
    guard sqlite3_exec(database, object.ddl, nil, nil, nil) == SQLITE_OK else {
      throw FlowTestError.sqlite
    }
  }
  let originID = String(repeating: "1", count: 64)
  let accountID = String(repeating: "2", count: 64)
  let sql = """
    PRAGMA application_id=\(CanonicalLedgerSchema.applicationID);
    INSERT INTO ledger_meta(key, value) VALUES
      ('schema_version', '10'),
      ('ledger_identity', 'ledger-atlas-canonical'),
      ('schema_fingerprint', '\(CanonicalLedgerSchema.legacyV10Fingerprint)');
    INSERT INTO ledger_origin(origin_id, label, provenance_id)
      VALUES ('\(originID)', 'synthetic', NULL);
    INSERT INTO ledger_account(account_id, name, currency_unit, origin_id, lifecycle)
      VALUES ('\(accountID)', 'Synthetic', 'USD', '\(originID)', 'active');
    """
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK,
    chmod(url.path, mode_t(S_IRUSR | S_IWUSR)) == 0
  else { throw FlowTestError.sqlite }
  return accountID
}

private enum FlowTestError: Error { case sqlite, injected }

/// What Prax hit on the first test DMG (2026-11-03): a Money Manager backup chosen with Open
/// Ledger was copied in and then refused with a general message, behind a widget error.
@MainActor
@Test func openingAMoneyManagerBackupSaysToImportItAndMarksTheCopyForRemoval() async throws {
  try await withFlowDirectory { directory in
    let backup = directory.appendingPathComponent("MM(04-11-26-022456).mmbak")
    try writeFlowMoneyManagerBackup(to: backup)
    #expect(LedgerJourney.isMoneyManagerBackup(backup))
    let (bookmarks, defaults, suite) = try makeBookmarkStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let journey = LedgerJourney()
    let session = LedgerSession(testingScopeStarter: { _ in true })

    let outcome = await LedgerAtlasRootView.performLedgerLifecycle(
      .open, at: backup, bookmarkStore: bookmarks,
      widgetPublisher: .init(write: { _ in throw FlowTestError.injected }), journey: journey,
      session: session, scopeStarter: { _ in true }, scopeStopper: { _ in })

    let expected =
      "This file is not a Ledger Atlas ledger. To bring in a Money Manager backup, choose Import Money Manager Backup instead."
    #expect(outcome.kind == .failed)
    #expect(outcome.failure == .invalidStore)
    #expect(outcome.message == expected)
    #expect(journey.lastFailure == expected)
    #expect(LedgerAtlasRootView.shouldRemoveRefusedCopy(outcome))
    #expect(bookmarks.reopen(.canonicalLedger) == .missing)
  }
}

@MainActor
@Test func aRealLedgerIsNotTakenForAMoneyManagerBackup() async throws {
  try await withFlowDirectory { directory in
    let ledger = directory.appendingPathComponent("ledger.sqlite")
    _ = try LedgerStoreLifecycle.create(at: ledger)
    #expect(!LedgerJourney.isMoneyManagerBackup(ledger))
  }
}

@MainActor
@Test func lifecycleFailuresNameTheirCause() {
  #expect(
    LedgerAtlasRootView.lifecycleFailureMessage(.open, LedgerStoreLifecycle.Error.unsupportedStore)
      == "This version of Ledger Atlas can't open this ledger. If it was saved by a newer version, update the app, then open it again.")
  #expect(
    LedgerAtlasRootView.lifecycleFailureMessage(.create, LedgerStoreLifecycle.Error.invalidStore)
      == "Ledger could not be created. Choose Create Ledger to retry.")
  #expect(
    LedgerAtlasRootView.lifecycleFailureMessage(.open, FlowTestError.injected)
      == "Ledger could not be opened. Choose Open Ledger to retry.")
  #expect(
    !LedgerAtlasRootView.shouldRemoveRefusedCopy(
      .init(kind: .failed, recoveryImageExists: false, message: nil, failure: .busy)))
}

private func writeFlowMoneyManagerBackup(to url: URL) throws {
  try LedgerDemoTour.writeMoneyManagerBackup(to: url)
}
