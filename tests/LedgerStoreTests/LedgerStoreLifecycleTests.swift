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
      if phase == .afterPublication || phase == .afterPublishedStoreOpened {
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
      #expect(
        retried.disposition
          == (phase == .afterPublication || phase == .afterPublishedStoreOpened
            ? .opened : .upgraded))
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

@Test func lifecycleRejectsRecoverySafetyChangesAfterReplacementValidationAndRetries() throws {
  enum Mutation { case mode, hardLink }
  for mutation in [Mutation.mode, .hardLink] {
    try withLifecycleDirectory { directory in
      let url = directory.appendingPathComponent("ledger.sqlite")
      _ = try writeV10Ledger(to: url)
      let original = try Data(contentsOf: url)
      let recovery = LedgerStoreLifecycle.recoveryImageURL(for: url)
      let linkedRecovery = directory.appendingPathComponent("linked-recovery.sqlite")

      #expect(throws: LedgerStoreLifecycle.Error.pathChanged) {
        try LedgerStoreLifecycle.open(at: url) { phase in
          guard phase == .afterReplacementValidated else { return }
          switch mutation {
          case .mode:
            guard chmod(recovery.path, mode_t(S_IRUSR | S_IWUSR | S_IRGRP)) == 0 else {
              throw LifecycleTestError.injected
            }
          case .hardLink:
            guard Darwin.link(recovery.path, linkedRecovery.path) == 0 else {
              throw LifecycleTestError.injected
            }
          }
        }
      }
      #expect(try Data(contentsOf: url) == original)

      switch mutation {
      case .mode:
        #expect(chmod(recovery.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
      case .hardLink:
        try FileManager.default.removeItem(at: linkedRecovery)
      }
      let retried = try LedgerStoreLifecycle.open(at: url)
      #expect(retried.disposition == .upgraded)
      #expect(try Data(contentsOf: recovery) == original)
    }
  }
}

@Test func lifecycleRollsBackPostPublicationRecoverySafetyChangesAndRetries() throws {
  enum Mutation { case mode, hardLink }
  for mutation in [Mutation.mode, .hardLink] {
    try withLifecycleDirectory { directory in
      let url = directory.appendingPathComponent("ledger.sqlite")
      _ = try writeV10Ledger(to: url)
      let original = try Data(contentsOf: url)
      let recovery = LedgerStoreLifecycle.recoveryImageURL(for: url)
      let linkedRecovery = directory.appendingPathComponent("linked-recovery.sqlite")

      #expect(throws: LedgerStoreLifecycle.Error.pathChanged) {
        try LedgerStoreLifecycle.open(at: url) { phase in
          guard phase == .afterPublication else { return }
          switch mutation {
          case .mode:
            guard chmod(recovery.path, mode_t(S_IRUSR | S_IWUSR | S_IRGRP)) == 0 else {
              throw LifecycleTestError.injected
            }
          case .hardLink:
            guard Darwin.link(recovery.path, linkedRecovery.path) == 0 else {
              throw LifecycleTestError.injected
            }
          }
        }
      }
      #expect(try Data(contentsOf: url) == original)
      #expect(try LedgerStoreLifecycle.inspect(at: url) == .upgradeRequired)

      switch mutation {
      case .mode:
        #expect(chmod(recovery.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
      case .hardLink:
        try FileManager.default.removeItem(at: linkedRecovery)
      }
      let retried = try LedgerStoreLifecycle.open(at: url)
      #expect(retried.disposition == .upgraded)
      #expect(try Data(contentsOf: recovery) == original)
    }
  }
}

@Test func lifecycleNeverRestoresSameSizeCorruptionOverTheCanonicalPath() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)
    let recovery = LedgerStoreLifecycle.recoveryImageURL(for: url)
    var corrupted = Data(repeating: 0x58, count: original.count)
    corrupted.replaceSubrange(0..<16, with: Data("not-a-sqlite-db!".utf8))

    #expect(throws: LedgerStoreLifecycle.Error.pathChanged) {
      try LedgerStoreLifecycle.open(at: url) { phase in
        guard phase == .afterPublication else { return }
        let sibling = try #require(
          FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
          ).first {
            $0.lastPathComponent.hasPrefix(".ledger-atlas-upgrade-")
              && $0.pathExtension == "tmp"
          })
        var before = stat()
        guard lstat(sibling.path, &before) == 0 else { throw LifecycleTestError.injected }
        try corrupted.write(to: sibling)
        var times = [before.st_atimespec, before.st_mtimespec]
        guard
          times.withUnsafeMutableBufferPointer({ values in
            utimensat(AT_FDCWD, sibling.path, values.baseAddress, 0)
          }) == 0,
          chmod(recovery.path, mode_t(S_IRUSR | S_IWUSR | S_IRGRP)) == 0
        else { throw LifecycleTestError.injected }
      }
    }

    #expect(try Data(contentsOf: url) != corrupted)
    #expect(try LedgerStoreLifecycle.inspect(at: url) == .current)
    #expect(try Data(contentsOf: recovery) == original)
    #expect(chmod(recovery.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
    #expect(try fileMode(recovery) == mode_t(S_IRUSR | S_IWUSR))
    let retried = try LedgerStoreLifecycle.open(at: url)
    #expect(retried.disposition == .opened)
    #expect(try Data(contentsOf: recovery) == original)
  }
}

@Test func lifecycleReauthenticatesRecoveryAfterOpeningPublishedStore() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)
    let recovery = LedgerStoreLifecycle.recoveryImageURL(for: url)
    var corrupted = original
    corrupted[corrupted.startIndex] ^= 0xff

    #expect(throws: LedgerStoreLifecycle.Error.pathChanged) {
      try LedgerStoreLifecycle.open(at: url) { phase in
        guard phase == .afterPublishedStoreOpened else { return }
        let descriptor = Darwin.open(recovery.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw LifecycleTestError.injected }
        defer { Darwin.close(descriptor) }
        var identity = stat()
        guard fstat(descriptor, &identity) == 0 else { throw LifecycleTestError.injected }
        let written = corrupted.withUnsafeBytes { bytes in
          Darwin.pwrite(descriptor, bytes.baseAddress, bytes.count, 0)
        }
        var times = [identity.st_atimespec, identity.st_mtimespec]
        guard written == corrupted.count, fsync(descriptor) == 0,
          times.withUnsafeMutableBufferPointer({ futimens(descriptor, $0.baseAddress) }) == 0,
          chmod(recovery.path, mode_t(S_IRUSR | S_IWUSR)) == 0
        else {
          throw LifecycleTestError.injected
        }
      }
    }

    #expect(try LedgerStoreLifecycle.inspect(at: url) == .current)
    let displaced = try #require(
      FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .first { $0.lastPathComponent.hasPrefix(".ledger-atlas-upgrade-") })
    #expect(try Data(contentsOf: displaced) == original)
    try original.write(to: recovery)
    #expect(chmod(recovery.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
    #expect(try LedgerStoreLifecycle.open(at: url).disposition == .opened)
    #expect(try Data(contentsOf: displaced) == original)
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

@Test func lifecycleRejectsSemanticallyInvalidExactV10ImportGraphsWithoutMutation() throws {
  try withLifecycleDirectory { directory in
    let valid = directory.appendingPathComponent("valid.sqlite")
    try writeV10ImportLedger(to: valid, mutation: "")
    let bytes = try Data(contentsOf: valid)
    #expect(try LedgerStoreLifecycle.inspect(at: valid) == .upgradeRequired)
    #expect(try Data(contentsOf: valid) == bytes)
  }
  let mutations = [
    "UPDATE economic_event SET amount_literal='1..2'",
    "UPDATE economic_event SET local_day=2",
    "DELETE FROM receipt_event",
    "DELETE FROM receipt_binding WHERE semantic='amount'",
    """
    INSERT INTO provenance_reference VALUES ('ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'profile', 'adapter', NULL, 'T', 'sidecar', 0, 'x');
    INSERT INTO sidecar_reference VALUES ('ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff', 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee', 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff', 1, 'INTEGER', 'integer', X'01');
    INSERT INTO receipt_sidecar VALUES ('6666666666666666666666666666666666666666666666666666666666666666', 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff', 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee', 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff')
    """,
    """
    INSERT INTO receipt_preservation_anchor VALUES ('9999999999999999999999999999999999999999999999999999999999999999', '6666666666666666666666666666666666666666666666666666666666666666', '8888888888888888888888888888888888888888888888888888888888888888', 'table', 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 'wrong-profile', 'adapter', NULL, 'T', NULL);
    INSERT INTO receipt_preservation_membership VALUES ('6666666666666666666666666666666666666666666666666666666666666666', '8888888888888888888888888888888888888888888888888888888888888888', 'table', '9999999999999999999999999999999999999999999999999999999999999999', '8888888888888888888888888888888888888888888888888888888888888888', 'table', NULL)
    """,
  ]
  for mutation in mutations {
    try withLifecycleDirectory { directory in
      let url = directory.appendingPathComponent("ledger.sqlite")
      try writeV10ImportLedger(to: url, mutation: mutation)
      let before = try Data(contentsOf: url)

      #expect(throws: LedgerStoreLifecycle.Error.invalidStore) {
        try LedgerStoreLifecycle.inspect(at: url)
      }
      #expect(throws: LedgerStoreLifecycle.Error.invalidStore) {
        try LedgerStoreLifecycle.open(at: url)
      }
      #expect(try Data(contentsOf: url) == before)
      #expect(!FileManager.default.fileExists(
        atPath: LedgerStoreLifecycle.recoveryImageURL(for: url).path))
      #expect(
        try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy {
          !$0.hasPrefix(".ledger-atlas-upgrade-")
        })
    }
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

private func writeV10ImportLedger(to url: URL, mutation: String) throws {
  var database: OpaquePointer?
  guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
    throw LifecycleTestError.sqlite
  }
  for object in CanonicalLedgerSchema.legacyV10Objects {
    guard sqlite3_exec(database, object.ddl, nil, nil, nil) == SQLITE_OK else {
      throw LifecycleTestError.sqlite
    }
  }
  let provenances = (1...5).map { String(repeating: String($0), count: 64) }
  let provenanceSQL = provenances.enumerated().map { index, id in
    "INSERT INTO provenance_reference VALUES ('\(id)', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'profile', 'adapter', NULL, 'T', 'row', \(index), 'c\(index)')"
  }.joined(separator: ";")
  let semantics = ["amount", "currency", "occurred_at", "account", "kind"]
  let bindings = zip(semantics, provenances).map { semantic, id in
    "INSERT INTO event_source_binding VALUES ('eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee', '\(semantic)', '\(id)', 'TEXT', 'text'); INSERT INTO receipt_binding VALUES ('6666666666666666666666666666666666666666666666666666666666666666', 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee', '\(semantic)', '\(id)')"
  }.joined(separator: ";")
  let sql = """
    PRAGMA application_id=\(CanonicalLedgerSchema.applicationID);
    INSERT INTO ledger_meta VALUES ('schema_version','10'), ('ledger_identity','ledger-atlas-canonical'), ('schema_fingerprint','\(CanonicalLedgerSchema.legacyV10Fingerprint)');
    \(provenanceSQL);
    INSERT INTO economic_event VALUES ('eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee', 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc', 'expense', '1.00', 'USD', 0, 1970, 1, 1, 0, 0, 0, 0, 'fixed', '0', 'millisecond', 0, 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd', '\(provenances[0])');
    INSERT INTO import_receipt VALUES ('6666666666666666666666666666666666666666666666666666666666666666', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'profile', 'adapter', 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc', 1, 8);
    INSERT INTO receipt_event VALUES ('6666666666666666666666666666666666666666666666666666666666666666', 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee');
    \(bindings);
    \(mutation);
    """
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK,
    sqlite3_close(database) == SQLITE_OK,
    chmod(url.path, mode_t(S_IRUSR | S_IWUSR)) == 0
  else { throw LifecycleTestError.sqlite }
}

private func fileMode(_ url: URL) throws -> mode_t {
  var value = stat()
  guard lstat(url.path, &value) == 0 else { throw LifecycleTestError.sqlite }
  return value.st_mode & mode_t(0o777)
}

private enum LifecycleTestError: Swift.Error { case sqlite, injected }
