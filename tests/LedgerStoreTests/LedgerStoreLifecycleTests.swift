import CSQLite
import Foundation
import LedgerCore
import Testing

@testable import LedgerStore

@Test func lifecycleCreatesOwnerOnlyExactV11WithoutOverwrite() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    let created = try LedgerStoreLifecycle.create(at: url)

    #expect(created.disposition == .created)
    #expect(created.recoveryImageURL == nil)
    #expect(try LedgerStoreLifecycle.inspect(at: url) == .current)
    #expect(created.store.schemaIdentity.version == 11)
    #expect(try created.store.readSnapshot().accounts.isEmpty)
    #expect(try fileMode(url) == mode_t(S_IRUSR | S_IWUSR))
    let bytes = try Data(contentsOf: url)

    #expect(throws: LedgerStoreLifecycle.Error.destinationExists) {
      try LedgerStoreLifecycle.create(at: url)
    }
    #expect(try Data(contentsOf: url) == bytes)
  }
}

@Test func lifecycleUpgradesExactV10AndPublishesAnExactRecoveryImage() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    let accountID = try writeV10Ledger(to: url)
    let v10Bytes = try Data(contentsOf: url)

    #expect(try LedgerStoreLifecycle.inspect(at: url) == .upgradeRequired)
    let upgraded = try LedgerStoreLifecycle.open(at: url)

    #expect(upgraded.disposition == .upgraded)
    let recovery = try #require(upgraded.recoveryImageURL)
    #expect(try Data(contentsOf: recovery) == v10Bytes)
    #expect(try fileMode(recovery) == mode_t(S_IRUSR | S_IWUSR))
    #expect(try LedgerStoreLifecycle.inspect(at: url) == .current)
    #expect(try upgraded.store.readSnapshot().accounts.map(\.id) == [accountID])
    #expect(try fileMode(url) == mode_t(S_IRUSR | S_IWUSR))
  }
}

@Test func lifecycleReopensACurrentStoreWithItsAuthenticatedInactiveJournal() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    do {
      let created = try LedgerStoreLifecycle.create(at: url)
      let origin = try LedgerOrigin(id: String(repeating: "3", count: 64), label: "synthetic")
      try created.store.createAccount(
        LedgerAccount(
          id: String(repeating: "4", count: 64), name: "Synthetic", currencyUnit: "USD",
          origin: origin))
    }
    #expect(FileManager.default.fileExists(atPath: url.path + "-journal"))
    #expect(FileManager.default.fileExists(atPath: url.path + "-journal.ledger-atlas-binding"))

    let reopened = try LedgerStoreLifecycle.open(at: url)
    #expect(reopened.disposition == .opened)
    #expect(try reopened.store.readSnapshot().accounts.count == 1)
  }
}

@Test func lifecycleCreationFailuresNeverPublishAnInvalidDestination() throws {
  for phase in LedgerStoreLifecycle.TestPhase.creationPhases {
    try withLifecycleDirectory { directory in
      let url = directory.appendingPathComponent("ledger.sqlite")
      #expect(throws: LedgerStoreLifecycle.Error.interrupted) {
        try LedgerStoreLifecycle.create(at: url) { reached in
          if reached == phase { throw LifecycleTestError.injected }
        }
      }
      if phase == .afterPublication {
        let inspection = try LedgerStoreLifecycle.inspect(at: url)
        #expect(inspection == .current)
      } else {
        #expect(!FileManager.default.fileExists(atPath: url.path))
      }
    }
  }
}

@Test func lifecycleUpgradeFailuresLeaveV10AtThePathOrInTheRecoveryImage() throws {
  for phase in LedgerStoreLifecycle.TestPhase.upgradePhases {
    try withLifecycleDirectory { directory in
      let url = directory.appendingPathComponent("ledger.sqlite")
      _ = try writeV10Ledger(to: url)
      let v10Bytes = try Data(contentsOf: url)
      #expect(throws: LedgerStoreLifecycle.Error.interrupted) {
        try LedgerStoreLifecycle.open(at: url) { reached in
          if reached == phase { throw LifecycleTestError.injected }
        }
      }
      if phase == .afterPublication {
        let inspection = try LedgerStoreLifecycle.inspect(at: url)
        #expect(inspection == .current)
      } else {
        #expect(try Data(contentsOf: url) == v10Bytes)
      }
      let recovery = LedgerStoreLifecycle.recoveryImageURL(for: url)
      if FileManager.default.fileExists(atPath: recovery.path) {
        #expect(try Data(contentsOf: recovery) == v10Bytes)
        #expect(try fileMode(recovery) == mode_t(S_IRUSR | S_IWUSR))
      }
    }
  }
}

@Test func lifecycleRetriesEveryFailureAfterPublishingAValidatedRecoveryImage() throws {
  let phases: [LedgerStoreLifecycle.TestPhase] = [
    .afterRecoveryPublished, .afterReplacementCreated, .afterReplacementMigrated,
    .afterReplacementValidated, .afterPublication,
  ]
  for phase in phases {
    try withLifecycleDirectory { directory in
      let url = directory.appendingPathComponent("ledger.sqlite")
      _ = try writeV10Ledger(to: url)
      let v10Bytes = try Data(contentsOf: url)
      #expect(throws: LedgerStoreLifecycle.Error.interrupted) {
        try LedgerStoreLifecycle.open(at: url) { reached in
          if reached == phase { throw LifecycleTestError.injected }
        }
      }

      let retried = try LedgerStoreLifecycle.open(at: url)
      #expect(retried.disposition == (phase == .afterPublication ? .opened : .upgraded))
      let recovery = LedgerStoreLifecycle.recoveryImageURL(for: url)
      #expect(try Data(contentsOf: recovery) == v10Bytes)
      #expect(try LedgerStoreLifecycle.inspect(at: url) == .current)
    }
  }
}

@Test func lifecycleRejectsUntrustedExistingRecoveryImagesWithoutMutatingV10() throws {
  enum RecoveryKind { case mismatched, unsafeMode, symlink, companion }
  for kind in [RecoveryKind.mismatched, .unsafeMode, .symlink, .companion] {
    try withLifecycleDirectory { directory in
      let url = directory.appendingPathComponent("ledger.sqlite")
      _ = try writeV10Ledger(to: url)
      let original = try Data(contentsOf: url)
      let recovery = LedgerStoreLifecycle.recoveryImageURL(for: url)
      switch kind {
      case .mismatched:
        try Data("not a ledger".utf8).write(to: recovery)
        #expect(chmod(recovery.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
      case .unsafeMode:
        try original.write(to: recovery)
        #expect(chmod(recovery.path, mode_t(S_IRUSR | S_IWUSR | S_IRGRP)) == 0)
      case .symlink:
        #expect(Darwin.symlink(url.path, recovery.path) == 0)
      case .companion:
        try original.write(to: recovery)
        #expect(chmod(recovery.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
        try Data().write(to: URL(fileURLWithPath: recovery.path + "-wal"))
      }

      #expect(throws: LedgerStoreLifecycle.Error.recoveryImageExists) {
        try LedgerStoreLifecycle.open(at: url)
      }
      #expect(try Data(contentsOf: url) == original)
    }
  }
}

@Test func lifecycleRefusesSymlinksCompanionsAndAuthenticatedPathSwaps() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)
    let symlink = directory.appendingPathComponent("symlink.sqlite")
    #expect(Darwin.symlink(url.path, symlink.path) == 0)
    #expect(throws: LedgerStoreLifecycle.Error.unsafePath) {
      try LedgerStoreLifecycle.open(at: symlink)
    }

    let companion = URL(fileURLWithPath: url.path + "-wal")
    try Data().write(to: companion)
    #expect(throws: LedgerStoreLifecycle.Error.companionPresent) {
      try LedgerStoreLifecycle.open(at: url)
    }
    try FileManager.default.removeItem(at: companion)

    let parked = directory.appendingPathComponent("parked.sqlite")
    let replacement = directory.appendingPathComponent("replacement.sqlite")
    _ = try writeV10Ledger(to: replacement)
    let replacementBytes = try Data(contentsOf: replacement)
    #expect(throws: LedgerStoreLifecycle.Error.pathChanged) {
      try LedgerStoreLifecycle.open(at: url) { phase in
        guard phase == .afterSourceAuthenticated else { return }
        #expect(Darwin.rename(url.path, parked.path) == 0)
        #expect(Darwin.rename(replacement.path, url.path) == 0)
      }
    }
    #expect(try Data(contentsOf: parked) == original)
    #expect(try Data(contentsOf: url) == replacementBytes)
  }
}

@Test func lifecycleInspectAndOpenRejectForgedInactiveJournalBindings() throws {
  for operation in ["inspect", "open"] {
    try withLifecycleDirectory { directory in
      let url = directory.appendingPathComponent("ledger.sqlite")
      do {
        let created = try LedgerStoreLifecycle.create(at: url)
        let origin = try LedgerOrigin(id: String(repeating: "3", count: 64), label: "synthetic")
        try created.store.createAccount(
          LedgerAccount(
            id: String(repeating: "4", count: 64), name: "Synthetic", currencyUnit: "USD",
            origin: origin))
      }
      let binding = URL(fileURLWithPath: url.path + "-journal.ledger-atlas-binding")
      let authenticBinding = try Data(contentsOf: binding)
      try Data(repeating: 0x78, count: authenticBinding.count).write(to: binding)
      #expect(chmod(binding.path, mode_t(S_IRUSR | S_IWUSR)) == 0)

      #expect(throws: LedgerStoreLifecycle.Error.companionPresent) {
        if operation == "inspect" {
          _ = try LedgerStoreLifecycle.inspect(at: url)
        } else {
          _ = try LedgerStoreLifecycle.open(at: url)
        }
      }
    }
  }
}

@Test func lifecycleErrorsDoNotIncludePathsOrLedgerValues() throws {
  try withLifecycleDirectory { directory in
    let sentinel = "PRIVATE_LEDGER_SENTINEL"
    let url = directory.appendingPathComponent(sentinel)
    try Data(sentinel.utf8).write(to: url)
    #expect(chmod(url.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
    do {
      _ = try LedgerStoreLifecycle.open(at: url)
      Issue.record("expected invalid store")
    } catch {
      #expect(error is LedgerStoreLifecycle.Error)
      #expect(!String(describing: error).contains(sentinel))
      #expect(!String(describing: error).contains(url.path))
    }
  }
}

@Test func lifecycleDistinguishesUnsupportedCanonicalVersionsWithoutMutation() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
      throw LifecycleTestError.sqlite
    }
    guard
      sqlite3_exec(
        database,
        "UPDATE ledger_meta SET value='12' WHERE key='schema_version'; UPDATE ledger_meta SET value='future' WHERE key='schema_fingerprint'",
        nil, nil, nil) == SQLITE_OK,
      sqlite3_close(database) == SQLITE_OK
    else { throw LifecycleTestError.sqlite }
    let before = try Data(contentsOf: url)

    #expect(throws: LedgerStoreLifecycle.Error.unsupportedStore) {
      try LedgerStoreLifecycle.open(at: url)
    }
    #expect(try Data(contentsOf: url) == before)
  }
}

private func withLifecycleDirectory(_ body: (URL) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try body(directory)
}

private func writeV10Ledger(to url: URL) throws -> String {
  var database: OpaquePointer?
  guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
    throw LifecycleTestError.sqlite
  }
  for object in CanonicalLedgerSchema.legacyV10Objects {
    guard sqlite3_exec(database, object.ddl, nil, nil, nil) == SQLITE_OK else {
      throw LifecycleTestError.sqlite
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
    sqlite3_close(database) == SQLITE_OK,
    chmod(url.path, mode_t(S_IRUSR | S_IWUSR)) == 0
  else { throw LifecycleTestError.sqlite }
  return accountID
}

private func fileMode(_ url: URL) throws -> mode_t {
  var value = stat()
  guard lstat(url.path, &value) == 0 else { throw LifecycleTestError.sqlite }
  return value.st_mode & mode_t(0o777)
}

private enum LifecycleTestError: Swift.Error { case sqlite, injected }
