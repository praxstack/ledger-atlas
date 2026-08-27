import CSQLite
import Darwin
import Foundation
import LedgerCore
import LedgerStore
import Testing

@testable import LedgerAtlasMacUI

@MainActor
@Test func createLedgerValidatesReopensThenPersistsTheBookmark() throws {
  try withFlowDirectory { directory in
    let destination = directory.appendingPathComponent("created.sqlite")
    let (bookmarks, defaults, suite) = try makeBookmarkStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let states = WidgetStates()
    let journey = LedgerJourney()
    let session = LedgerSession(testingScopeStarter: { _ in true })

    let outcome = LedgerAtlasRootView.performLedgerLifecycle(
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
@Test func savedBookmarkAutoReopenUsesTheCurrentLedgerLifecyclePath() throws {
  try withFlowDirectory { directory in
    let destination = directory.appendingPathComponent("current.sqlite")
    _ = try LedgerStoreLifecycle.create(at: destination)
    let (bookmarks, defaults, suite) = try makeBookmarkStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    try bookmarks.save(destination)
    let states = WidgetStates()
    let journey = LedgerJourney()
    let session = LedgerSession(testingScopeStarter: { _ in true })
    var operations: [LedgerLifecycleOperation] = []

    let outcome = LedgerAtlasRootView.reopenSavedLedger(
      bookmarkStore: bookmarks,
      widgetPublisher: .init(write: { states.append($0.state) }), journey: journey,
      session: session, scopeStarter: { _ in true }, scopeStopper: { _ in },
      lifecycle: { operation, url in
        operations.append(operation)
        return try LedgerStoreLifecycle.open(at: url)
      })

    #expect(outcome.kind == .opened)
    #expect(operations == [.open])
    #expect(bookmarks.reopen(.canonicalLedger) == .resolved(destination))
    #expect(session.screen == .loaded)
    #expect(journey.phase == .imported)
    #expect(states.values == [.ready])
  }
}

@MainActor
@Test func openLedgerUsesLifecycleForAnExplicitCurrentSelection() throws {
  try withFlowDirectory { directory in
    let destination = directory.appendingPathComponent("current.sqlite")
    _ = try LedgerStoreLifecycle.create(at: destination)
    let (bookmarks, defaults, suite) = try makeBookmarkStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let journey = LedgerJourney()
    let session = LedgerSession(testingScopeStarter: { _ in true })
    var operations: [LedgerLifecycleOperation] = []

    let outcome = LedgerAtlasRootView.performLedgerSelection(
      .open, url: destination, bookmarkStore: bookmarks,
      widgetPublisher: .init(write: { _ in }), journey: journey, session: session,
      scopeStarter: { _ in true }, scopeStopper: { _ in },
      lifecycle: { operation, url in
        operations.append(operation)
        return try LedgerStoreLifecycle.open(at: url)
      })

    #expect(outcome.kind == .opened)
    #expect(operations == [.open])
    #expect(bookmarks.reopen(.canonicalLedger) == .resolved(destination))
  }
}

@MainActor
@Test func staleBookmarkAutoReopenRenewsOnlyAfterLifecycleSuccess() throws {
  try withFlowDirectory { directory in
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

    let outcome = LedgerAtlasRootView.reopenSavedLedger(
      bookmarkStore: bookmarks, widgetPublisher: .init(write: { _ in }),
      journey: LedgerJourney(), session: LedgerSession(testingScopeStarter: { _ in true }),
      scopeStarter: { _ in true }, scopeStopper: { _ in })

    #expect(outcome.kind == .opened)
    #expect(writes == 2)
    #expect(bookmarks.reopen(.canonicalLedger) == .resolved(destination))
  }
}

@MainActor
@Test func openLedgerUpgradesV10AndReportsTheValidatedRecoveryImage() throws {
  try withFlowDirectory { directory in
    let destination = directory.appendingPathComponent("legacy.sqlite")
    let accountID = try writeV10Ledger(to: destination)
    let legacyBytes = try Data(contentsOf: destination)
    let (bookmarks, defaults, suite) = try makeBookmarkStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let states = WidgetStates()
    let journey = LedgerJourney()
    let session = LedgerSession(testingScopeStarter: { _ in true })

    let outcome = LedgerAtlasRootView.performLedgerLifecycle(
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
@Test func failedUpgradeClosesTheOldSessionPreservesBookmarkAndReportsRecovery() throws {
  try withFlowDirectory { directory in
    let prior = directory.appendingPathComponent("prior.sqlite")
    let priorResult = try LedgerStoreLifecycle.create(at: prior)
    let selected = directory.appendingPathComponent("selected.sqlite")
    _ = try writeV10Ledger(to: selected)
    let (bookmarks, defaults, suite) = try makeBookmarkStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    try bookmarks.save(prior)
    let states = WidgetStates()
    let journey = LedgerJourney()
    let session = LedgerSession(testingScopeStarter: { _ in true })
    let priorSnapshot = try journey.openValidatedLedger(priorResult.store, at: prior)
    #expect(session.openValidated(prior, snapshot: priorSnapshot))

    let outcome = LedgerAtlasRootView.performLedgerLifecycle(
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
        == "Ledger could not be opened. A recovery image exists. Choose Open Ledger to retry.")
    #expect(!outcome.message!.contains(prior.path))
    #expect(!outcome.message!.contains(selected.path))
    #expect(bookmarks.reopen(.canonicalLedger) == .resolved(prior))
    #expect(session.screen == .noLedger)
    #expect(journey.ledgerURL == nil)
    #expect(states.values == [.reopenRequired])
  }
}

@MainActor
@Test func deniedScopeClosesTheOldSessionAndPreservesThePriorBookmark() throws {
  try withFlowDirectory { directory in
    let prior = directory.appendingPathComponent("prior.sqlite")
    let priorResult = try LedgerStoreLifecycle.create(at: prior)
    let selected = directory.appendingPathComponent("denied.sqlite")
    let (bookmarks, defaults, suite) = try makeBookmarkStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    try bookmarks.save(prior)
    let states = WidgetStates()
    let journey = LedgerJourney()
    let session = LedgerSession(testingScopeStarter: { _ in true })
    let priorSnapshot = try journey.openValidatedLedger(priorResult.store, at: prior)
    #expect(session.openValidated(prior, snapshot: priorSnapshot))
    var lifecycleCalled = false

    let outcome = LedgerAtlasRootView.performLedgerLifecycle(
      .open, at: selected, bookmarkStore: bookmarks,
      widgetPublisher: .init(write: { states.append($0.state) }), journey: journey,
      session: session, scopeStarter: { _ in false }, scopeStopper: { _ in },
      lifecycle: { _, _ in
        lifecycleCalled = true
        throw FlowTestError.injected
      })

    #expect(outcome.kind == .failed)
    #expect(!lifecycleCalled)
    #expect(bookmarks.reopen(.canonicalLedger) == .resolved(prior))
    #expect(session.screen == .noLedger)
    #expect(journey.ledgerURL == nil)
    #expect(states.values == [.permissionDenied])
  }
}

@MainActor
@Test func cancelledSelectionLeavesThePriorSessionBookmarkAndWidgetUntouched() throws {
  try withFlowDirectory { directory in
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

    let outcome = LedgerAtlasRootView.performLedgerSelection(
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
  #expect(LedgerAtlasRootView.createLedgerPanelMessage == "Choose where to save the new ledger.")
  #expect(LedgerAtlasRootView.openLedgerPanelMessage == "Choose a Ledger Atlas ledger.")
}

private func withFlowDirectory(_ body: (URL) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try body(directory)
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
    defaults, suite)
}

private final class WidgetStates: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [RedactedWidgetProjection.State] = []

  var values: [RedactedWidgetProjection.State] { lock.withLock { storage } }
  func append(_ state: RedactedWidgetProjection.State) { lock.withLock { storage.append(state) } }
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
