import Foundation
import LedgerAtlasMacUI
import Testing

@Test func redactedWidgetProjectionEncodesOnlyVersionStateAndSafeMessage() throws {
  let projection = RedactedWidgetProjection.permissionDenied
  let data = try JSONEncoder().encode(projection)
  let json = try #require(String(data: data, encoding: .utf8))

  #expect(projection.schemaVersion == 1)
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
