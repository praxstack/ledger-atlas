import CSQLite
import CryptoKit
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
    #expect(created.store.schemaIdentity.version == 12)
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

@Test func lifecycleUpgradesExactV10WithItsAuthenticatedInactiveJournal() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    let accountID = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)
    try writeInactiveJournalBinding(for: url)

    #expect(try LedgerStoreLifecycle.inspect(at: url) == .upgradeRequired)
    let upgraded = try LedgerStoreLifecycle.open(at: url)

    #expect(upgraded.disposition == .upgraded)
    #expect(try Data(contentsOf: #require(upgraded.recoveryImageURL)) == original)
    #expect(try upgraded.store.readSnapshot().accounts.map(\.id) == [accountID])
    #expect(try Data(contentsOf: URL(fileURLWithPath: url.path + "-journal")).isEmpty)
    #expect(try LedgerStoreLifecycle.open(at: url).disposition == .opened)
  }
}

@Test func lifecycleRestartRetargetsAuthenticatedJournalAfterTheCanonicalSwap() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    let accountID = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)
    try writeInactiveJournalBinding(for: url)

    #expect(
      throws: LedgerStoreLifecycle.Error.publicationCompleted(
        phase: .currentPublished, recoveryImageExists: true
      )
    ) {
      try LedgerStoreLifecycle.open(at: url) { phase in
        if phase == .afterSwapBeforeJournalRetarget { throw LifecycleTestError.injected }
      }
    }

    let reopened = try LedgerStoreLifecycle.open(at: url)
    #expect(reopened.disposition == .opened)
    #expect(try reopened.store.readSnapshot().accounts.map(\.id) == [accountID])
    #expect(try Data(contentsOf: #require(reopened.recoveryImageURL)) == original)
    #expect(try Data(contentsOf: URL(fileURLWithPath: url.path + "-journal")).isEmpty)
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
      let expected: LedgerStoreLifecycle.Error =
        phase == .afterPublication
        ? .publicationCompleted(phase: .currentPublished, recoveryImageExists: false)
        : .interrupted
      #expect(throws: expected) {
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

@Test func lifecycleFailedCreationRemovesItsEmptyOperationTemporary() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")

    #expect(throws: LedgerStoreLifecycle.Error.interrupted) {
      try LedgerStoreLifecycle.create(at: url) { phase in
        if phase == .afterTemporaryCreated { throw LifecycleTestError.injected }
      }
    }

    let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(remaining.allSatisfy { !$0.hasPrefix(lifecycleTemporaryPrefix(url, "create")) })
  }
}

@Test func lifecyclePartialWriteFailureDoesNotAccumulateTemporaryFiles() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    for _ in 0..<3 {
      #expect(throws: LedgerStoreLifecycle.Error.interrupted) {
        try LedgerStoreLifecycle.create(at: url) { phase in
          if phase == .afterTemporaryWriteBeforeRecord { throw LifecycleTestError.injected }
        }
      }
      let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      #expect(remaining.allSatisfy { !$0.hasPrefix(lifecycleTemporaryPrefix(url, "create")) })
    }
  }
}

@Test func lifecycleDetectsAReplacementAtTheFinalCreatePublicationSeam() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    let parked = directory.appendingPathComponent("parked-create.sqlite")
    let sentinel = Data("create publication sentinel".utf8)
    var replacedTemporary: URL?

    #expect(throws: LedgerStoreLifecycle.Error.pathChanged) {
      try LedgerStoreLifecycle.create(at: url) { phase in
        guard phase == .beforeCreatePublication else { return }
        let temporary = try #require(
          FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(lifecycleTemporaryPrefix(url, "create")) })
        replacedTemporary = temporary
        #expect(Darwin.rename(temporary.path, parked.path) == 0)
        try sentinel.write(to: temporary)
        #expect(chmod(temporary.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
      }
    }

    let parkedBytes = try Data(contentsOf: parked)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(!parkedBytes.isEmpty)
    let replaced = try #require(replacedTemporary)
    #expect(replaced.lastPathComponent.hasPrefix(lifecycleTemporaryPrefix(url, "create")))
    #expect(try Data(contentsOf: replaced) == sentinel)
  }
}

@Test func lifecycleCreatePostRenameDirectorySyncFailureKeepsPublishedBytes() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    #expect(
      throws: LedgerStoreLifecycle.Error.publicationCompleted(
        phase: .currentPublished, recoveryImageExists: false
      )
    ) {
      try LedgerStoreLifecycle.create(at: url) { phase in
        if phase == .afterCreateRenameBeforeDirectorySync { throw LifecycleTestError.injected }
      }
    }
    let inspection = try LedgerStoreLifecycle.inspect(at: url)
    let bytes = try Data(contentsOf: url)
    #expect(inspection == .current)
    #expect(!bytes.isEmpty)
  }
}

@Test func lifecycleCreateDeferredCleanupDoesNotTruncateRenamedTemporary() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    let parked = directory.appendingPathComponent("parked-create.sqlite")
    let sentinel = Data("create deferred-cleanup sentinel".utf8)

    #expect(throws: LedgerStoreLifecycle.Error.interrupted) {
      try LedgerStoreLifecycle.create(at: url) { phase in
        guard phase == .afterTemporaryCreated else { return }
        let temporary = try #require(
          FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(lifecycleTemporaryPrefix(url, "create")) })
        #expect(Darwin.rename(temporary.path, parked.path) == 0)
        try overwriteInPlace(sentinel, at: parked)
        throw LifecycleTestError.injected
      }
    }

    #expect(!FileManager.default.fileExists(atPath: url.path))
    let parkedBytes = try Data(contentsOf: parked)
    #expect(parkedBytes == sentinel)
  }
}

@Test func lifecycleCreateRejectsRenamedTemporaryBeforeWriting() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    let parked = directory.appendingPathComponent("parked-create-before-write.sqlite")
    let sentinel = Data("create pre-write sentinel".utf8)

    #expect(throws: LedgerStoreLifecycle.Error.pathChanged) {
      try LedgerStoreLifecycle.create(at: url) { phase in
        guard phase == .afterTemporaryCreated else { return }
        let temporary = try #require(
          FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(lifecycleTemporaryPrefix(url, "create")) })
        #expect(Darwin.rename(temporary.path, parked.path) == 0)
        try overwriteInPlace(sentinel, at: parked)
      }
    }

    #expect(!FileManager.default.fileExists(atPath: url.path))
    let parkedBytes = try Data(contentsOf: parked)
    #expect(parkedBytes == sentinel)
  }
}

@Test func lifecycleCreateRejectsRenamedTemporaryBeforePublication() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    let parked = directory.appendingPathComponent("parked-create-before-publication.sqlite")
    let sentinel = Data("create pre-publication sentinel".utf8)
    var replacedTemporary: URL?

    #expect(throws: LedgerStoreLifecycle.Error.pathChanged) {
      try LedgerStoreLifecycle.create(at: url) { phase in
        guard phase == .afterTemporaryValidated else { return }
        let temporary = try #require(
          FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(lifecycleTemporaryPrefix(url, "create")) })
        #expect(Darwin.rename(temporary.path, parked.path) == 0)
        try sentinel.write(to: temporary)
        #expect(chmod(temporary.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
        replacedTemporary = temporary
      }
    }

    #expect(!FileManager.default.fileExists(atPath: url.path))
    let parkedBytes = try Data(contentsOf: parked)
    let replacedBytes = try Data(contentsOf: #require(replacedTemporary))
    #expect(!parkedBytes.isEmpty)
    #expect(replacedBytes == sentinel)
  }
}

@Test func lifecycleCreateRejectsCompanionsAddedBeforePublication() throws {
  for suffix in ["-journal", "-journal.ledger-atlas-binding", "-wal", "-shm"] {
    try withLifecycleDirectory { directory in
      let url = directory.appendingPathComponent("ledger.sqlite")
      let companion = URL(fileURLWithPath: url.path + suffix)
      let bytes = Data("create companion sentinel (suffix)".utf8)

      #expect(throws: LedgerStoreLifecycle.Error.companionPresent) {
        try LedgerStoreLifecycle.create(at: url) { phase in
          guard phase == .afterTemporaryValidated else { return }
          try bytes.write(to: companion)
          #expect(chmod(companion.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
        }
      }

      #expect(!FileManager.default.fileExists(atPath: url.path))
      let companionBytes = try Data(contentsOf: companion)
      #expect(companionBytes == bytes)
    }
  }
}

@Test func lifecycleRecoveryPostRenameDirectorySyncFailureKeepsRecoveryBytes() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)
    #expect(
      throws: LedgerStoreLifecycle.Error.publicationCompleted(
        phase: .recoveryPublished, recoveryImageExists: true
      )
    ) {
      try LedgerStoreLifecycle.open(at: url) { phase in
        if phase == .afterRecoveryRenameBeforeDirectorySync { throw LifecycleTestError.injected }
      }
    }
    #expect(try Data(contentsOf: url) == original)
    #expect(try Data(contentsOf: LedgerStoreLifecycle.recoveryImageURL(for: url)) == original)
  }
}

@Test func lifecycleUpgradeRejectsRenamedRecoveryTemporaryBeforeCopying() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)
    let parked = directory.appendingPathComponent("parked-recovery-before-copy.sqlite")
    let sentinel = Data("recovery pre-copy sentinel".utf8)

    #expect(throws: LedgerStoreLifecycle.Error.pathChanged) {
      try LedgerStoreLifecycle.open(at: url) { phase in
        guard phase == .afterRecoveryCreated else { return }
        let temporary = try #require(
          FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(lifecycleTemporaryPrefix(url, "recovery")) })
        #expect(Darwin.rename(temporary.path, parked.path) == 0)
        try overwriteInPlace(sentinel, at: parked)
      }
    }

    #expect(try Data(contentsOf: url) == original)
    #expect(try Data(contentsOf: parked) == sentinel)
    #expect(
      !FileManager.default.fileExists(
        atPath: LedgerStoreLifecycle.recoveryImageURL(for: url).path))
  }
}

@Test func lifecycleUpgradeDeferredCleanupDoesNotTruncateRenamedReplacement() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)
    let parked = directory.appendingPathComponent("parked-replacement.sqlite")
    let sentinel = Data("replacement deferred-cleanup sentinel".utf8)

    #expect(
      throws: LedgerStoreLifecycle.Error.publicationCompleted(
        phase: .recoveryPublished, recoveryImageExists: true
      )
    ) {
      try LedgerStoreLifecycle.open(at: url) { phase in
        guard phase == .afterReplacementCreated else { return }
        let temporary = try #require(
          FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(lifecycleTemporaryPrefix(url, "upgrade")) })
        #expect(Darwin.rename(temporary.path, parked.path) == 0)
        try overwriteInPlace(sentinel, at: parked)
        throw LifecycleTestError.injected
      }
    }

    #expect(try Data(contentsOf: url) == original)
    #expect(try Data(contentsOf: parked) == sentinel)
    #expect(try Data(contentsOf: LedgerStoreLifecycle.recoveryImageURL(for: url)) == original)
  }
}

@Test func lifecycleUpgradeRejectsRenamedReplacementBeforeWriting() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)
    let recovery = LedgerStoreLifecycle.recoveryImageURL(for: url)
    let parked = directory.appendingPathComponent("parked-replacement-before-write.sqlite")
    let sentinel = Data("replacement pre-write sentinel".utf8)

    #expect(
      throws: LedgerStoreLifecycle.Error.publicationCompleted(
        phase: .recoveryPublished, recoveryImageExists: true
      )
    ) {
      try LedgerStoreLifecycle.open(at: url) { phase in
        guard phase == .afterReplacementCreated else { return }
        let temporary = try #require(
          FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(lifecycleTemporaryPrefix(url, "upgrade")) })
        #expect(Darwin.rename(temporary.path, parked.path) == 0)
        try overwriteInPlace(sentinel, at: parked)
      }
    }

    #expect(try Data(contentsOf: url) == original)
    #expect(try Data(contentsOf: recovery) == original)
    #expect(try Data(contentsOf: parked) == sentinel)
  }
}

@Test func lifecycleUpgradeRejectsCanonicalPathReplacementBeforeRecoveryPublication() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)
    let parked = directory.appendingPathComponent("parked-recovery-source.sqlite")
    let sentinel = Data("recovery source path sentinel".utf8)

    #expect(throws: LedgerStoreLifecycle.Error.pathChanged) {
      try LedgerStoreLifecycle.open(at: url) { phase in
        guard phase == .afterRecoveryValidated else { return }
        #expect(Darwin.rename(url.path, parked.path) == 0)
        try sentinel.write(to: url)
        #expect(chmod(url.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
      }
    }

    #expect(try Data(contentsOf: parked) == original)
    #expect(try Data(contentsOf: url) == sentinel)
    #expect(
      !FileManager.default.fileExists(
        atPath: LedgerStoreLifecycle.recoveryImageURL(for: url).path))
  }
}

@Test func lifecycleUpgradeRejectsCompanionsAddedBeforeRecoveryPublication() throws {
  for suffix in ["-journal", "-journal.ledger-atlas-binding", "-wal", "-shm"] {
    try withLifecycleDirectory { directory in
      let url = directory.appendingPathComponent("ledger.sqlite")
      _ = try writeV10Ledger(to: url)
      let original = try Data(contentsOf: url)
      let companion = URL(fileURLWithPath: url.path + suffix)
      let bytes = Data("recovery companion sentinel (suffix)".utf8)

      #expect(throws: LedgerStoreLifecycle.Error.companionPresent) {
        try LedgerStoreLifecycle.open(at: url) { phase in
          guard phase == .afterRecoveryValidated else { return }
          try bytes.write(to: companion)
          #expect(chmod(companion.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
        }
      }

      #expect(try Data(contentsOf: url) == original)
      #expect(try Data(contentsOf: companion) == bytes)
      #expect(
        !FileManager.default.fileExists(
          atPath: LedgerStoreLifecycle.recoveryImageURL(for: url).path))
    }
  }
}

@Test func lifecycleUpgradeFailuresLeaveV10AtThePathOrInTheRecoveryImage() throws {
  for phase in LedgerStoreLifecycle.TestPhase.upgradePhases {
    try withLifecycleDirectory { directory in
      let url = directory.appendingPathComponent("ledger.sqlite")
      _ = try writeV10Ledger(to: url)
      let v10Bytes = try Data(contentsOf: url)
      let outcome = Result {
        try LedgerStoreLifecycle.open(at: url) { reached in
          if reached == phase { throw LifecycleTestError.injected }
        }
      }
      guard case .failure(let error as LedgerStoreLifecycle.Error) = outcome else {
        throw LifecycleTestError.injected
      }
      switch phase {
      case .afterRecoveryPublished, .beforeRecoveryDescriptorDup, .afterReplacementCreated,
        .afterReplacementMigrated,
        .afterReplacementValidated, .beforeUpgradeStatePublication, .afterUpgradeStatePublished:
        #expect(
          error == .publicationCompleted(phase: .recoveryPublished, recoveryImageExists: true),
          "phase: \(phase)")
      case .afterSwapBeforeValidation, .afterPublication, .afterPublishedStoreOpened,
        .beforeDisplacedTruncate:
        #expect(
          error == .publicationCompleted(phase: .currentPublished, recoveryImageExists: true),
          "phase: \(phase)")
      default: #expect(error == .interrupted, "phase: \(phase)")
      }
      if phase == .afterSwapBeforeValidation || phase == .afterPublication
        || phase == .afterPublishedStoreOpened
        || phase == .beforeDisplacedTruncate
      {
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
      let outcome = Result {
        try LedgerStoreLifecycle.open(at: url) { reached in
          if reached == phase { throw LifecycleTestError.injected }
        }
      }
      guard case .failure(let error as LedgerStoreLifecycle.Error) = outcome else {
        throw LifecycleTestError.injected
      }
      #expect(
        error
          == (phase == .afterPublication
            ? .publicationCompleted(phase: .currentPublished, recoveryImageExists: true)
            : .publicationCompleted(phase: .recoveryPublished, recoveryImageExists: true)))

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

      #expect(
        throws: LedgerStoreLifecycle.Error.publicationCompleted(
          phase: .recoveryPublished, recoveryImageExists: false
        )
      ) {
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

@Test func lifecycleKeepsPublishedCurrentWhenPostPublicationRecoveryBecomesUnsafe() throws {
  enum Mutation { case mode, hardLink }
  for mutation in [Mutation.mode, .hardLink] {
    try withLifecycleDirectory { directory in
      let url = directory.appendingPathComponent("ledger.sqlite")
      _ = try writeV10Ledger(to: url)
      let original = try Data(contentsOf: url)
      let recovery = LedgerStoreLifecycle.recoveryImageURL(for: url)
      let linkedRecovery = directory.appendingPathComponent("linked-recovery.sqlite")

      #expect(
        throws: LedgerStoreLifecycle.Error.publicationCompleted(
          phase: .currentPublished, recoveryImageExists: false
        ), "mutation: \(String(describing: mutation))"
      ) {
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
      #expect(try Data(contentsOf: url) != original)
      #expect(try LedgerStoreLifecycle.inspect(at: url) == .current)

      switch mutation {
      case .mode:
        #expect(chmod(recovery.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
      case .hardLink:
        try FileManager.default.removeItem(at: linkedRecovery)
      }
      let retried = try LedgerStoreLifecycle.open(at: url)
      #expect(retried.disposition == .opened)
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

    #expect(
      throws: LedgerStoreLifecycle.Error.publicationCompleted(
        phase: .currentPublished, recoveryImageExists: false
      )
    ) {
      try LedgerStoreLifecycle.open(at: url) { phase in
        guard phase == .afterPublication else { return }
        let sibling = try #require(
          FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
          ).first {
            $0.lastPathComponent.hasPrefix(lifecycleTemporaryPrefix(url, "upgrade"))
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
    #expect(throws: LedgerStoreLifecycle.Error.pathChanged) {
      try LedgerStoreLifecycle.open(at: url)
    }
    #expect(try LedgerStoreLifecycle.inspect(at: url) == .current)
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

    #expect(
      throws: LedgerStoreLifecycle.Error.publicationCompleted(
        phase: .currentPublished, recoveryImageExists: false
      )
    ) {
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
        .first { $0.lastPathComponent.hasPrefix(lifecycleTemporaryPrefix(url, "upgrade")) })
    #expect(try Data(contentsOf: displaced) == original)
    try original.write(to: recovery)
    #expect(chmod(recovery.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
    #expect(try LedgerStoreLifecycle.open(at: url).disposition == .opened)
    #expect(try Data(contentsOf: displaced).isEmpty)
  }
}

@Test func lifecycleReauthenticatesRecoveryAtTheDestructiveBoundary() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)
    let recovery = LedgerStoreLifecycle.recoveryImageURL(for: url)
    var corrupted = original
    corrupted[corrupted.startIndex] ^= 0xff

    #expect(
      throws: LedgerStoreLifecycle.Error.publicationCompleted(
        phase: .currentPublished, recoveryImageExists: false
      )
    ) {
      try LedgerStoreLifecycle.open(at: url) { phase in
        guard phase == .beforeDisplacedTruncate else { return }
        let descriptor = Darwin.open(recovery.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw LifecycleTestError.injected }
        defer { Darwin.close(descriptor) }
        var identity = stat()
        guard fstat(descriptor, &identity) == 0 else { throw LifecycleTestError.injected }
        let written = corrupted.withUnsafeBytes {
          Darwin.pwrite(descriptor, $0.baseAddress, $0.count, 0)
        }
        var times = [identity.st_atimespec, identity.st_mtimespec]
        guard written == corrupted.count, fsync(descriptor) == 0,
          times.withUnsafeMutableBufferPointer({ futimens(descriptor, $0.baseAddress) }) == 0
        else { throw LifecycleTestError.injected }
      }
    }

    let displaced = try #require(
      FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .first { $0.lastPathComponent.hasPrefix(lifecycleTemporaryPrefix(url, "upgrade")) })
    #expect(try Data(contentsOf: displaced) == original)
    #expect(try Data(contentsOf: recovery) == corrupted)
    #expect(try LedgerStoreLifecycle.inspect(at: url) == .current)
  }
}

@Test func lifecycleReauthenticatesRecoveryImmediatelyBeforeRestartReconciliation() throws {
  enum Mutation { case corrupt, replacePath, unsafeMode, hardLink, companion }
  for mutation in [Mutation.corrupt, .replacePath, .unsafeMode, .hardLink, .companion] {
    try withLifecycleDirectory { directory in
      let url = directory.appendingPathComponent("ledger.sqlite")
      _ = try writeV10Ledger(to: url)
      let original = try Data(contentsOf: url)
      let recovery = LedgerStoreLifecycle.recoveryImageURL(for: url)
      #expect(
        throws: LedgerStoreLifecycle.Error.publicationCompleted(
          phase: .currentPublished, recoveryImageExists: true
        )
      ) {
        try LedgerStoreLifecycle.open(at: url) { phase in
          if phase == .afterPublication { throw LifecycleTestError.injected }
        }
      }
      let displaced = try #require(
        FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
          .first { $0.lastPathComponent.hasPrefix(lifecycleTemporaryPrefix(url, "upgrade")) })

      #expect(
        throws: LedgerStoreLifecycle.Error.publicationCompleted(
          phase: .currentPublished, recoveryImageExists: false
        )
      ) {
        try LedgerStoreLifecycle.open(at: url) { phase in
          guard phase == .beforeReconciliationMutation else { return }
          switch mutation {
          case .corrupt:
            var corrupted = original
            corrupted[corrupted.startIndex] ^= 0xff
            try corrupted.write(to: recovery)
          case .replacePath:
            let parked = directory.appendingPathComponent("parked-recovery.sqlite")
            #expect(Darwin.rename(recovery.path, parked.path) == 0)
            try original.write(to: recovery)
          case .unsafeMode:
            #expect(chmod(recovery.path, mode_t(S_IRUSR | S_IWUSR | S_IRGRP)) == 0)
          case .hardLink:
            #expect(
              Darwin.link(recovery.path, directory.appendingPathComponent("recovery-link").path)
                == 0)
          case .companion:
            try Data().write(to: URL(fileURLWithPath: recovery.path + "-wal"))
          }
          switch mutation {
          case .corrupt, .replacePath:
            #expect(chmod(recovery.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
          case .unsafeMode, .hardLink, .companion:
            break
          }
        }
      }
      #expect(try Data(contentsOf: displaced) == original)
      #expect(try LedgerStoreLifecycle.inspect(at: url) == .current)
    }
  }
}

@Test func lifecycleNeverRollsBackCurrentWhenTheDisplacedPathIsRacedAfterSwap() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)
    let parked = directory.appendingPathComponent("parked-v10.sqlite")
    let sentinel = Data("unrelated sentinel".utf8)
    var racedLeaf: URL?

    #expect(
      throws: LedgerStoreLifecycle.Error.publicationCompleted(
        phase: .currentPublished, recoveryImageExists: true
      )
    ) {
      try LedgerStoreLifecycle.open(at: url) { phase in
        guard phase == .afterSwapBeforeValidation else { return }
        let displaced = try #require(
          FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(lifecycleTemporaryPrefix(url, "upgrade")) })
        #expect(Darwin.rename(displaced.path, parked.path) == 0)
        try sentinel.write(to: displaced)
        #expect(chmod(displaced.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
        racedLeaf = displaced
      }
    }
    #expect(try LedgerStoreLifecycle.inspect(at: url) == .current)
    #expect(try Data(contentsOf: parked) == original)
    #expect(try Data(contentsOf: #require(racedLeaf)) == sentinel)
  }
}

@Test func lifecycleRestartFailsClosedAndPreservesUnboundLifecycleTemporaries() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)
    let migrationOracle = directory.appendingPathComponent("migration-oracle.sqlite")
    try original.write(to: migrationOracle)
    #expect(chmod(migrationOracle.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
    _ = try LedgerStoreLifecycle.open(at: migrationOracle)
    let migrated = try Data(contentsOf: migrationOracle)
    // Equivalent to a process ending between durable temporary writes and publication.
    let recoveryTemporary = directory.appendingPathComponent(
      lifecycleTemporaryPrefix(url, "recovery") + "crashed.tmp")
    let upgradeTemporary = directory.appendingPathComponent(
      lifecycleTemporaryPrefix(url, "upgrade") + "crashed.tmp")
    try original.write(to: recoveryTemporary)
    try migrated.write(to: upgradeTemporary)
    #expect(chmod(recoveryTemporary.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
    #expect(chmod(upgradeTemporary.path, mode_t(S_IRUSR | S_IWUSR)) == 0)

    #expect(throws: LedgerStoreLifecycle.Error.pathChanged) {
      try LedgerStoreLifecycle.open(at: url)
    }
    #expect(try Data(contentsOf: recoveryTemporary) == original)
    #expect(try Data(contentsOf: upgradeTemporary) == migrated)
  }
}

@Test func lifecycleUpgradeRetainsNoFinancialBytesInItsDisplacedSibling() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)

    let result = try LedgerStoreLifecycle.open(at: url)
    #expect(result.disposition == .upgraded)
    let displaced = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix(lifecycleTemporaryPrefix(url, "upgrade")) }
    for artifact in displaced {
      #expect(try Data(contentsOf: artifact).isEmpty)
    }
  }
}

@Test func lifecycleRestartReconcilesAPublishedUpgradeBeforeOrdinaryOpen() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)

    #expect(
      throws: LedgerStoreLifecycle.Error.publicationCompleted(
        phase: .currentPublished, recoveryImageExists: true
      )
    ) {
      try LedgerStoreLifecycle.open(at: url) { phase in
        if phase == .afterPublication { throw LifecycleTestError.injected }
      }
    }

    let stranded = try #require(
      FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .first { $0.lastPathComponent.hasPrefix(lifecycleTemporaryPrefix(url, "upgrade")) })
    #expect(try Data(contentsOf: stranded) == original)

    let restarted = try LedgerStoreLifecycle.open(at: url)
    #expect(restarted.disposition == .opened)
    #expect(restarted.recoveryImageURL == LedgerStoreLifecycle.recoveryImageURL(for: url))
    #expect(try Data(contentsOf: stranded).isEmpty)
    #expect(try Data(contentsOf: LedgerStoreLifecycle.recoveryImageURL(for: url)) == original)
  }
}

@Test func lifecycleRestartRemovesTheAuthenticatedPreSwapReplacement() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)

    #expect(
      throws: LedgerStoreLifecycle.Error.publicationCompleted(
        phase: .recoveryPublished, recoveryImageExists: true
      )
    ) {
      try LedgerStoreLifecycle.open(at: url) { phase in
        if phase == .afterUpgradeStatePublished { throw LifecycleTestError.injected }
      }
    }
    let stranded = try #require(
      FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .first { $0.lastPathComponent.hasPrefix(lifecycleTemporaryPrefix(url, "upgrade")) })
    #expect(try Data(contentsOf: stranded).isEmpty == false)

    let retried = try LedgerStoreLifecycle.open(at: url)
    #expect(retried.disposition == .upgraded)
    #expect(try Data(contentsOf: LedgerStoreLifecycle.recoveryImageURL(for: url)) == original)
    let upgrades = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix(lifecycleTemporaryPrefix(url, "upgrade")) }
    for upgrade in upgrades {
      #expect(try Data(contentsOf: upgrade).isEmpty)
    }
  }
}

@Test func lifecyclePreservesPreSwapReplacementWhenItsActiveStateIsReplaced() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)
    let recovery = LedgerStoreLifecycle.recoveryImageURL(for: url)
    let stateURL = URL(fileURLWithPath: url.path + ".upgrade-state")

    #expect(
      throws: LedgerStoreLifecycle.Error.publicationCompleted(
        phase: .recoveryPublished, recoveryImageExists: true
      )
    ) {
      try LedgerStoreLifecycle.open(at: url) { phase in
        if phase == .afterUpgradeStatePublished { throw LifecycleTestError.injected }
      }
    }
    let replacement = try #require(
      FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .first { $0.lastPathComponent.hasPrefix(lifecycleTemporaryPrefix(url, "upgrade")) })
    let replacementBytes = try Data(contentsOf: replacement)
    let stateBytes = try Data(contentsOf: stateURL)
    let parkedState = directory.appendingPathComponent("parked-upgrade-state")

    #expect(throws: LedgerStoreLifecycle.Error.pathChanged) {
      try LedgerStoreLifecycle.open(at: url) { phase in
        guard phase == .beforeUnpublishedReplacementTruncate else { return }
        #expect(Darwin.rename(stateURL.path, parkedState.path) == 0)
        try Data().write(to: stateURL)
        #expect(chmod(stateURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
      }
    }

    #expect(try Data(contentsOf: url) == original)
    #expect(try Data(contentsOf: recovery) == original)
    #expect(try Data(contentsOf: replacement) == replacementBytes)
    #expect(try Data(contentsOf: parkedState) == stateBytes)
  }
}

@Test func lifecycleRejectsAForgeablePreSwapStateBeforeTruncatingAnUnrelatedCurrent() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)
    let recovery = LedgerStoreLifecycle.recoveryImageURL(for: url)
    let stateURL = URL(fileURLWithPath: url.path + ".upgrade-state")

    #expect(
      throws: LedgerStoreLifecycle.Error.publicationCompleted(
        phase: .recoveryPublished, recoveryImageExists: true
      )
    ) {
      try LedgerStoreLifecycle.open(at: url) { phase in
        if phase == .afterUpgradeStatePublished { throw LifecycleTestError.injected }
      }
    }
    let replacement = try #require(
      FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .first { $0.lastPathComponent.hasPrefix(lifecycleTemporaryPrefix(url, "upgrade")) })
    let unrelatedURL = directory.appendingPathComponent("unrelated-current.sqlite")
    _ = try LedgerStoreLifecycle.create(at: unrelatedURL)
    let unrelated = try Data(contentsOf: unrelatedURL)
    try overwriteInPlace(unrelated, at: replacement)
    let replacementBytes = try Data(contentsOf: replacement)
    try rewriteUpgradeState(stateURL, currentDigest: sha256Hex(replacementBytes))
    let stateBytes = try Data(contentsOf: stateURL)

    #expect(throws: LedgerStoreLifecycle.Error.pathChanged) {
      try LedgerStoreLifecycle.open(at: url)
    }
    #expect(try Data(contentsOf: url) == original)
    #expect(try Data(contentsOf: recovery) == original)
    #expect(try Data(contentsOf: replacement) == unrelated)
    #expect(try Data(contentsOf: stateURL) == stateBytes)
  }
}

@Test func lifecycleRejectsAForgeablePublishedStateBeforeTruncatingDisplacedData() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)
    let recovery = LedgerStoreLifecycle.recoveryImageURL(for: url)
    let stateURL = URL(fileURLWithPath: url.path + ".upgrade-state")
    #expect(
      throws: LedgerStoreLifecycle.Error.publicationCompleted(
        phase: .currentPublished, recoveryImageExists: true
      )
    ) {
      try LedgerStoreLifecycle.open(at: url) { phase in
        if phase == .afterPublication { throw LifecycleTestError.injected }
      }
    }
    let unrelatedURL = directory.appendingPathComponent("unrelated-published.sqlite")
    _ = try LedgerStoreLifecycle.create(at: unrelatedURL)
    let unrelated = try Data(contentsOf: unrelatedURL)
    try overwriteInPlace(unrelated, at: url)
    try rewriteUpgradeState(stateURL, currentDigest: sha256Hex(unrelated))
    let stateBytes = try Data(contentsOf: stateURL)
    let displaced = try #require(
      FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .first { $0.lastPathComponent.hasPrefix(lifecycleTemporaryPrefix(url, "upgrade")) })

    #expect(throws: LedgerStoreLifecycle.Error.pathChanged) {
      try LedgerStoreLifecycle.open(at: url)
    }
    #expect(try Data(contentsOf: url) == unrelated)
    #expect(try Data(contentsOf: displaced) == original)
    #expect(try Data(contentsOf: recovery) == original)
    #expect(try Data(contentsOf: stateURL) == stateBytes)
  }
}

@Test func lifecycleRejectsNonCanonicalUpgradeStateBytesWithoutCleanup() throws {
  for mutation in ["extra", "duplicate"] {
    try withLifecycleDirectory { directory in
      let url = directory.appendingPathComponent("ledger.sqlite")
      _ = try writeV10Ledger(to: url)
      let original = try Data(contentsOf: url)
      let stateURL = URL(fileURLWithPath: url.path + ".upgrade-state")
      #expect(
        throws: LedgerStoreLifecycle.Error.publicationCompleted(
          phase: .recoveryPublished, recoveryImageExists: true
        )
      ) {
        try LedgerStoreLifecycle.open(at: url) { phase in
          if phase == .afterUpgradeStatePublished { throw LifecycleTestError.injected }
        }
      }
      let state = try Data(contentsOf: stateURL)
      let json = String(decoding: state, as: UTF8.self)
      let malformed: Data
      if mutation == "extra" {
        var object = try #require(JSONSerialization.jsonObject(with: state) as? [String: Any])
        object["sentinel"] = "unrelated state bytes"
        malformed = try JSONSerialization.data(withJSONObject: object)
      } else {
        guard let brace = json.lastIndex(of: "}") else { throw LifecycleTestError.sqlite }
        let object = try #require(JSONSerialization.jsonObject(with: state) as? [String: Any])
        let leaf = try #require(object["replacementLeaf"] as? String)
        malformed = Data((String(json[..<brace]) + ",\"replacementLeaf\":\"" + leaf + "\"}").utf8)
      }
      try malformed.write(to: stateURL)
      #expect(chmod(stateURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
      let preserved = try Data(contentsOf: stateURL)

      #expect(throws: LedgerStoreLifecycle.Error.pathChanged) {
        try LedgerStoreLifecycle.open(at: url)
      }
      #expect(try Data(contentsOf: url) == original)
      #expect(try Data(contentsOf: stateURL) == preserved)
    }
  }
}

@Test func lifecycleRestartReconcilesWhenOpeningThePublishedStoreFails() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)

    #expect(
      throws: LedgerStoreLifecycle.Error.publicationCompleted(
        phase: .currentPublished, recoveryImageExists: true
      )
    ) {
      try LedgerStoreLifecycle.open(at: url) { phase in
        guard phase == .afterPublication else { return }
        guard chmod(url.path, 0) == 0 else { throw LifecycleTestError.injected }
      }
    }
    #expect(chmod(url.path, mode_t(S_IRUSR | S_IWUSR)) == 0)

    let restarted = try LedgerStoreLifecycle.open(at: url)
    #expect(restarted.disposition == .opened)
    #expect(restarted.recoveryImageURL == LedgerStoreLifecycle.recoveryImageURL(for: url))
    #expect(try Data(contentsOf: LedgerStoreLifecycle.recoveryImageURL(for: url)) == original)
  }
}

@Test func lifecycleRestartFinishesCleanupStoppedBeforeDisplacedTruncate() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)

    #expect(
      throws: LedgerStoreLifecycle.Error.publicationCompleted(
        phase: .currentPublished, recoveryImageExists: true
      )
    ) {
      try LedgerStoreLifecycle.open(at: url) { phase in
        if phase == .beforeDisplacedTruncate { throw LifecycleTestError.injected }
      }
    }

    let restarted = try LedgerStoreLifecycle.open(at: url)
    #expect(restarted.disposition == .opened)
    #expect(restarted.recoveryImageURL == LedgerStoreLifecycle.recoveryImageURL(for: url))
    #expect(try Data(contentsOf: LedgerStoreLifecycle.recoveryImageURL(for: url)) == original)
  }
}

@Test func lifecycleCancellationStopsBeforePublishingRecovery() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("ledger.sqlite")
  _ = try writeV10Ledger(to: url)
  let original = try Data(contentsOf: url)
  let reachedRecoveryPublication = LifecycleTestGate()
  let releaseRecoveryPublication = DispatchSemaphore(value: 0)
  let task = Task { () -> Swift.Error? in
    do {
      _ = try LedgerStoreLifecycle.open(at: url) { phase in
        guard phase == .afterRecoveryValidated else { return }
        Task { await reachedRecoveryPublication.arrive() }
        releaseRecoveryPublication.wait()
      }
      return nil
    } catch {
      return error
    }
  }
  await reachedRecoveryPublication.wait()
  task.cancel()
  releaseRecoveryPublication.signal()
  let error = await task.value

  #expect(error as? LedgerStoreLifecycle.Error == .interrupted)
  #expect(try Data(contentsOf: url) == original)
  #expect(
    !FileManager.default.fileExists(atPath: LedgerStoreLifecycle.recoveryImageURL(for: url).path))
}

@Test func lifecycleRejectsAConcurrentSameProcessOpenBeforeItMutatesAnything() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    let otherURL = directory.appendingPathComponent("other-ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      defer { finished.signal() }
      _ = try? LedgerStoreLifecycle.open(at: url) { phase in
        guard phase == .afterRecoveryValidated else { return }
        entered.signal()
        release.wait()
      }
    }
    entered.wait()
    let publisherTemporary = try #require(
      FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .first { $0.lastPathComponent.hasPrefix(lifecycleTemporaryPrefix(url, "recovery")) })
    #expect(try Data(contentsOf: publisherTemporary) == original)
    #expect(try LedgerStoreLifecycle.create(at: otherURL).disposition == .created)
    #expect(throws: LedgerStoreLifecycle.Error.busy) { try LedgerStoreLifecycle.open(at: url) }
    #expect(try Data(contentsOf: url) == original)
    #expect(try Data(contentsOf: publisherTemporary) == original)
    #expect(FileManager.default.fileExists(atPath: otherURL.path))
    release.signal()
    finished.wait()
  }
}

@Test func lifecycleRejectsAnotherProcessHoldingTheLedgerLock() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)
    let lockURL = lifecycleLockURL(url)
    try Data().write(to: lockURL)
    #expect(chmod(lockURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
    try withChildHoldingLifecycleLock(at: lockURL) {
      #expect(throws: LedgerStoreLifecycle.Error.busy) {
        try LedgerStoreLifecycle.open(at: url)
      }
      let unchanged = try Data(contentsOf: url)
      #expect(unchanged == original)
      #expect(
        !FileManager.default.fileExists(
          atPath: LedgerStoreLifecycle.recoveryImageURL(for: url).path))
    }
    #expect(try LedgerStoreLifecycle.open(at: url).disposition == .upgraded)
  }
}

@Test func lifecycleFailsClosedWhenItsLockedPathIsReplaced() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)
    let lockURL = lifecycleLockURL(url)
    let parkedLock = directory.appendingPathComponent("parked-lock")
    var childLockedReplacement = false
    #expect(throws: LedgerStoreLifecycle.Error.pathChanged) {
      try LedgerStoreLifecycle.open(at: url) { phase in
        guard phase == .afterLeaseAcquired else { return }
        #expect(Darwin.rename(lockURL.path, parkedLock.path) == 0)
        try Data().write(to: lockURL)
        #expect(chmod(lockURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
        childLockedReplacement = try childCanLock(lockURL)
      }
    }
    #expect(childLockedReplacement)
    #expect(try Data(contentsOf: url) == original)
    #expect(
      !FileManager.default.fileExists(atPath: LedgerStoreLifecycle.recoveryImageURL(for: url).path))
  }
}

@Test func lifecycleCurrentOpenFailsClosedWhenItsLockPathIsReplaced() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try LedgerStoreLifecycle.create(at: url)
    let original = try Data(contentsOf: url)
    let lockURL = lifecycleLockURL(url)
    let parkedLock = directory.appendingPathComponent("parked-current-lock")
    var childLockedReplacement = false

    #expect(throws: LedgerStoreLifecycle.Error.pathChanged) {
      try LedgerStoreLifecycle.open(at: url) { phase in
        guard phase == .afterLeaseAcquired else { return }
        #expect(Darwin.rename(lockURL.path, parkedLock.path) == 0)
        try Data().write(to: lockURL)
        #expect(chmod(lockURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
        childLockedReplacement = try childCanLock(lockURL)
      }
    }
    #expect(childLockedReplacement)
    #expect(try Data(contentsOf: url) == original)
  }
}

@Test func lifecycleFailsClosedWhenPublishedStateDisappearsAfterSwap() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)
    let state = URL(fileURLWithPath: url.path + ".upgrade-state")
    let parked = directory.appendingPathComponent("parked-state")
    #expect(
      throws: LedgerStoreLifecycle.Error.publicationCompleted(
        phase: .currentPublished, recoveryImageExists: true
      )
    ) {
      try LedgerStoreLifecycle.open(at: url) { phase in
        guard phase == .afterSwapBeforeValidation else { return }
        #expect(Darwin.rename(state.path, parked.path) == 0)
      }
    }
    let displaced = try #require(
      FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .first { $0.lastPathComponent.hasPrefix(lifecycleTemporaryPrefix(url, "upgrade")) })
    #expect(try Data(contentsOf: displaced) == original)
    #expect(throws: LedgerStoreLifecycle.Error.pathChanged) {
      try LedgerStoreLifecycle.open(at: url)
    }
    #expect(try Data(contentsOf: displaced) == original)
  }
}

@Test func lifecycleRejectsByteIdenticalWrongInodeReplacementBeforeSwap() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)
    #expect(
      throws: LedgerStoreLifecycle.Error.publicationCompleted(
        phase: .recoveryPublished, recoveryImageExists: true
      )
    ) {
      try LedgerStoreLifecycle.open(at: url) { phase in
        if phase == .afterUpgradeStatePublished { throw LifecycleTestError.injected }
      }
    }
    let replacement = try #require(
      FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .first { $0.lastPathComponent.hasPrefix(lifecycleTemporaryPrefix(url, "upgrade")) })
    let copy = directory.appendingPathComponent("same-bytes-current.sqlite")
    try Data(contentsOf: replacement).write(to: copy)
    #expect(chmod(copy.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
    #expect(Darwin.rename(copy.path, replacement.path) == 0)
    #expect(throws: LedgerStoreLifecycle.Error.pathChanged) {
      try LedgerStoreLifecycle.open(at: url)
    }
    #expect(try Data(contentsOf: url) == original)
    #expect(try Data(contentsOf: replacement) != Data())
  }
}

@Test func lifecycleFinishesCleanupWhenTheRecordedPreSwapReplacementIsAlreadyZero() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    #expect(
      throws: LedgerStoreLifecycle.Error.publicationCompleted(
        phase: .recoveryPublished, recoveryImageExists: true
      )
    ) {
      try LedgerStoreLifecycle.open(at: url) { phase in
        if phase == .afterUpgradeStatePublished { throw LifecycleTestError.injected }
      }
    }
    let replacement = try #require(
      FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
      ).first { $0.lastPathComponent.hasPrefix(lifecycleTemporaryPrefix(url, "upgrade")) })
    let descriptor = Darwin.open(replacement.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
    #expect(descriptor >= 0)
    #expect(ftruncate(descriptor, 0) == 0)
    #expect(fsync(descriptor) == 0)
    Darwin.close(descriptor)
    #expect(try LedgerStoreLifecycle.open(at: url).disposition == .upgraded)
  }
}

@Test func lifecycleRejectsPartialUpgradeStateWithoutMutatingV10() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)
    let state = URL(fileURLWithPath: url.path + ".upgrade-state")
    try Data("{\"replacementLeaf\":\"partial\"".utf8).write(to: state)
    #expect(chmod(state.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
    #expect(throws: LedgerStoreLifecycle.Error.pathChanged) {
      try LedgerStoreLifecycle.open(at: url)
    }
    #expect(try Data(contentsOf: url) == original)
    #expect(
      !FileManager.default.fileExists(atPath: LedgerStoreLifecycle.recoveryImageURL(for: url).path))
  }
}

@Test func lifecycleDoesNotScavengeAnUnauthenticatedNamespacedTemporary() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)
    let temporary = directory.appendingPathComponent(
      lifecycleTemporaryPrefix(url, "recovery") + "sentinel.tmp")
    let sentinel = Data("unrelated-sentinel".utf8)
    try sentinel.write(to: temporary)
    #expect(chmod(temporary.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
    #expect(throws: LedgerStoreLifecycle.Error.pathChanged) {
      try LedgerStoreLifecycle.open(at: url)
    }
    #expect(try Data(contentsOf: url) == original)
    #expect(try Data(contentsOf: temporary) == sentinel)
  }
}

@Test func lifecycleRejectsUnsafeNamespacedTemporaryInsteadOfTreatingItAsAbsent() throws {
  enum Artifact { case mode, symlink }
  for artifact in [Artifact.mode, .symlink] {
    try withLifecycleDirectory { directory in
      let url = directory.appendingPathComponent("ledger.sqlite")
      _ = try LedgerStoreLifecycle.create(at: url)
      let original = try Data(contentsOf: url)
      let temporary = directory.appendingPathComponent(
        lifecycleTemporaryPrefix(url, "recovery") + "unsafe.tmp")
      let target = directory.appendingPathComponent("unsafe-target")
      let sentinel = Data("unsafe namespaced temporary".utf8)
      switch artifact {
      case .mode:
        try sentinel.write(to: temporary)
        #expect(chmod(temporary.path, mode_t(S_IRUSR | S_IWUSR | S_IRGRP)) == 0)
      case .symlink:
        try sentinel.write(to: target)
        #expect(chmod(target.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
        #expect(Darwin.symlink(target.path, temporary.path) == 0)
      }

      #expect(throws: LedgerStoreLifecycle.Error.pathChanged) {
        try LedgerStoreLifecycle.open(at: url)
      }
      #expect(try Data(contentsOf: url) == original)
      switch artifact {
      case .mode:
        #expect(try Data(contentsOf: temporary) == sentinel)
        #expect(try fileMode(temporary) == mode_t(S_IRUSR | S_IWUSR | S_IRGRP))
      case .symlink:
        #expect(try Data(contentsOf: target) == sentinel)
        var value = stat()
        #expect(lstat(temporary.path, &value) == 0)
        #expect((value.st_mode & S_IFMT) == S_IFLNK)
      }
    }
  }
}

@Test func lifecycleRejectsUnsafeInactiveUpgradeStateInsteadOfTreatingItAsAbsent() throws {
  enum Artifact { case mode, symlink }
  for artifact in [Artifact.mode, .symlink] {
    try withLifecycleDirectory { directory in
      let url = directory.appendingPathComponent("ledger.sqlite")
      _ = try LedgerStoreLifecycle.create(at: url)
      let original = try Data(contentsOf: url)
      let state = URL(fileURLWithPath: url.path + ".upgrade-state")
      let target = directory.appendingPathComponent("unsafe-state-target")
      switch artifact {
      case .mode:
        try Data().write(to: state)
        #expect(chmod(state.path, mode_t(S_IRUSR | S_IWUSR | S_IRGRP)) == 0)
      case .symlink:
        try Data().write(to: target)
        #expect(chmod(target.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
        #expect(Darwin.symlink(target.path, state.path) == 0)
      }

      #expect(throws: LedgerStoreLifecycle.Error.pathChanged) {
        try LedgerStoreLifecycle.open(at: url)
      }
      #expect(try Data(contentsOf: url) == original)
      switch artifact {
      case .mode:
        #expect(try Data(contentsOf: state).isEmpty)
        #expect(try fileMode(state) == mode_t(S_IRUSR | S_IWUSR | S_IRGRP))
      case .symlink:
        #expect(try Data(contentsOf: target).isEmpty)
        var value = stat()
        #expect(lstat(state.path, &value) == 0)
        #expect((value.st_mode & S_IFMT) == S_IFLNK)
      }
    }
  }
}

@Test func lifecycleRejectsStaleUpgradeStateDisplacedIdentityBeforeCleanup() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)
    let recovery = LedgerStoreLifecycle.recoveryImageURL(for: url)
    let state = URL(fileURLWithPath: url.path + ".upgrade-state")

    #expect(
      throws: LedgerStoreLifecycle.Error.publicationCompleted(
        phase: .recoveryPublished, recoveryImageExists: true
      )
    ) {
      try LedgerStoreLifecycle.open(at: url) { phase in
        if phase == .afterUpgradeStatePublished { throw LifecycleTestError.injected }
      }
    }
    let replacement = try #require(
      FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .first { $0.lastPathComponent.hasPrefix(lifecycleTemporaryPrefix(url, "upgrade")) })
    let replacementBytes = try Data(contentsOf: replacement)
    let stateBefore = try Data(contentsOf: state)
    try rewriteUpgradeStateDisplacedInode(state, to: UInt64.max)
    let forgedState = try Data(contentsOf: state)
    #expect(forgedState != stateBefore)

    #expect(throws: LedgerStoreLifecycle.Error.pathChanged) {
      try LedgerStoreLifecycle.open(at: url)
    }
    #expect(try Data(contentsOf: url) == original)
    #expect(try Data(contentsOf: recovery) == original)
    #expect(try Data(contentsOf: replacement) == replacementBytes)
    #expect(try Data(contentsOf: state) == forgedState)
  }
}

@Test func lifecycleRestartPreservesNonemptyUnboundMigrationStateTemporary() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)
    let nonempty = directory.appendingPathComponent(
      lifecycleTemporaryPrefix(url, "migration-state") + "sentinel.tmp")
    let empty = directory.appendingPathComponent(
      lifecycleTemporaryPrefix(url, "migration-state") + "empty.tmp")
    let sentinel = Data("unbound migration-state sentinel".utf8)
    try sentinel.write(to: nonempty)
    try Data().write(to: empty)
    #expect(chmod(nonempty.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
    #expect(chmod(empty.path, mode_t(S_IRUSR | S_IWUSR)) == 0)

    #expect(throws: LedgerStoreLifecycle.Error.pathChanged) {
      try LedgerStoreLifecycle.open(at: url)
    }
    #expect(try Data(contentsOf: url) == original)
    #expect(try Data(contentsOf: nonempty) == sentinel)
    #expect(try Data(contentsOf: empty).isEmpty)

    try Data().write(to: nonempty)
    #expect(try LedgerStoreLifecycle.open(at: url).disposition == .upgraded)
    #expect(try Data(contentsOf: empty).isEmpty)
  }
}

@Test func lifecycleActiveStateRejectsAnAdditionalNonemptyMigrationStateTemporary() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)
    let recovery = LedgerStoreLifecycle.recoveryImageURL(for: url)
    let state = URL(fileURLWithPath: url.path + ".upgrade-state")

    #expect(
      throws: LedgerStoreLifecycle.Error.publicationCompleted(
        phase: .recoveryPublished, recoveryImageExists: true
      )
    ) {
      try LedgerStoreLifecycle.open(at: url) { phase in
        if phase == .afterUpgradeStatePublished { throw LifecycleTestError.injected }
      }
    }
    let replacement = try #require(
      FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .first { $0.lastPathComponent.hasPrefix(lifecycleTemporaryPrefix(url, "upgrade")) })
    let replacementBytes = try Data(contentsOf: replacement)
    let stateBytes = try Data(contentsOf: state)
    let orphan = directory.appendingPathComponent(
      lifecycleTemporaryPrefix(url, "migration-state") + "extra.tmp")
    let sentinel = Data("active migration-state orphan".utf8)
    try sentinel.write(to: orphan)
    #expect(chmod(orphan.path, mode_t(S_IRUSR | S_IWUSR)) == 0)

    #expect(throws: LedgerStoreLifecycle.Error.pathChanged) {
      try LedgerStoreLifecycle.open(at: url)
    }
    #expect(try Data(contentsOf: url) == original)
    #expect(try Data(contentsOf: recovery) == original)
    #expect(try Data(contentsOf: replacement) == replacementBytes)
    #expect(try Data(contentsOf: state) == stateBytes)
    #expect(try Data(contentsOf: orphan) == sentinel)
  }
}

@Test func lifecycleCurrentOpenRejectsNonemptyRecoveryAndMigrationStateTemporaries() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try LedgerStoreLifecycle.create(at: url)
    let recovery = directory.appendingPathComponent(
      lifecycleTemporaryPrefix(url, "recovery") + "current.tmp")
    let migrationState = directory.appendingPathComponent(
      lifecycleTemporaryPrefix(url, "migration-state") + "current.tmp")
    let recoveryBytes = Data("current recovery orphan".utf8)
    let migrationBytes = Data("current migration-state orphan".utf8)
    try recoveryBytes.write(to: recovery)
    try migrationBytes.write(to: migrationState)
    #expect(chmod(recovery.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
    #expect(chmod(migrationState.path, mode_t(S_IRUSR | S_IWUSR)) == 0)

    #expect(throws: LedgerStoreLifecycle.Error.pathChanged) {
      try LedgerStoreLifecycle.open(at: url)
    }
    #expect(try Data(contentsOf: recovery) == recoveryBytes)
    #expect(try Data(contentsOf: migrationState) == migrationBytes)
  }
}

@Test func lifecycleCancellationAfterDurableRecoveryReportsPublishedTruth() async throws {
  for phase in [
    LedgerStoreLifecycle.TestPhase.afterRecoveryPublished,
    .afterUpgradeStatePublished,
  ] {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)
    let reached = LifecycleTestGate()
    let release = DispatchSemaphore(value: 0)
    let task = Task { () -> Swift.Error? in
      do {
        _ = try LedgerStoreLifecycle.open(at: url) { reachedPhase in
          guard reachedPhase == phase else { return }
          Task { await reached.arrive() }
          release.wait()
        }
        return nil
      } catch {
        return error
      }
    }
    await reached.wait()
    task.cancel()
    release.signal()

    #expect(
      await task.value as? LedgerStoreLifecycle.Error
        == .publicationCompleted(phase: .recoveryPublished, recoveryImageExists: true))
    #expect(try Data(contentsOf: url) == original)
    #expect(try Data(contentsOf: LedgerStoreLifecycle.recoveryImageURL(for: url)) == original)
    #expect(try LedgerStoreLifecycle.open(at: url).disposition == .upgraded)
  }
}

@Test func lifecycleCancellationBeforeReconciliationMutationLeavesStorageUntouched() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("ledger.sqlite")
  _ = try writeV10Ledger(to: url)
  let original = try Data(contentsOf: url)
  #expect(
    throws: LedgerStoreLifecycle.Error.publicationCompleted(
      phase: .currentPublished, recoveryImageExists: true
    )
  ) {
    try LedgerStoreLifecycle.open(at: url) { phase in
      if phase == .afterPublication { throw LifecycleTestError.injected }
    }
  }
  let displaced = try #require(
    FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .first { $0.lastPathComponent.hasPrefix(lifecycleTemporaryPrefix(url, "upgrade")) })
  #expect(try Data(contentsOf: displaced) == original)

  let reached = LifecycleTestGate()
  let release = DispatchSemaphore(value: 0)
  let task = Task { () -> Swift.Error? in
    do {
      _ = try LedgerStoreLifecycle.open(at: url) { phase in
        guard phase == .beforeReconciliationMutation else { return }
        Task { await reached.arrive() }
        release.wait()
      }
      return nil
    } catch {
      return error
    }
  }
  await reached.wait()
  task.cancel()
  release.signal()

  #expect(await task.value as? LedgerStoreLifecycle.Error == .interrupted)
  #expect(try Data(contentsOf: displaced) == original)
  #expect(try LedgerStoreLifecycle.open(at: url).disposition == .opened)
  #expect(try Data(contentsOf: displaced).isEmpty)
}

@Test func lifecycleDoesNotTruncateARenamedAndRepurposedDisplacedSource() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)
    var sourceIdentity = stat()
    #expect(lstat(url.path, &sourceIdentity) == 0)
    let parked = directory.appendingPathComponent("parked-v10.sqlite")
    let sentinelBytes = Data("unrelated sentinel".utf8)
    var hiddenLeaf: URL?

    #expect(
      throws: LedgerStoreLifecycle.Error.publicationCompleted(
        phase: .currentPublished, recoveryImageExists: true
      )
    ) {
      try LedgerStoreLifecycle.open(at: url) { phase in
        guard phase == .afterPublishedStoreOpened else { return }
        let hidden = try #require(
          FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(lifecycleTemporaryPrefix(url, "upgrade")) })
        #expect(Darwin.rename(hidden.path, parked.path) == 0)
        try overwriteInPlace(sentinelBytes, at: parked)
        #expect(chmod(parked.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
        hiddenLeaf = hidden
      }
    }

    let sentinel = try #require(hiddenLeaf)
    #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    #expect(try Data(contentsOf: url) != original)
    var parkedIdentity = stat()
    #expect(lstat(parked.path, &parkedIdentity) == 0)
    #expect(sourceIdentity.st_dev == parkedIdentity.st_dev)
    #expect(sourceIdentity.st_ino == parkedIdentity.st_ino)
    #expect(try Data(contentsOf: parked) == sentinelBytes)
  }
}

@Test func lifecycleDoesNotTruncateDisplacedSourceChangedAfterItsFinalDigest() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)
    let sentinel = Data(repeating: 0xa5, count: original.count)
    var displaced: URL?

    #expect(
      throws: LedgerStoreLifecycle.Error.publicationCompleted(
        phase: .currentPublished, recoveryImageExists: true
      )
    ) {
      try LedgerStoreLifecycle.open(at: url) { phase in
        guard phase == .afterDisplacedSourceDigestBeforeTruncate else { return }
        let target = try #require(
          FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(lifecycleTemporaryPrefix(url, "upgrade")) })
        try overwriteSameLengthRestoringModificationTime(sentinel, at: target)
        displaced = target
      }
    }

    #expect(try Data(contentsOf: #require(displaced)) == sentinel)
    #expect(try Data(contentsOf: LedgerStoreLifecycle.recoveryImageURL(for: url)) == original)
  }
}

@Test func lifecycleRestartDoesNotTruncateARenamedAndRepurposedDisplacedSource() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)
    let recovery = LedgerStoreLifecycle.recoveryImageURL(for: url)
    let parked = directory.appendingPathComponent("parked-restart-v10.sqlite")
    let sentinel = Data("restart displaced sentinel".utf8)
    var hiddenLeaf: URL?

    #expect(
      throws: LedgerStoreLifecycle.Error.publicationCompleted(
        phase: .currentPublished, recoveryImageExists: true
      )
    ) {
      try LedgerStoreLifecycle.open(at: url) { phase in
        if phase == .afterPublication { throw LifecycleTestError.injected }
      }
    }
    #expect(
      throws: LedgerStoreLifecycle.Error.publicationCompleted(
        phase: .currentPublished, recoveryImageExists: true
      )
    ) {
      try LedgerStoreLifecycle.open(at: url) { phase in
        guard phase == .beforeReconciliationMutation else { return }
        let hidden = try #require(
          FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(lifecycleTemporaryPrefix(url, "upgrade")) })
        #expect(Darwin.rename(hidden.path, parked.path) == 0)
        try overwriteInPlace(sentinel, at: parked)
        hiddenLeaf = hidden
      }
    }
    #expect(try Data(contentsOf: url) != original)
    #expect(try Data(contentsOf: parked) == sentinel)
    #expect(try Data(contentsOf: recovery) == original)
    let hidden = try #require(hiddenLeaf)
    #expect(!FileManager.default.fileExists(atPath: hidden.path))
  }
}

@Test func lifecycleUpgradeRejectsRenamedReplacementBeforeSwap() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)
    let recovery = LedgerStoreLifecycle.recoveryImageURL(for: url)
    let parked = directory.appendingPathComponent("parked-v11.sqlite")
    let sentinel = Data("replacement pre-swap sentinel".utf8)
    var replacedTemporary: URL?

    #expect(
      throws: LedgerStoreLifecycle.Error.publicationCompleted(
        phase: .recoveryPublished, recoveryImageExists: true
      )
    ) {
      try LedgerStoreLifecycle.open(at: url) { phase in
        guard phase == .afterUpgradeStatePublished else { return }
        let temporary = try #require(
          FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(lifecycleTemporaryPrefix(url, "upgrade")) })
        #expect(Darwin.rename(temporary.path, parked.path) == 0)
        try sentinel.write(to: temporary)
        #expect(chmod(temporary.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
        replacedTemporary = temporary
      }
    }

    #expect(try Data(contentsOf: url) == original)
    #expect(try Data(contentsOf: recovery) == original)
    #expect(try Data(contentsOf: parked).isEmpty == false)
    #expect(try Data(contentsOf: #require(replacedTemporary)) == sentinel)
  }
}

@Test func lifecycleUpgradeRejectsCanonicalPathReplacementBeforeSwap() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)
    let recovery = LedgerStoreLifecycle.recoveryImageURL(for: url)
    let parked = directory.appendingPathComponent("parked-canonical-v10.sqlite")
    let sentinel = Data("canonical pre-swap sentinel".utf8)

    #expect(
      throws: LedgerStoreLifecycle.Error.publicationCompleted(
        phase: .recoveryPublished, recoveryImageExists: true
      )
    ) {
      try LedgerStoreLifecycle.open(at: url) { phase in
        guard phase == .afterUpgradeStatePublished else { return }
        #expect(Darwin.rename(url.path, parked.path) == 0)
        try sentinel.write(to: url)
        #expect(chmod(url.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
      }
    }

    #expect(try Data(contentsOf: url) == sentinel)
    #expect(try Data(contentsOf: parked) == original)
    #expect(try Data(contentsOf: recovery) == original)
  }
}

@Test func lifecycleUpgradeRejectsCompanionsAddedBeforeSwap() throws {
  for suffix in ["-journal", "-journal.ledger-atlas-binding", "-wal", "-shm"] {
    try withLifecycleDirectory { directory in
      let url = directory.appendingPathComponent("ledger.sqlite")
      _ = try writeV10Ledger(to: url)
      let original = try Data(contentsOf: url)
      let recovery = LedgerStoreLifecycle.recoveryImageURL(for: url)
      let companion = URL(fileURLWithPath: url.path + suffix)
      let bytes = Data("upgrade companion sentinel (suffix)".utf8)

      #expect(
        throws: LedgerStoreLifecycle.Error.publicationCompleted(
          phase: .recoveryPublished, recoveryImageExists: true
        )
      ) {
        try LedgerStoreLifecycle.open(at: url) { phase in
          guard phase == .afterUpgradeStatePublished else { return }
          try bytes.write(to: companion)
          #expect(chmod(companion.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
        }
      }

      #expect(try Data(contentsOf: url) == original)
      #expect(try Data(contentsOf: recovery) == original)
      #expect(try Data(contentsOf: companion) == bytes)
    }
  }
}

@Test func lifecycleUpgradeRejectsRepurposedInactiveStateBeforePublication() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let original = try Data(contentsOf: url)
    let stateURL = URL(fileURLWithPath: url.path + ".upgrade-state")
    let parked = directory.appendingPathComponent("parked-inactive-state")
    let sentinel = Data("inactive state sentinel".utf8)
    try Data().write(to: stateURL)
    #expect(chmod(stateURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0)

    #expect(
      throws: LedgerStoreLifecycle.Error.publicationCompleted(
        phase: .recoveryPublished, recoveryImageExists: true
      )
    ) {
      try LedgerStoreLifecycle.open(at: url) { phase in
        guard phase == .beforeUpgradeStatePublication else { return }
        #expect(Darwin.rename(stateURL.path, parked.path) == 0)
        try overwriteInPlace(sentinel, at: parked)
      }
    }
    #expect(try Data(contentsOf: url) == original)
    #expect(try Data(contentsOf: parked) == sentinel)
    #expect(!FileManager.default.fileExists(atPath: stateURL.path))
    #expect(try Data(contentsOf: LedgerStoreLifecycle.recoveryImageURL(for: url)) == original)
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

@Test func lifecycleRejectsSparseOversizedV10BeforeMigrationAllocation() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    _ = try writeV10Ledger(to: url)
    let originalBytes = try Data(contentsOf: url)
    let descriptor = Darwin.open(url.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
    #expect(descriptor >= 0)
    #expect(ftruncate(descriptor, off_t(512 * 1024 * 1024 + 4 * 1024)) == 0)
    #expect(fsync(descriptor) == 0)
    Darwin.close(descriptor)

    #expect(throws: LedgerStoreLifecycle.Error.unsupportedStore) {
      try LedgerStoreLifecycle.inspect(at: url)
    }
    #expect(throws: LedgerStoreLifecycle.Error.unsupportedStore) {
      try LedgerStoreLifecycle.open(at: url)
    }
    var value = stat()
    #expect(lstat(url.path, &value) == 0)
    #expect(value.st_size == off_t(512 * 1024 * 1024 + 4 * 1024))
    let prefix = originalBytes
    let readDescriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    #expect(readDescriptor >= 0)
    var readBuffer = [UInt8](repeating: 0, count: prefix.count)
    let count = readBuffer.withUnsafeMutableBytes {
      pread(readDescriptor, $0.baseAddress, $0.count, 0)
    }
    Darwin.close(readDescriptor)
    #expect(count == prefix.count)
    #expect(Data(readBuffer) == prefix)
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
    // Both mutations remain structurally and domain valid; only the persisted receipt digests
    // bind them to their authenticated canonical graph.
    "UPDATE event_source_binding SET declared_type='INTEGER' WHERE semantic='amount'",
    "UPDATE import_receipt SET profile_id='forged-profile'",
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
      #expect(
        !FileManager.default.fileExists(
          atPath: LedgerStoreLifecycle.recoveryImageURL(for: url).path))
      #expect(
        try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy {
          !$0.hasPrefix(lifecycleTemporaryPrefix(url, "upgrade"))
        })
    }
  }
}

@Test func lifecycleRejectsRehashedV10ProvenanceForgeriesWithoutMutation() throws {
  let currencyProvenance = syntheticV10ProvenanceIDs[1]
  let forgeries = [
    (
      "UPDATE provenance_reference SET source_column_name='forged' WHERE provenance_id='\(currencyProvenance)'",
      syntheticV10EventSetHash()
    ),
    (
      "UPDATE provenance_reference SET source_column_ordinal=-9223372036854775808 WHERE provenance_id='\(currencyProvenance)'",
      syntheticV10EventSetHash()
    ),
    (
      "UPDATE economic_event SET provenance_id='\(currencyProvenance)'",
      syntheticV10EventSetHash(amountProvenanceID: currencyProvenance)
    ),
  ]
  for (mutation, eventSetHash) in forgeries {
    try withLifecycleDirectory { directory in
      let url = directory.appendingPathComponent("ledger.sqlite")
      try writeV10ImportLedger(to: url, mutation: "")
      #expect(try LedgerStoreLifecycle.inspect(at: url) == .upgradeRequired)
      try mutateV10ImportLedger(
        at: url,
        sql: """
          \(mutation);
          UPDATE import_receipt SET event_set_hash='\(eventSetHash)',
            reconciliation_hash='\(syntheticV10ReconciliationHash(eventSetHash: eventSetHash))';
          """)
      let before = try Data(contentsOf: url)

      #expect(throws: LedgerStoreLifecycle.Error.invalidStore) {
        try LedgerStoreLifecycle.inspect(at: url)
      }
      #expect(throws: LedgerStoreLifecycle.Error.invalidStore) {
        try LedgerStoreLifecycle.open(at: url)
      }
      #expect(try Data(contentsOf: url) == before)
    }
  }
}

@Test func lifecycleRejectsRehashedV10PreservationForgeryWithoutMutation() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    try writeV10ImportLedger(to: url, mutation: "")
    try addSyntheticV10Preservation(to: url)
    #expect(try LedgerStoreLifecycle.inspect(at: url) == .upgradeRequired)

    let eventSetHash = syntheticV10EventSetHash()
    let forgedPreservationHash = syntheticV10PreservationHash(storageClass: .blob)
    try mutateV10ImportLedger(
      at: url,
      sql: """
        UPDATE receipt_preservation_payload SET storage_class='blob';
        UPDATE import_receipt SET event_set_hash='\(eventSetHash)',
          reconciliation_hash='\(syntheticV10ReconciliationHash(
            eventSetHash: eventSetHash, preservationHash: forgedPreservationHash))';
        """)
    let before = try Data(contentsOf: url)

    #expect(throws: LedgerStoreLifecycle.Error.invalidStore) {
      try LedgerStoreLifecycle.inspect(at: url)
    }
    #expect(throws: LedgerStoreLifecycle.Error.invalidStore) {
      try LedgerStoreLifecycle.open(at: url)
    }
    #expect(try Data(contentsOf: url) == before)
  }
}

@Test func lifecycleRejectsRehashedCurrentV11ProvenanceForgeryWithoutMutation() throws {
  try withLifecycleDirectory { directory in
    let url = directory.appendingPathComponent("ledger.sqlite")
    try writeV10ImportLedger(to: url, mutation: "")
    #expect(try LedgerStoreLifecycle.open(at: url).disposition == .upgraded)

    let eventSetHash = syntheticV10EventSetHash()
    try mutateV10ImportLedger(
      at: url,
      sql: """
        UPDATE provenance_reference SET source_column_name='forged'
          WHERE provenance_id='\(syntheticV10ProvenanceIDs[1])';
        UPDATE import_receipt SET event_set_hash='\(eventSetHash)',
          reconciliation_hash='\(syntheticV10ReconciliationHash(eventSetHash: eventSetHash))';
        """)
    let before = try Data(contentsOf: url)

    #expect(throws: LedgerStoreLifecycle.Error.invalidStore) {
      try LedgerStoreLifecycle.inspect(at: url)
    }
    #expect(throws: LedgerStoreLifecycle.Error.invalidStore) {
      try LedgerStoreLifecycle.open(at: url)
    }
    #expect(try Data(contentsOf: url) == before)
  }
}

private actor LifecycleTestGate {
  private var arrived = false
  private var waiter: CheckedContinuation<Void, Never>?

  func arrive() {
    arrived = true
    waiter?.resume()
    waiter = nil
  }

  func wait() async {
    guard !arrived else { return }
    await withCheckedContinuation { waiter = $0 }
  }
}

private func withLifecycleDirectory(_ body: (URL) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try body(directory)
}

private func lifecycleNamespace(_ url: URL) -> String {
  SHA256.hash(data: Data(url.lastPathComponent.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func lifecycleTemporaryPrefix(_ url: URL, _ kind: String) -> String {
  ".ledger-atlas-\(lifecycleNamespace(url))-\(kind)-"
}

private func lifecycleLockURL(_ url: URL) -> URL {
  url.deletingLastPathComponent().appendingPathComponent(
    ".ledger-atlas-\(lifecycleNamespace(url)).lifecycle-lock")
}

private func withChildHoldingLifecycleLock(at lockURL: URL, _ body: () throws -> Void) throws {
  let child = Process()
  let input = Pipe()
  let output = Pipe()
  child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
  child.arguments = [
    "-c",
    "import fcntl,os,sys; fd=os.open(sys.argv[1],os.O_RDONLY); fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB); sys.stdout.buffer.write(b'1'); sys.stdout.buffer.flush(); sys.stdin.buffer.read(1)",
    lockURL.path,
  ]
  child.standardInput = input
  child.standardOutput = output
  child.standardError = Pipe()
  try child.run()
  let signal = output.fileHandleForReading.readData(ofLength: 1)
  defer {
    if child.isRunning {
      try? input.fileHandleForWriting.write(contentsOf: Data([1]))
      input.fileHandleForWriting.closeFile()
      child.waitUntilExit()
    }
  }
  guard signal == Data([49]), child.isRunning else { throw LifecycleTestError.injected }
  try body()
}

private func childCanLock(_ lockURL: URL) throws -> Bool {
  let child = Process()
  child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
  child.arguments = [
    "-c",
    "import fcntl,os,sys; fd=os.open(sys.argv[1],os.O_RDONLY); fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)",
    lockURL.path,
  ]
  child.standardError = Pipe()
  try child.run()
  child.waitUntilExit()
  return child.terminationStatus == 0
}

private func mutateV10ImportLedger(at url: URL, sql: String) throws {
  var database: OpaquePointer?
  guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
    throw LifecycleTestError.sqlite
  }
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK,
    sqlite3_close(database) == SQLITE_OK
  else { throw LifecycleTestError.sqlite }
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

private let syntheticV10ArtifactID = String(repeating: "a", count: 64)
// Frozen values emitted by the production v10 staging algorithm. Keep this fixture independent
// from the current implementation so a staging-ID change cannot silently rewrite legacy history.
private let syntheticV10ReceiptID =
  "347b3852f34f361db60db8639cea84ff9fdd275a0095e888b970af82c82c17df"
private let syntheticV10EventID = String(repeating: "e", count: 64)
private let syntheticV10AccountID = String(repeating: "c", count: 64)
private let syntheticV10SourceRecordID =
  "b10dcc7ff65ce7069970a3a9e0c8eacead3b81944e6e1a7a55d2ff456db626cb"
private let syntheticV10ProvenanceIDs = [
  "fe5e3a5af9fdb64fff1e451fb5b1802d08e8bed9d0e81f174cb75fe25ca42460",
  "1ad61dc248d88814c0a7690d8820a4db8aef7e9e299e13cf03a69ed7f90239fc",
  "6118c034e3d80b7d266e03c28e6ed6c8e0d9c3be5e860807dd0a2f375fa94420",
  "02b74322ce27f171835b906f436cd4abac79d9fc252f40a6c412768bf37176e0",
  "8998f1e6fe333d6d9b50b4c9cdc8312b167e7ca4be15e69d8f2370124a31aa4b",
]
private let syntheticV10Payload = Data("synthetic-payload".utf8)
private let syntheticV10PayloadProvenanceID =
  "1e3bbe68d8576f00ca64a192fe7d9e5ad5e7df7f4ed28878392fa6aeddc8d9bf"
private let syntheticV10AnchorID =
  "afa9183e6f90d0ca4224fe10fd618fbead3afbe211806fe94a6dfa998ed4fd2e"
private let syntheticV10PayloadID =
  "26f04c113a5713969327fb99b9d491a6d88c11113ed5a569e04aa60f4b3fcb67"

private func syntheticV10EventSetHash(
  amountProvenanceID: String = syntheticV10ProvenanceIDs[0]
) -> String {
  let semantics = ["amount", "currency", "occurred_at", "account", "kind"]
  var components = [
    CanonicalReceiptDigest.eventSetPrefix, syntheticV10EventID, syntheticV10AccountID,
    "expense", "1.00", "USD", "0", "1970", "1", "1", "0", "0", "0", "0", "fixed",
    "0", "millisecond", "0", syntheticV10SourceRecordID, amountProvenanceID,
  ]
  for (semantic, provenanceID) in zip(semantics, syntheticV10ProvenanceIDs)
    .sorted(by: { $0.0 < $1.0 })
  {
    components.append(contentsOf: [
      semantic, provenanceID, "optional:some", "TEXT", "text",
    ])
  }
  return CanonicalReceiptDigest.hash(components)
}

private func syntheticV10ReconciliationHash(
  eventSetHash: String,
  preservationHash: String = CanonicalReceiptDigest.hash([
    "ledger-atlas/receipt-owned-preservation-set/v4"
  ])
) -> String {
  CanonicalReceiptDigest.hash([
    "ledger-atlas/canonical-receipt-integrity/v6", syntheticV10ReceiptID,
    syntheticV10ArtifactID, syntheticV10ArtifactID, "profile", "adapter", eventSetHash, "1",
    "8", eventSetHash, preservationHash,
  ])
}

private func syntheticV10PreservationHash(
  storageClass: CanonicalFieldStorageClass = .text
) -> String {
  let anchorMembership = [
    syntheticV10ReceiptID, syntheticV10SourceRecordID, "record", syntheticV10AnchorID,
    syntheticV10SourceRecordID, "record", "optional:none",
  ]
  let fieldMembership = [
    syntheticV10ReceiptID, syntheticV10PayloadProvenanceID, "field", syntheticV10AnchorID,
    syntheticV10SourceRecordID, "record", "optional:some", syntheticV10PayloadID,
  ]
  var components = ["ledger-atlas/receipt-owned-preservation-set/v4"]
  for membership in [anchorMembership, fieldMembership].sorted(by: { $0[1] < $1[1] }) {
    components.append(contentsOf: membership)
  }
  components.append(contentsOf: [
    syntheticV10AnchorID, syntheticV10ReceiptID, syntheticV10SourceRecordID, "record",
    syntheticV10ArtifactID, "profile", "adapter", "optional:none", "T", "optional:some",
    "row", syntheticV10PayloadID, syntheticV10ReceiptID, syntheticV10AnchorID,
    syntheticV10PayloadProvenanceID, "1", "optional:some", "TEXT", storageClass.rawValue,
    CanonicalReceiptDigest.sha256(syntheticV10Payload), syntheticV10ArtifactID, "profile",
    "adapter", "optional:none", "T", "row", "optional:some", "5", "optional:some",
    "opaque", syntheticV10PayloadProvenanceID,
  ])
  return CanonicalReceiptDigest.hash(components)
}

private func addSyntheticV10Preservation(to url: URL) throws {
  let payloadHex = syntheticV10Payload.map { String(format: "%02x", $0) }.joined()
  let eventSetHash = syntheticV10EventSetHash()
  let preservationHash = syntheticV10PreservationHash()
  try mutateV10ImportLedger(
    at: url,
    sql: """
      INSERT INTO provenance_reference VALUES ('\(syntheticV10PayloadProvenanceID)',
        '\(syntheticV10ArtifactID)', 'profile', 'adapter', NULL, 'T', 'row', 5, 'opaque');
      INSERT INTO receipt_preservation_anchor VALUES ('\(syntheticV10AnchorID)',
        '\(syntheticV10ReceiptID)', '\(syntheticV10SourceRecordID)', 'record',
        '\(syntheticV10ArtifactID)', 'profile', 'adapter', NULL, 'T', 'row');
      INSERT INTO receipt_preservation_payload VALUES ('\(syntheticV10PayloadID)',
        '\(syntheticV10ReceiptID)', '\(syntheticV10AnchorID)',
        '\(syntheticV10PayloadProvenanceID)', '\(syntheticV10PayloadProvenanceID)', 1,
        'TEXT', 'text', X'\(payloadHex)');
      INSERT INTO receipt_preservation_membership VALUES ('\(syntheticV10ReceiptID)',
        '\(syntheticV10SourceRecordID)', 'record', '\(syntheticV10AnchorID)',
        '\(syntheticV10SourceRecordID)', 'record', NULL);
      INSERT INTO receipt_preservation_membership VALUES ('\(syntheticV10ReceiptID)',
        '\(syntheticV10PayloadProvenanceID)', 'field', '\(syntheticV10AnchorID)',
        '\(syntheticV10SourceRecordID)', 'record', '\(syntheticV10PayloadID)');
      UPDATE import_receipt SET reconciliation_hash='\(syntheticV10ReconciliationHash(
        eventSetHash: eventSetHash, preservationHash: preservationHash))';
      """)
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
  let receipt = syntheticV10ReceiptID
  let artifact = syntheticV10ArtifactID
  let eventID = syntheticV10EventID
  let accountID = syntheticV10AccountID
  let sourceRecordID = syntheticV10SourceRecordID
  let provenances = syntheticV10ProvenanceIDs
  let provenanceSQL = provenances.enumerated().map { index, id in
    "INSERT INTO provenance_reference VALUES ('\(id)', '\(artifact)', 'profile', 'adapter', NULL, 'T', 'row', \(index), 'c\(index)')"
  }.joined(separator: ";")
  let semantics = ["amount", "currency", "occurred_at", "account", "kind"]
  let bindings = zip(semantics, provenances).map { semantic, id in
    "INSERT INTO event_source_binding VALUES ('\(eventID)', '\(semantic)', '\(id)', 'TEXT', 'text'); INSERT INTO receipt_binding VALUES ('\(receipt)', '\(eventID)', '\(semantic)', '\(id)')"
  }.joined(separator: ";")
  let eventSetHash = syntheticV10EventSetHash()
  let reconciliationHash = syntheticV10ReconciliationHash(eventSetHash: eventSetHash)
  let sql = """
    PRAGMA application_id=\(CanonicalLedgerSchema.applicationID);
    INSERT INTO ledger_meta VALUES ('schema_version','10'), ('ledger_identity','ledger-atlas-canonical'), ('schema_fingerprint','\(CanonicalLedgerSchema.legacyV10Fingerprint)');
    \(provenanceSQL);
    INSERT INTO economic_event VALUES ('\(eventID)', '\(accountID)', 'expense', '1.00', 'USD', 0, 1970, 1, 1, 0, 0, 0, 0, 'fixed', '0', 'millisecond', 0, '\(sourceRecordID)', '\(provenances[0])');
    INSERT INTO import_receipt VALUES ('\(receipt)', '\(artifact)', '\(artifact)', 'profile', 'adapter', '\(reconciliationHash)', '\(eventSetHash)', 1, 8);
    INSERT INTO receipt_event VALUES ('\(receipt)', '\(eventID)');
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

private func overwriteInPlace(_ bytes: Data, at url: URL) throws {
  let descriptor = Darwin.open(url.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
  guard descriptor >= 0 else { throw LifecycleTestError.sqlite }
  defer { Darwin.close(descriptor) }
  guard ftruncate(descriptor, 0) == 0, lseek(descriptor, 0, SEEK_SET) == 0 else {
    throw LifecycleTestError.sqlite
  }
  let written = bytes.withUnsafeBytes {
    Darwin.write(descriptor, $0.baseAddress, $0.count)
  }
  guard written == bytes.count, fsync(descriptor) == 0 else { throw LifecycleTestError.sqlite }
}

private func overwriteSameLengthRestoringModificationTime(_ bytes: Data, at url: URL) throws {
  let descriptor = Darwin.open(url.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
  guard descriptor >= 0 else { throw LifecycleTestError.sqlite }
  defer { Darwin.close(descriptor) }
  var before = stat()
  guard fstat(descriptor, &before) == 0, before.st_size == off_t(bytes.count) else {
    throw LifecycleTestError.sqlite
  }
  let written = bytes.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
  var times = [before.st_atimespec, before.st_mtimespec]
  guard written == bytes.count, fsync(descriptor) == 0, futimens(descriptor, &times) == 0 else {
    throw LifecycleTestError.sqlite
  }
  var after = stat()
  guard fstat(descriptor, &after) == 0,
    after.st_ctimespec.tv_sec != before.st_ctimespec.tv_sec
      || after.st_ctimespec.tv_nsec != before.st_ctimespec.tv_nsec
  else { throw LifecycleTestError.sqlite }
}

private func writeInactiveJournalBinding(for databaseURL: URL) throws {
  let journalURL = URL(fileURLWithPath: databaseURL.path + "-journal")
  try Data().write(to: journalURL)
  guard chmod(journalURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
    throw LifecycleTestError.sqlite
  }
  var database = stat()
  var journal = stat()
  guard lstat(databaseURL.path, &database) == 0, lstat(journalURL.path, &journal) == 0 else {
    throw LifecycleTestError.sqlite
  }
  let payload =
    "ledger-atlas-journal-v3\n\(database.st_dev)\n\(database.st_ino)\n\(database.st_birthtimespec.tv_sec)\n\(database.st_birthtimespec.tv_nsec)\n\(journal.st_dev)\n\(journal.st_ino)\n\(journal.st_birthtimespec.tv_sec)\n\(journal.st_birthtimespec.tv_nsec)\n"
  let bindingURL = URL(fileURLWithPath: journalURL.path + ".ledger-atlas-binding")
  try Data(payload.utf8).write(to: bindingURL)
  guard chmod(bindingURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
    throw LifecycleTestError.sqlite
  }
}

private func sha256Hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func rewriteUpgradeState(_ url: URL, currentDigest: String) throws {
  let data = try Data(contentsOf: url)
  guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    throw LifecycleTestError.sqlite
  }
  object["currentDigest"] = currentDigest
  try JSONSerialization.data(withJSONObject: object).write(to: url)
  guard chmod(url.path, mode_t(S_IRUSR | S_IWUSR)) == 0 else { throw LifecycleTestError.sqlite }
}

private func rewriteUpgradeStateDisplacedInode(_ url: URL, to inode: UInt64) throws {
  let data = try Data(contentsOf: url)
  let json = String(decoding: data, as: UTF8.self)
  guard let marker = json.range(of: "\"displacedInode\":") else {
    throw LifecycleTestError.sqlite
  }
  let valueStart = marker.upperBound
  guard let valueEnd = json[valueStart...].firstIndex(where: { !$0.isNumber }) else {
    throw LifecycleTestError.sqlite
  }
  let rewritten = String(json[..<valueStart]) + String(inode) + String(json[valueEnd...])
  try Data(rewritten.utf8).write(to: url)
  guard chmod(url.path, mode_t(S_IRUSR | S_IWUSR)) == 0 else { throw LifecycleTestError.sqlite }
}

private enum LifecycleTestError: Swift.Error { case sqlite, injected }
