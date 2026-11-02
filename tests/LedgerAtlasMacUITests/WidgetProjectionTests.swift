import Foundation
import LedgerAtlasMacUI
import Testing

@Test func redactedWidgetProjectionEncodesOnlyVersionStateAndSafeMessage() throws {
  let projection = RedactedWidgetProjection.permissionDenied
  let data = try JSONEncoder().encode(projection)
  let json = try #require(String(data: data, encoding: .utf8))

  #expect(projection.schemaVersion == 2)
  #expect(projection.state == .permissionDenied)
  #expect(!json.localizedCaseInsensitiveContains("amount"))
  #expect(!json.localizedCaseInsensitiveContains("name"))
  #expect(!json.localizedCaseInsensitiveContains("note"))
  #expect(!json.localizedCaseInsensitiveContains("path"))
  #expect(!json.localizedCaseInsensitiveContains("transaction"))
  #expect(!json.localizedCaseInsensitiveContains("account"))
  #expect(!json.localizedCaseInsensitiveContains("source"))
}

@Test func redactedWidgetProjectionProvidesSafeReopenState() {
  #expect(RedactedWidgetProjection.reopenRequired.state == .reopenRequired)
  #expect(RedactedWidgetProjection.reopenRequired.message == "Open Ledger Atlas to continue.")
}

@Test func redactedWidgetProjectionDerivesDisplayCopyFromItsFixedState() throws {
  let data = try JSONEncoder().encode(RedactedWidgetProjection(state: .ready))
  let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

  #expect(Set(object.keys) == ["schemaVersion", "state"])
  #expect(RedactedWidgetProjection(state: .ready).message == "Ledger Atlas is ready.")
}

@Test func redactedWidgetProjectionUsesFixedVoiceOverCopyForEveryState() {
  let expected: [(RedactedWidgetProjection.State, String)] = [
    (.empty, "Ledger Atlas. Open Ledger Atlas to get started."),
    (.permissionDenied, "Ledger Atlas. Allow access in Ledger Atlas to continue."),
    (.ready, "Ledger Atlas. Ledger Atlas is ready."),
    (.reopenRequired, "Ledger Atlas. Open Ledger Atlas to continue."),
    (.locked, "Ledger Atlas. Ledger Atlas is locked."),
  ]

  for (state, label) in expected {
    #expect(RedactedWidgetProjection(state: state).accessibilityLabel == label)
  }
}

@Test func securityScopedBookmarkStorePersistsAndReopensTheUserSelection() throws {
  let suite = "LedgerAtlasMacUITests.bookmark.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let selected = URL(fileURLWithPath: "/synthetic/ledger.sqlite")
  let store = SecurityScopedBookmarkStore(
    defaults: defaults,
    makeBookmark: { Data($0.path.utf8) },
    resolveBookmark: { URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)) })

  try store.save(selected)

  #expect(store.reopenURL() == selected)
}

@Test func projectionStoreReplacesPayloadsWithUnexpectedFields() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let store = RedactedWidgetProjectionStore(containerURL: directory)
  try Data(#"{"schemaVersion":1,"state":"ready","memo":"private"}"#.utf8).write(to: store.url)

  #expect(store.read() == .empty)
  let repaired = try #require(String(data: Data(contentsOf: store.url), encoding: .utf8))
  #expect(!repaired.contains("memo"))
}

@Test func staleCanonicalBookmarkWaitsForValidatedOpenBeforeRenewal() throws {
  let suite = "LedgerAtlasMacUITests.bookmark.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let selected = URL(fileURLWithPath: "/synthetic/ledger.sqlite")
  var writes = 0
  let store = SecurityScopedBookmarkStore(
    defaults: defaults,
    makeBookmark: { _ in writes += 1; return Data("renewed".utf8) },
    resolveBookmarkResult: { _ in .init(url: selected, isStale: true) })

  try store.save(selected, for: .canonicalLedger)

  // Resolving reports staleness but writes nothing: renewal is the caller's save after a
  // validated open (LA-031).
  #expect(store.reopen(.canonicalLedger) == .stale(selected))
  #expect(writes == 1)
  #expect(store.reopenURL() == nil)
  #expect(store.reopen(.importSource) == .missing)
}

@Test func staleBookmarkResolutionPreservesTheOriginal() throws {
  let suite = "LedgerAtlasMacUITests.bookmark.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let selected = URL(fileURLWithPath: "/synthetic/ledger.sqlite")
  let key = "\(SecurityScopedBookmarkStore.defaultKey).canonicalLedger"
  let store = SecurityScopedBookmarkStore(
    defaults: defaults,
    makeBookmark: { Data($0.path.utf8) },
    resolveBookmarkResult: { _ in .init(url: selected, isStale: true) })
  try store.save(selected)
  let original = try #require(defaults.data(forKey: key))

  #expect(store.reopen(.canonicalLedger) == .stale(selected))
  #expect(store.reopen(.canonicalLedger) == .stale(selected))
  #expect(defaults.data(forKey: key) == original)
}

@Test func widgetProjectionPublisherWritesOnlyFixedRuntimeStates() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let store = RedactedWidgetProjectionStore(containerURL: directory)
  let publisher = RedactedWidgetProjectionPublisher(store: store)

  try publisher.publish(.permissionDenied)
  #expect(store.read().state == .permissionDenied)
  try publisher.publish(.ready)
  #expect(store.read().state == .ready)
}

@Test func widgetProjectionPublisherReturnsWriteFailures() {
  let publisher = RedactedWidgetProjectionPublisher(write: { _ in
    throw CocoaError(.fileWriteNoPermission)
  })

  #expect(throws: CocoaError.self) { try publisher.publish(.ready) }
}

@Test func corruptCanonicalBookmarkIsPreservedWithoutTouchingImportSelection() throws {
  let suite = "LedgerAtlasMacUITests.bookmark.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let store = SecurityScopedBookmarkStore(
    defaults: defaults,
    makeBookmark: { Data($0.path.utf8) },
    resolveBookmark: {
      guard $0 != Data("corrupt".utf8) else { throw CocoaError(.fileReadCorruptFile) }
      return URL(fileURLWithPath: String(decoding: $0, as: UTF8.self))
    })
  try store.save(URL(fileURLWithPath: "/synthetic/import.mmbak"), for: .importSource)
  defaults.set(Data("corrupt".utf8), forKey: "\(SecurityScopedBookmarkStore.defaultKey).canonicalLedger")

  #expect(store.reopen(.canonicalLedger) == .corrupt)
  #expect(store.reopen(.canonicalLedger) == .corrupt)
  #expect(store.reopen(.importSource) == .resolved(URL(fileURLWithPath: "/synthetic/import.mmbak")))
}

@Test func widgetSummaryCarriesOnlyTwoCoarseFactsAndOnlyWhenReady() throws {
  let summary = RedactedWidgetProjection.Summary(entriesThisMonth: 12, budgets: .nearLimit)
  let ready = RedactedWidgetProjection(state: .ready, summary: summary)
  let data = try JSONEncoder().encode(ready)
  let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect(Set(object.keys) == ["schemaVersion", "state", "summary"])
  let inner = try #require(object["summary"] as? [String: Any])
  #expect(Set(inner.keys) == ["entriesThisMonth", "budgets"])
  #expect(try JSONDecoder().decode(RedactedWidgetProjection.self, from: data) == ready)
  #expect(ready.summaryLines == ["12 entries this month", "A budget is near its limit"])
  #expect(
    ready.accessibilityLabel
      == "Ledger Atlas. Ledger Atlas is ready. 12 entries this month. A budget is near its limit.")

  // A locked or closed ledger never carries a summary, even if one is passed.
  #expect(RedactedWidgetProjection(state: .locked, summary: summary).summary == nil)
  let leaked = Data(
    #"{"schemaVersion":2,"state":"locked","summary":{"entriesThisMonth":1,"budgets":"none"}}"#.utf8)
  #expect(throws: (any Error).self) {
    try JSONDecoder().decode(RedactedWidgetProjection.self, from: leaked)
  }
  let extra = Data(
    #"{"schemaVersion":2,"state":"ready","summary":{"entriesThisMonth":1,"budgets":"none","total":"9"}}"#
      .utf8)
  #expect(throws: (any Error).self) {
    try JSONDecoder().decode(RedactedWidgetProjection.self, from: extra)
  }
}

@Test func widgetReadsVersionOneFilesFromEarlierBuilds() throws {
  let v1 = Data(#"{"schemaVersion":1,"state":"ready"}"#.utf8)
  let decoded = try JSONDecoder().decode(RedactedWidgetProjection.self, from: v1)
  #expect(decoded.state == .ready && decoded.summary == nil && decoded.schemaVersion == 2)
  #expect(throws: (any Error).self) {
    try JSONDecoder().decode(
      RedactedWidgetProjection.self, from: Data(#"{"schemaVersion":3,"state":"ready"}"#.utf8))
  }
}

@Test func theWidgetsReadNeverWritesTheSharedFile() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let store = RedactedWidgetProjectionStore(containerURL: directory)

  #expect(store.readOnly() == .reopenRequired)
  #expect(!FileManager.default.fileExists(atPath: store.url.path))
  let damaged = Data("not json".utf8)
  try damaged.write(to: store.url)
  #expect(store.readOnly() == .reopenRequired)
  #expect(try Data(contentsOf: store.url) == damaged)

  try store.write(.locked)
  #expect(store.readOnly() == .locked)
}
