import CSQLite
import CryptoKit
import Foundation
import LedgerAdapterSemantics
import LedgerCore

/// The only path-based boundary for creating, opening, and upgrading canonical ledgers.
public enum LedgerStoreLifecycle {
  // In-memory legacy migration uses sqlite3 backup plus sqlite3_serialize.  Keep this
  // preflight bounded so a sparse/hostile legacy file cannot force an unbounded allocation;
  // larger ledgers need a future streaming migration path.
  private static let maximumMigratedImageBytes: UInt64 = 512 * 1024 * 1024

  public enum Inspection: Equatable, Sendable { case current, upgradeRequired }
  public enum Disposition: Equatable, Sendable { case created, opened, upgraded }
  public enum PublicationPhase: Equatable, Sendable {
    case recoveryPublished, currentPublished, reconciledCurrent
  }

  public struct Result {
    public let store: LedgerStore
    public let disposition: Disposition
    public let recoveryImageURL: URL?
    package let createdIdentity: FileIdentity?
  }

  package struct FileIdentity: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64

    init(_ value: stat) {
      device = UInt64(value.st_dev)
      inode = UInt64(value.st_ino)
    }

    func matches(_ value: stat) -> Bool {
      device == UInt64(value.st_dev) && inode == UInt64(value.st_ino)
    }
  }

  public enum Error: Swift.Error, Equatable, Sendable {
    case unsafePath
    case pathChanged
    case companionPresent
    case invalidStore
    case unsupportedStore
    case destinationExists
    case recoveryImageExists
    case busy
    case publicationFailed
    case publicationCompleted(phase: PublicationPhase, recoveryImageExists: Bool)
    case interrupted
  }

  package enum TestPhase: Equatable, Sendable {
    case afterLeaseAcquired
    case beforeCreatePublication
    case afterCreateRenameBeforeDirectorySync
    case afterTemporaryCreated
    case afterTemporaryWriteBeforeRecord
    case afterTemporaryValidated
    case afterSourceAuthenticated
    case afterRecoveryCreated
    case afterRecoveryValidated
    case afterRecoveryRenameBeforeDirectorySync
    case afterRecoveryPublished
    case beforeRecoveryDescriptorDup
    case afterReplacementCreated
    case afterReplacementMigrated
    case afterReplacementValidated
    case beforeUpgradeStatePublication
    case afterUpgradeStatePublished
    case afterSwapBeforeJournalRetarget
    case afterSwapBeforeValidation
    case afterPublication
    case afterPublishedStoreOpened
    case beforeDisplacedTruncate
    case afterDisplacedSourceDigestBeforeTruncate
    case beforeReconciliationMutation
    case beforeUnpublishedReplacementTruncate

    package static let creationPhases: [Self] = [
      .afterTemporaryCreated, .afterTemporaryWriteBeforeRecord, .afterTemporaryValidated,
      .afterPublication,
    ]
    package static let upgradePhases: [Self] = [
      .afterSourceAuthenticated, .afterRecoveryCreated, .afterRecoveryValidated,
      .afterRecoveryPublished, .beforeRecoveryDescriptorDup, .afterReplacementCreated,
      .afterReplacementMigrated,
      .afterReplacementValidated, .beforeUpgradeStatePublication, .afterUpgradeStatePublished,
      .afterPublication,
      .afterSwapBeforeValidation, .afterPublishedStoreOpened, .beforeDisplacedTruncate,
    ]
  }

  package typealias TestHook = (TestPhase) throws -> Void

  public static func inspect(at url: URL) throws -> Inspection {
    let source = try openPinned(at: url)
    defer { Darwin.close(source.descriptor) }
    let result = try inspect(source, trustKey: try LedgerReceiptTrust.key(for: url, create: false))
    try requirePath(url, matches: source.identity)
    switch result {
    case .current:
      try requireInspectableCompanions(at: url, databaseDescriptor: source.descriptor)
    case .upgradeRequired: try requireSourceCompanionsStillSafe(source, at: url)
    }
    try requirePath(url, matches: source.identity)
    return result
  }

  public static func create(at url: URL) throws -> Result {
    try create(at: url, testing: nil)
  }

  package static func create(at url: URL, testing hook: TestHook?) throws -> Result {
    do { return try createImpl(at: url, hook: hook) } catch let error as Error { throw error } catch
    { throw Error.interrupted }
  }

  public static func open(at url: URL) throws -> Result {
    try open(at: url, testing: nil)
  }

  package static func open(at url: URL, testing hook: TestHook?) throws -> Result {
    do { return try openImpl(at: url, hook: hook) } catch let error as Error { throw error } catch {
      throw Error.interrupted
    }
  }

  /// Where an upgrade keeps the untouched pre-upgrade ledger.  The `.v10-recovery` suffix is
  /// kept from the first upgrade path so recovery images from earlier builds are still found;
  /// the file holds whichever older release was upgraded.
  public static func recoveryImageURL(for url: URL) -> URL {
    URL(fileURLWithPath: url.path + ".v10-recovery")
  }

  private static func upgradeStateURL(for url: URL) -> URL {
    URL(fileURLWithPath: url.path + ".upgrade-state")
  }

  private static func createImpl(at url: URL, hook: TestHook?) throws -> Result {
    let destination = try Destination(url)
    defer { Darwin.close(destination.parentDescriptor) }
    let lease = try LifecycleLease(destination)
    defer { lease.release() }
    try invoke(hook, .afterLeaseAcquired)
    guard !entryExists(destination.leaf, in: destination.parentDescriptor) else {
      throw Error.destinationExists
    }
    let image = try currentImage()
    try lease.requireBound(destination)
    let temporary = try TemporaryFile(
      parentDescriptor: destination.parentDescriptor, prefix: destination.temporaryPrefix("create"))
    var published = false
    defer { temporary.closeAndNeutralizeUnlessPublished(published) }

    try invoke(hook, .afterTemporaryCreated)
    try lease.requireBound(destination)
    try write(image, to: temporary) {
      try invoke(hook, .afterTemporaryWriteBeforeRecord)
    }
    try validate(temporary.descriptor, as: .current)
    try invoke(hook, .afterTemporaryValidated)
    try requireNotCancelled()
    try requireTemporaryFileStillSafe(temporary)
    try requireNoCompanions(at: url)
    try requireTemporaryFileBinding(temporary)
    try requireNoCompanions(at: url)
    // Lease binding is intentionally last: all preceding checks are bounded to identity/path
    // metadata after the full temp-content authentication above.
    try lease.requireBound(destination)
    try invoke(hook, .beforeCreatePublication)
    let publishedIdentity = try publishTemporaryCopy(
      temporary, parentDescriptor: destination.parentDescriptor, leaf: destination.leaf)
    do {
      try temporary.unlinkAfterPublication()
    } catch {
      throw Error.publicationCompleted(phase: .currentPublished, recoveryImageExists: false)
    }
    published = true
    do { try invoke(hook, .afterCreateRenameBeforeDirectorySync) } catch {
      throw Error.publicationCompleted(phase: .currentPublished, recoveryImageExists: false)
    }
    guard fsync(destination.parentDescriptor) == 0 else {
      throw Error.publicationCompleted(phase: .currentPublished, recoveryImageExists: false)
    }
    do { try invoke(hook, .afterPublication) } catch {
      throw Error.publicationCompleted(phase: .currentPublished, recoveryImageExists: false)
    }
    let store: LedgerStore
    do {
      try lease.requireBound(destination)
      try requirePath(url, matches: publishedIdentity)
      try requireNoCompanions(at: url)
      try lease.requireBound(destination)
      store = try openPublished(at: url, expected: publishedIdentity)
    } catch {
      throw Error.publicationCompleted(
        phase: .currentPublished, recoveryImageExists: false)
    }
    return Result(
      store: store, disposition: .created, recoveryImageURL: nil,
      createdIdentity: FileIdentity(publishedIdentity))
  }

  /// Publish from the already-authenticated descriptor. A pathname can be replaced after the
  /// final check on macOS, so rename-by-path would publish an attacker-supplied inode. O_EXCL plus
  /// descriptor-bound copying makes the destination bytes come only from the pinned temporary.
  private static func publishTemporaryCopy(
    _ temporary: TemporaryFile, parentDescriptor: Int32, leaf: String
  ) throws -> stat {
    try requireTemporaryFileStillSafe(temporary)
    let destination = Darwin.openat(
      parentDescriptor, leaf,
      O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      mode_t(S_IRUSR | S_IWUSR))
    guard destination >= 0 else {
      if errno == EEXIST { throw Error.destinationExists }
      throw Error.publicationFailed
    }
    var destinationIdentity = stat()
    guard fstat(destination, &destinationIdentity) == 0,
      safeFile(destinationIdentity)
    else {
      Darwin.close(destination)
      _ = unlinkat(parentDescriptor, leaf, 0)
      _ = fsync(parentDescriptor)
      throw Error.publicationFailed
    }
    do {
      let sourceIdentity = try identity(of: temporary.descriptor)
      guard sourceIdentity.st_size >= 0 else { throw Error.pathChanged }
      var offset: off_t = 0
      var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
      while offset < sourceIdentity.st_size {
        let amount = min(buffer.count, Int(sourceIdentity.st_size - offset))
        let readCount = pread(temporary.descriptor, &buffer, amount, offset)
        guard readCount == amount else { throw Error.pathChanged }
        var written = 0
        while written < amount {
          let count = buffer.withUnsafeBytes {
            Darwin.write(destination, $0.baseAddress!.advanced(by: written), amount - written)
          }
          guard count > 0 else { throw Error.publicationFailed }
          written += count
        }
        offset += off_t(amount)
      }
      guard fsync(destination) == 0 else { throw Error.publicationFailed }
      try requireTemporaryFileStillSafe(temporary)
      destinationIdentity = try identity(of: destination)
      guard safeFile(destinationIdentity), destinationIdentity.st_size == sourceIdentity.st_size,
        try digest(destination) == temporary.lastAuthoredState.digest,
        fsync(parentDescriptor) == 0
      else { throw Error.pathChanged }
      Darwin.close(destination)
      return destinationIdentity
    } catch {
      var atPath = stat()
      if fstatat(parentDescriptor, leaf, &atPath, AT_SYMLINK_NOFOLLOW) == 0,
        sameInode(atPath, destinationIdentity)
      {
        _ = unlinkat(parentDescriptor, leaf, 0)
        _ = fsync(parentDescriptor)
      }
      Darwin.close(destination)
      throw error
    }
  }

  private static func openImpl(at url: URL, hook: TestHook?) throws -> Result {
    let destination = try Destination(url)
    defer { Darwin.close(destination.parentDescriptor) }
    let lease = try LifecycleLease(destination)
    defer { lease.release() }
    try invoke(hook, .afterLeaseAcquired)
    try lease.requireBound(destination)
    let stateLeaf = upgradeStateURL(for: url).lastPathComponent
    let stateExists = entryExists(stateLeaf, in: destination.parentDescriptor)
    let allowsUpgradeTransitionCompanions =
      stateExists
      ? !(try inactiveUpgradeState(stateLeaf, parentDescriptor: destination.parentDescriptor))
      : false
    let source = try openPinned(
      at: url, allowingUpgradeTransitionCompanions: allowsUpgradeTransitionCompanions)
    defer { Darwin.close(source.descriptor) }
    let trustKey = try LedgerReceiptTrust.key(for: url, create: false)
    // A current-schema file is fully checked once, by `openPublished` on the pinned connection
    // the store keeps. Checking it here as well doubled the time to open a large ledger.
    switch try inspect(source, trustKey: trustKey, checkingCurrent: false) {
    case .current:
      let recovered = try reconcilePublishedUpgrade(source, at: url, lease: lease, hook: hook)
      try lease.requireBound(destination)
      try requirePath(url, matches: source.identity)
      try requireInspectableCompanions(at: url, databaseDescriptor: source.descriptor)
      try lease.requireBound(destination)
      let store: LedgerStore
      do {
        store = try openPublished(
          at: url, expected: source.identity, contentDigest: source.contentDigest)
      } catch {
        if recovered != nil {
          let recoveryLeaf = recovered!.url.lastPathComponent
          throw Error.publicationCompleted(
            phase: .reconciledCurrent,
            recoveryImageExists: hasValidRecoveryImage(
              leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
              expectedDigest: recovered!.digest, expectedIdentity: recovered!.identity))
        }
        throw error
      }
      try lease.requireBound(destination)
      try requireInspectableCompanions(at: url, databaseDescriptor: source.descriptor)
      try requirePath(url, matches: source.identity)
      return Result(
        store: store, disposition: .opened, recoveryImageURL: recovered?.url,
        createdIdentity: nil)
    case .upgradeRequired:
      try invoke(hook, .afterSourceAuthenticated)
      try requirePath(url, matches: source.identity)
      try requireSourceCompanionsStillSafe(source, at: url)
      try requireLegacyMigrationSupported(source.descriptor)
      try clearUnpublishedUpgradeState(source, at: url, lease: lease, hook: hook)
      return try upgrade(source, at: url, lease: lease, hook: hook)
    }
  }

  private static func upgrade(
    _ source: PinnedFile, at url: URL, lease: LifecycleLease, hook: TestHook?
  ) throws -> Result {
    try requireMigrationSizeBound(source.descriptor)
    let destination = try Destination(url)
    defer { Darwin.close(destination.parentDescriptor) }
    let recoveryURL = recoveryImageURL(for: url)
    let recoveryLeaf = recoveryURL.lastPathComponent
    var temporaryRecovery: TemporaryFile?
    var recoveryPublished = false
    var didPublishRecovery = false
    defer { temporaryRecovery?.closeAndNeutralizeUnlessPublished(recoveryPublished) }
    let recovery: PinnedFile
    if entryExists(recoveryLeaf, in: destination.parentDescriptor) {
      do {
        recovery = try openValidatedRecovery(
          source: source, url: recoveryURL, leaf: recoveryLeaf,
          parentDescriptor: destination.parentDescriptor)
      } catch {
        throw Error.recoveryImageExists
      }
    } else {
      try requireNotCancelled()
      try lease.requireBound(destination)
      let temporary = try TemporaryFile(
        parentDescriptor: destination.parentDescriptor,
        prefix: destination.temporaryPrefix("recovery"))
      temporaryRecovery = temporary
      try invoke(hook, .afterRecoveryCreated)
      try copy(source.descriptor, to: temporary)
      try requirePath(url, matches: source.identity)
      guard filesEqual(source.descriptor, temporary.descriptor) else { throw Error.pathChanged }
      try validate(temporary.descriptor, as: .legacy)
      try invoke(hook, .afterRecoveryValidated)
      try requireTemporaryRecoveryStillSafe(
        temporary, source: source, parentDescriptor: destination.parentDescriptor)
      try requireNotCancelled()
      try requirePath(url, matches: source.identity)
      try requireSourceCompanionsStillSafe(source, at: url)
      try requireTemporaryFileBinding(temporary)
      // Lease binding is the final check before the publication rename; no expensive digest or
      // file comparison follows it.
      try lease.requireBound(destination)
      guard
        Darwin.renameatx_np(
          destination.parentDescriptor, temporary.leaf, destination.parentDescriptor,
          recoveryLeaf, UInt32(RENAME_EXCL)) == 0
      else {
        if errno == EEXIST { throw Error.recoveryImageExists }
        throw Error.publicationFailed
      }
      recoveryPublished = true
      do { try invoke(hook, .afterRecoveryRenameBeforeDirectorySync) } catch {
        throw Error.publicationCompleted(
          phase: .recoveryPublished,
          recoveryImageExists: hasValidRecoveryImage(
            leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
            expectedDigest: source.contentDigest,
            expectedIdentity: temporary.lastAuthoredState.identity))
      }
      guard fsync(destination.parentDescriptor) == 0 else {
        throw Error.publicationCompleted(
          phase: .recoveryPublished,
          recoveryImageExists: hasValidRecoveryImage(
            leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
            expectedDigest: source.contentDigest,
            expectedIdentity: temporary.lastAuthoredState.identity))
      }
      do { try invoke(hook, .beforeRecoveryDescriptorDup) } catch {
        throw Error.publicationCompleted(
          phase: .recoveryPublished,
          recoveryImageExists: hasValidRecoveryImage(
            leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
            expectedDigest: source.contentDigest,
            expectedIdentity: temporary.lastAuthoredState.identity))
      }
      let descriptor = dup(temporary.descriptor)
      guard descriptor >= 0 else {
        throw Error.publicationCompleted(
          phase: .recoveryPublished,
          recoveryImageExists: hasValidRecoveryImage(
            leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
            expectedDigest: source.contentDigest,
            expectedIdentity: temporary.lastAuthoredState.identity))
      }
      do {
        let value = try identity(of: descriptor)
        recovery = PinnedFile(
          descriptor: descriptor, identity: value, url: recoveryURL,
          contentDigest: try digest(descriptor))
      } catch {
        Darwin.close(descriptor)
        throw error
      }
      didPublishRecovery = true
    }
    defer { Darwin.close(recovery.descriptor) }
    if didPublishRecovery {
      do { try invoke(hook, .afterRecoveryPublished) } catch {
        throw Error.publicationCompleted(
          phase: .recoveryPublished,
          recoveryImageExists: hasValidRecoveryImage(
            leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
            expectedDigest: recovery.contentDigest, expectedIdentity: recovery.identity))
      }
    }
    try reportingPublication(
      .recoveryPublished,
      recoveryImageExists: hasValidRecoveryImage(
        leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
        expectedDigest: recovery.contentDigest, expectedIdentity: recovery.identity)
    ) {
      try requireRecoveryStillSafe(
        recovery, source: source, leaf: recoveryLeaf,
        parentDescriptor: destination.parentDescriptor)
    }

    try reportingPublication(
      .recoveryPublished,
      recoveryImageExists: hasValidRecoveryImage(
        leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
        expectedDigest: recovery.contentDigest, expectedIdentity: recovery.identity)
    ) {
      try requireNotCancelled()
    }

    let replacement = try reportingPublication(
      .recoveryPublished,
      recoveryImageExists: hasValidRecoveryImage(
        leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
        expectedDigest: recovery.contentDigest, expectedIdentity: recovery.identity)
    ) {
      try lease.requireBound(destination)
      return try TemporaryFile(
        parentDescriptor: destination.parentDescriptor,
        prefix: destination.temporaryPrefix("upgrade"))
    }
    var replacementPublished = false
    defer { replacement.closeAndNeutralizeUnlessPublished(replacementPublished) }
    try reportingPublication(
      .recoveryPublished,
      recoveryImageExists: hasValidRecoveryImage(
        leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
        expectedDigest: recovery.contentDigest, expectedIdentity: recovery.identity)
    ) {
      try invoke(hook, .afterReplacementCreated)
    }
    try reportingPublication(
      .recoveryPublished,
      recoveryImageExists: hasValidRecoveryImage(
        leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
        expectedDigest: recovery.contentDigest, expectedIdentity: recovery.identity)
    ) {
      try requireRecoveryStillSafe(
        recovery, source: source, leaf: recoveryLeaf,
        parentDescriptor: destination.parentDescriptor)
    }
    try reportingPublication(
      .recoveryPublished,
      recoveryImageExists: hasValidRecoveryImage(
        leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
        expectedDigest: recovery.contentDigest, expectedIdentity: recovery.identity)
    ) {
      try write(try migratedImage(from: source.descriptor, at: url), to: replacement)
      try invoke(hook, .afterReplacementMigrated)
    }
    try reportingPublication(
      .recoveryPublished,
      recoveryImageExists: hasValidRecoveryImage(
        leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
        expectedDigest: recovery.contentDigest, expectedIdentity: recovery.identity)
    ) {
      try requireRecoveryStillSafe(
        recovery, source: source, leaf: recoveryLeaf,
        parentDescriptor: destination.parentDescriptor)
    }
    try reportingPublication(
      .recoveryPublished,
      recoveryImageExists: hasValidRecoveryImage(
        leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
        expectedDigest: recovery.contentDigest, expectedIdentity: recovery.identity)
    ) {
      try validate(
        replacement.descriptor, as: .current,
        trustKey: try LedgerReceiptTrust.key(for: url, create: false))
      try invoke(hook, .afterReplacementValidated)
    }
    try reportingPublication(
      .recoveryPublished,
      recoveryImageExists: hasValidRecoveryImage(
        leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
        expectedDigest: recovery.contentDigest, expectedIdentity: recovery.identity)
    ) {
      try requireRecoveryStillSafe(
        recovery, source: source, leaf: recoveryLeaf,
        parentDescriptor: destination.parentDescriptor)
    }
    try reportingPublication(
      .recoveryPublished,
      recoveryImageExists: hasValidRecoveryImage(
        leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
        expectedDigest: recovery.contentDigest, expectedIdentity: recovery.identity)
    ) {
      try requirePath(url, matches: source.identity)
      try requireSourceCompanionsStillSafe(source, at: url)
    }
    try reportingPublication(
      .recoveryPublished,
      recoveryImageExists: hasValidRecoveryImage(
        leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
        expectedDigest: recovery.contentDigest, expectedIdentity: recovery.identity)
    ) {
      try requireRecoveryStillSafe(
        recovery, source: source, leaf: recoveryLeaf,
        parentDescriptor: destination.parentDescriptor)
    }

    let writableSource = Darwin.openat(
      destination.parentDescriptor, destination.leaf, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
    guard writableSource >= 0 else {
      throw Error.publicationCompleted(
        phase: .recoveryPublished,
        recoveryImageExists: hasValidRecoveryImage(
          leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
          expectedDigest: recovery.contentDigest, expectedIdentity: recovery.identity))
    }
    defer { Darwin.close(writableSource) }
    let writableSourceIdentity = try reportingPublication(
      .recoveryPublished,
      recoveryImageExists: hasValidRecoveryImage(
        leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
        expectedDigest: recovery.contentDigest, expectedIdentity: recovery.identity)
    ) { try identity(of: writableSource) }
    guard safeFile(writableSourceIdentity), sameFile(writableSourceIdentity, source.identity) else {
      throw Error.publicationCompleted(
        phase: .recoveryPublished,
        recoveryImageExists: hasValidRecoveryImage(
          leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
          expectedDigest: recovery.contentDigest, expectedIdentity: recovery.identity))
    }

    let state = try reportingPublication(
      .recoveryPublished,
      recoveryImageExists: hasValidRecoveryImage(
        leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
        expectedDigest: recovery.contentDigest, expectedIdentity: recovery.identity)
    ) {
      try lease.requireBound(destination)
      return try publishUpgradeState(
        current: replacement, recovery: recovery, source: source, destination: destination,
        at: url, lease: lease, hook: hook)
    }
    defer { Darwin.close(state.descriptor) }
    try reportingPublication(
      .recoveryPublished,
      recoveryImageExists: hasValidRecoveryImage(
        leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
        expectedDigest: recovery.contentDigest, expectedIdentity: recovery.identity)
    ) {
      try requireNotCancelled()
      try lease.requireBound(destination)
      try requireStateBound(state, destination: destination)
      try requirePath(url, matches: source.identity)
      try requireSourceCompanionsStillSafe(source, at: url)
      try requireTemporaryFileStillSafe(replacement)
    }
    replacementPublished = true
    do { try invoke(hook, .afterUpgradeStatePublished) } catch {
      throw Error.publicationCompleted(
        phase: .recoveryPublished,
        recoveryImageExists: hasValidRecoveryImage(
          leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
          expectedDigest: recovery.contentDigest, expectedIdentity: recovery.identity))
    }
    try reportingPublication(
      .recoveryPublished,
      recoveryImageExists: hasValidRecoveryImage(
        leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
        expectedDigest: recovery.contentDigest, expectedIdentity: recovery.identity)
    ) {
      try requireNotCancelled()
      try lease.requireBound(destination)
      try requireStateBound(state, destination: destination)
      try requirePath(url, matches: source.identity)
      try requireSourceCompanionsStillSafe(source, at: url)
      try requireTemporaryFileStillSafe(replacement)
    }

    try reportingPublication(
      .recoveryPublished,
      recoveryImageExists: hasValidRecoveryImage(
        leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
        expectedDigest: recovery.contentDigest, expectedIdentity: recovery.identity)
    ) {
      try lease.requireBound(destination)
      try requireStateBound(state, destination: destination)
      try requirePath(url, matches: source.identity)
      try requireSourceCompanionsStillSafe(source, at: url)
      try requireTemporaryFileStillSafe(replacement)
      try requireRecoveryStillSafe(
        recovery, source: source, leaf: recoveryLeaf,
        parentDescriptor: destination.parentDescriptor)
      let expected = try migratedImage(from: source.descriptor, at: url)
      guard digest(expected) == replacement.lastAuthoredState.digest else {
        throw Error.pathChanged
      }
      try requirePath(url, matches: source.identity)
      try requireRecoveryStillSafe(
        recovery, source: source, leaf: recoveryLeaf,
        parentDescriptor: destination.parentDescriptor)
      try requireTemporaryFileStillSafe(replacement)
    }
    // The migration digest above may have traversed the entire v10 database.  Bind the lease,
    // state, source, recovery, replacement, and companions again at the exact swap boundary.
    try requireNotCancelled()
    try requirePath(url, matches: source.identity)
    try requireSourceCompanionsStillSafe(source, at: url)
    try requireFileBinding(
      source.descriptor, expectedIdentity: source.identity, leaf: destination.leaf,
      parentDescriptor: destination.parentDescriptor)
    try requireTemporaryFileBinding(replacement)
    try requirePinnedFileBinding(
      recovery, leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor)
    try requirePinnedFileBinding(state, parentDescriptor: destination.parentDescriptor)
    // Lease binding is last; the swap below performs no further content traversal.
    try lease.requireBound(destination)
    guard
      Darwin.renameatx_np(
        destination.parentDescriptor, replacement.leaf, destination.parentDescriptor,
        destination.leaf, UInt32(RENAME_SWAP)) == 0
    else { throw Error.publicationFailed }
    do { try invoke(hook, .afterSwapBeforeJournalRetarget) } catch {
      throw Error.publicationCompleted(
        phase: .currentPublished,
        recoveryImageExists: hasValidRecoveryImage(
          leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
          expectedDigest: recovery.contentDigest, expectedIdentity: recovery.identity))
    }
    do {
      try retargetInactiveJournal(
        from: source, to: replacement, at: url, destination: destination, lease: lease)
    } catch {
      throw Error.publicationCompleted(
        phase: .currentPublished,
        recoveryImageExists: hasValidRecoveryImage(
          leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
          expectedDigest: recovery.contentDigest, expectedIdentity: recovery.identity))
    }
    do { try invoke(hook, .afterSwapBeforeValidation) } catch {
      throw Error.publicationCompleted(
        phase: .currentPublished,
        recoveryImageExists: hasValidRecoveryImage(
          leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
          expectedDigest: recovery.contentDigest, expectedIdentity: recovery.identity))
    }
    do {
      try requireFileStillSafe(
        replacement.descriptor, expectedIdentity: replacement.lastAuthoredState.identity,
        expectedDigest: replacement.lastAuthoredState.digest, leaf: destination.leaf,
        parentDescriptor: destination.parentDescriptor, allowRenameCtime: true)
    } catch {
      throw Error.publicationCompleted(
        phase: .currentPublished,
        recoveryImageExists: hasValidRecoveryImage(
          leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
          expectedDigest: recovery.contentDigest, expectedIdentity: recovery.identity))
    }
    var displaced = stat()
    let displacedAtPath =
      fstatat(
        destination.parentDescriptor, replacement.leaf, &displaced, AT_SYMLINK_NOFOLLOW) == 0
    let displacedSafe = safeFile(displaced)
    let displacedIdentityMatches = sameContentIdentity(displaced, source.identity)
    let sourceRecoveryEqual = filesEqual(source.descriptor, recovery.descriptor)
    let directorySynced = fsync(destination.parentDescriptor) == 0
    guard displacedAtPath, displacedSafe, displacedIdentityMatches, sourceRecoveryEqual,
      directorySynced
    else {
      // The v11 replacement is already at the canonical path.  Never swap it back:
      // the displaced pathname may have been raced by another process.
      throw Error.publicationCompleted(
        phase: .currentPublished,
        recoveryImageExists: hasValidRecoveryImage(
          leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
          expectedDigest: recovery.contentDigest, expectedIdentity: recovery.identity))
    }
    replacementPublished = true
    do {
      try invoke(hook, .afterPublication)
    } catch {
      do {
        try requirePublishedRecoveryStillSafe(
          recovery, expectedDigest: recovery.contentDigest, leaf: recoveryLeaf,
          parentDescriptor: destination.parentDescriptor)
      } catch {
        throw Error.publicationCompleted(
          phase: .currentPublished,
          recoveryImageExists: hasValidRecoveryImage(
            leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
            expectedDigest: recovery.contentDigest, expectedIdentity: recovery.identity))
      }
      throw Error.publicationCompleted(
        phase: .currentPublished,
        recoveryImageExists: hasValidRecoveryImage(
          leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
          expectedDigest: recovery.contentDigest, expectedIdentity: recovery.identity))
    }
    do {
      try requirePublishedRecoveryStillSafe(
        recovery, expectedDigest: recovery.contentDigest, leaf: recoveryLeaf,
        parentDescriptor: destination.parentDescriptor)
    } catch {
      throw Error.publicationCompleted(
        phase: .currentPublished,
        recoveryImageExists: hasValidRecoveryImage(
          leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
          expectedDigest: recovery.contentDigest, expectedIdentity: recovery.identity))
    }
    let store: LedgerStore
    do {
      let expected = try identity(of: replacement.descriptor)
      try lease.requireBound(destination)
      try requirePath(url, matches: expected)
      try requireInspectableCompanions(at: url, databaseDescriptor: replacement.descriptor)
      try lease.requireBound(destination)
      store = try openPublished(at: url, expected: expected)
    } catch {
      throw Error.publicationCompleted(
        phase: .currentPublished,
        recoveryImageExists: hasValidRecoveryImage(
          leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
          expectedDigest: recovery.contentDigest, expectedIdentity: recovery.identity))
    }
    do { try invoke(hook, .afterPublishedStoreOpened) } catch {
      throw Error.publicationCompleted(
        phase: .currentPublished,
        recoveryImageExists: hasValidRecoveryImage(
          leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
          expectedDigest: recovery.contentDigest, expectedIdentity: recovery.identity))
    }
    do {
      try requirePublishedRecoveryStillSafe(
        recovery, expectedDigest: recovery.contentDigest, leaf: recoveryLeaf,
        parentDescriptor: destination.parentDescriptor)
    } catch {
      throw Error.publicationCompleted(
        phase: .currentPublished,
        recoveryImageExists: hasValidRecoveryImage(
          leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
          expectedDigest: recovery.contentDigest, expectedIdentity: recovery.identity))
    }
    do {
      try invoke(hook, .beforeDisplacedTruncate)
      try requireNotCancelled()
      try lease.requireBound(destination)
      try requireStateBound(state, destination: destination)
      try requireInspectableCompanions(at: url, databaseDescriptor: replacement.descriptor)
      try requirePublishedRecoveryStillSafe(
        recovery, expectedDigest: recovery.contentDigest, leaf: recoveryLeaf,
        parentDescriptor: destination.parentDescriptor)
      try requireFileStillSafe(
        replacement.descriptor, expectedIdentity: replacement.lastAuthoredState.identity,
        expectedDigest: replacement.lastAuthoredState.digest, leaf: destination.leaf,
        parentDescriptor: destination.parentDescriptor, allowRenameCtime: true)
      let displacedAuthenticatedIdentity = try requireFileStillSafe(
        writableSource, expectedIdentity: source.identity, expectedDigest: source.contentDigest,
        leaf: replacement.leaf, parentDescriptor: destination.parentDescriptor,
        allowRenameCtime: true)
      try invoke(hook, .afterDisplacedSourceDigestBeforeTruncate)
      // Rebind the lease and state after the final descriptor/digest reads and immediately
      // before truncating the displaced source.  The second binding closes the lock-path
      // replacement window opened by those O(file-size) checks.
      try requireFileBinding(
        replacement.descriptor, expectedIdentity: replacement.lastAuthoredState.identity,
        leaf: destination.leaf, parentDescriptor: destination.parentDescriptor,
        allowRenameCtime: true)
      try requireFileBinding(
        writableSource, expectedIdentity: displacedAuthenticatedIdentity, leaf: replacement.leaf,
        parentDescriptor: destination.parentDescriptor)
      try requirePinnedFileBinding(
        recovery, leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor)
      try requirePinnedFileBinding(state, parentDescriptor: destination.parentDescriptor)
      try requireInspectableCompanions(at: url, databaseDescriptor: replacement.descriptor)
      // Lease binding is last; the ftruncate below performs no further content traversal.
      try lease.requireBound(destination)
      guard ftruncate(writableSource, 0) == 0, fsync(writableSource) == 0 else {
        throw Error.publicationFailed
      }
      try lease.requireBound(destination)
      try requireStateBound(state, destination: destination)
      try removeUpgradeState(state, destination: destination, lease: lease)
    } catch let error as Error where error == .pathChanged {
      // After publication the displaced source may have been renamed or repurposed.  Recovery
      // truth is independent: authenticate the retained v10 image by its own pinned digest and
      // schema instead of requiring equality with that potentially raced source descriptor.
      let recoveryIsValid = hasValidRecoveryImage(
        leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
        expectedDigest: recovery.contentDigest, expectedIdentity: recovery.identity)
      throw Error.publicationCompleted(
        phase: .currentPublished, recoveryImageExists: recoveryIsValid)
    } catch {
      throw Error.publicationCompleted(
        phase: .currentPublished,
        recoveryImageExists: hasValidRecoveryImage(
          leaf: recoveryLeaf, parentDescriptor: destination.parentDescriptor,
          expectedDigest: recovery.contentDigest, expectedIdentity: recovery.identity))
    }
    return Result(
      store: store, disposition: .upgraded, recoveryImageURL: recoveryURL,
      createdIdentity: nil)
  }

  /// Removes only a just-created destination whose inode is still the one published by `create`.
  /// A path replacement or unsafe file is left untouched.
  package static func discardCreated(_ result: Result, at url: URL) -> Bool {
    guard result.disposition == .created, let expected = result.createdIdentity,
      let destination = try? Destination(url)
    else { return false }
    defer { Darwin.close(destination.parentDescriptor) }
    guard let lease = try? LifecycleLease(destination) else { return false }
    defer { lease.release() }
    guard (try? lease.requireBound(destination)) != nil else { return false }
    var current = stat()
    guard
      fstatat(destination.parentDescriptor, destination.leaf, &current, AT_SYMLINK_NOFOLLOW) == 0,
      safeFile(current), expected.matches(current),
      (try? lease.requireBound(destination)) != nil,
      unlinkat(destination.parentDescriptor, destination.leaf, 0) == 0,
      fsync(destination.parentDescriptor) == 0
    else { return false }
    return true
  }

  private struct UpgradeState: Codable {
    let replacementLeaf: String
    let currentDigest: String
    let recoveryDigest: String
    let replacementDevice: UInt64
    let replacementInode: UInt64
    let displacedDevice: UInt64
    let displacedInode: UInt64
  }

  private struct ReconciledRecovery {
    let url: URL
    let identity: stat
    let digest: String
  }

  private static func publishUpgradeState(
    current: TemporaryFile, recovery: PinnedFile, source: PinnedFile, destination: Destination,
    at url: URL, lease: LifecycleLease, hook: TestHook?
  ) throws -> PinnedFile {
    let stateURL = upgradeStateURL(for: url)
    let stateLeaf = stateURL.lastPathComponent
    let sourceIdentity = try identity(of: source.descriptor)
    let replacementIdentity = try identity(of: current.descriptor)
    let state = UpgradeState(
      replacementLeaf: current.leaf, currentDigest: try digest(current.descriptor),
      recoveryDigest: try digest(recovery.descriptor),
      replacementDevice: UInt64(replacementIdentity.st_dev),
      replacementInode: UInt64(replacementIdentity.st_ino),
      displacedDevice: UInt64(sourceIdentity.st_dev),
      displacedInode: UInt64(sourceIdentity.st_ino))
    let replacingInactiveState = entryExists(stateLeaf, in: destination.parentDescriptor)
    var inactiveState: PinnedFile?
    if replacingInactiveState {
      let existing = try openPinnedLeaf(
        stateLeaf, parentDescriptor: destination.parentDescriptor, url: stateURL)
      inactiveState = existing
      guard (try identity(of: existing.descriptor)).st_size == 0,
        existing.contentDigest == digest(Data())
      else {
        Darwin.close(existing.descriptor)
        throw Error.pathChanged
      }
    }
    defer { if let inactiveState { Darwin.close(inactiveState.descriptor) } }
    let temporary = try TemporaryFile(
      parentDescriptor: destination.parentDescriptor,
      prefix: destination.temporaryPrefix("migration-state"))
    var published = false
    defer { temporary.closeAndNeutralizeUnlessPublished(published) }
    let encodedState = try encodeUpgradeState(state)
    try write(encodedState, to: temporary)
    try invoke(hook, .beforeUpgradeStatePublication)
    try requireNotCancelled()
    try lease.requireBound(destination)
    try requirePath(url, matches: source.identity)
    try requireSourceCompanionsStillSafe(source, at: url)
    try requireTemporaryFileStillSafe(temporary)
    guard try read(temporary.descriptor) == encodedState else { throw Error.pathChanged }
    if let inactiveState {
      try requirePinnedFileStillSafe(
        inactiveState, leaf: stateLeaf, parentDescriptor: destination.parentDescriptor)
      guard (try identity(of: inactiveState.descriptor)).st_size == 0 else {
        throw Error.pathChanged
      }
    }
    // The state bytes and source/recovery identities were read above; rebind all of them and
    // the lease after those checks, immediately before replacing the inactive state pathname.
    try requireNotCancelled()
    try requirePath(url, matches: source.identity)
    try requireSourceCompanionsStillSafe(source, at: url)
    try requireTemporaryFileStillSafe(current)
    try requireRecoveryStillSafe(
      recovery, source: source, leaf: recovery.url.lastPathComponent,
      parentDescriptor: destination.parentDescriptor)
    try requireTemporaryFileStillSafe(temporary)
    guard try read(temporary.descriptor) == encodedState else { throw Error.pathChanged }
    if let inactiveState {
      try requirePinnedFileStillSafe(
        inactiveState, leaf: stateLeaf, parentDescriptor: destination.parentDescriptor)
      guard (try identity(of: inactiveState.descriptor)).st_size == 0 else {
        throw Error.pathChanged
      }
    }
    try requireFileBinding(
      source.descriptor, expectedIdentity: source.identity, leaf: destination.leaf,
      parentDescriptor: destination.parentDescriptor)
    try requireTemporaryFileBinding(current)
    try requirePinnedFileBinding(
      recovery, leaf: recovery.url.lastPathComponent,
      parentDescriptor: destination.parentDescriptor)
    try requireTemporaryFileBinding(temporary)
    if let inactiveState {
      try requirePinnedFileBinding(
        inactiveState, leaf: stateLeaf, parentDescriptor: destination.parentDescriptor)
    }
    // Lease binding is last; the rename below performs no further content traversal.
    try lease.requireBound(destination)
    guard
      Darwin.renameatx_np(
        destination.parentDescriptor, temporary.leaf, destination.parentDescriptor,
        stateLeaf, UInt32(replacingInactiveState ? RENAME_SWAP : RENAME_EXCL)) == 0,
      fsync(destination.parentDescriptor) == 0
    else { throw Error.publicationFailed }
    published = true
    let descriptor = dup(temporary.descriptor)
    guard descriptor >= 0 else { throw Error.publicationFailed }
    do {
      let value = try identity(of: descriptor)
      return PinnedFile(
        descriptor: descriptor, identity: value, url: stateURL,
        contentDigest: try digest(descriptor))
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  private static func encodeUpgradeState(_ state: UpgradeState) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(state)
  }

  private static func reconcilePublishedUpgrade(
    _ current: PinnedFile, at url: URL, lease: LifecycleLease, hook: TestHook?
  ) throws -> ReconciledRecovery? {
    let stateURL = upgradeStateURL(for: url)
    let stateLeaf = stateURL.lastPathComponent
    let destination = try Destination(url)
    defer { Darwin.close(destination.parentDescriptor) }
    guard entryExists(stateLeaf, in: destination.parentDescriptor) else {
      try lease.requireBound(destination)
      guard !(try hasNonemptyUpgradeArtifacts(in: destination)) else { throw Error.pathChanged }
      try lease.requireBound(destination)
      return nil
    }
    if try inactiveUpgradeState(stateLeaf, parentDescriptor: destination.parentDescriptor) {
      try lease.requireBound(destination)
      guard !(try hasNonemptyUpgradeArtifacts(in: destination)) else { throw Error.pathChanged }
      try lease.requireBound(destination)
      return nil
    }
    // An active state owns the recorded upgrade temporary; any separate migration-state temp
    // is unbound and must fail closed rather than being mistaken for state recovery.
    guard !(try hasNonemptyLifecycleTemporaries(in: destination, kinds: ["migration-state"]))
    else { throw Error.pathChanged }
    let (state, record) = try openUpgradeState(
      at: stateURL, leaf: stateLeaf, parentDescriptor: destination.parentDescriptor,
      namespace: destination.namespace, writable: true)
    defer { Darwin.close(state.descriptor) }
    try requireStateBound(state, destination: destination)
    let currentIdentity = try identity(of: current.descriptor)
    guard UInt64(currentIdentity.st_dev) == record.replacementDevice,
      UInt64(currentIdentity.st_ino) == record.replacementInode
    else { throw Error.pathChanged }
    guard try digest(current.descriptor) == record.currentDigest else { throw Error.pathChanged }
    let recoveryURL = recoveryImageURL(for: url)
    let recovery = try openValidatedLegacyRecovery(
      at: recoveryURL, leaf: recoveryURL.lastPathComponent,
      parentDescriptor: destination.parentDescriptor)
    defer { Darwin.close(recovery.descriptor) }
    guard try digest(recovery.descriptor) == record.recoveryDigest else { throw Error.pathChanged }
    let displaced = try openDisplaced(
      record, destination: destination, recovery: recovery)
    defer { Darwin.close(displaced.descriptor) }
    try requirePinnedFileStillSafe(current, parentDescriptor: destination.parentDescriptor)
    let expected = try migratedImage(from: recovery.descriptor, at: url)
    guard digest(expected) == current.contentDigest else { throw Error.pathChanged }
    try reconcilePublishedUpgradeCompanions(
      current: current, displaced: displaced, at: url, destination: destination, lease: lease)
    try requirePublishedRecoveryStillSafe(
      recovery, expectedDigest: record.recoveryDigest,
      leaf: recoveryURL.lastPathComponent, parentDescriptor: destination.parentDescriptor)
    try requireNotCancelled()
    try invoke(hook, .beforeReconciliationMutation)
    try requireNotCancelled()
    try lease.requireBound(destination)
    try requireStateBound(state, destination: destination)
    do {
      try requirePublishedRecoveryStillSafe(
        recovery, expectedDigest: record.recoveryDigest,
        leaf: recoveryURL.lastPathComponent, parentDescriptor: destination.parentDescriptor)
    } catch {
      throw Error.publicationCompleted(
        phase: .currentPublished,
        recoveryImageExists: hasValidRecoveryImage(
          leaf: recoveryURL.lastPathComponent, parentDescriptor: destination.parentDescriptor,
          expectedDigest: record.recoveryDigest, expectedIdentity: recovery.identity))
    }
    do {
      try requirePinnedFileStillSafe(
        current, parentDescriptor: destination.parentDescriptor)
      try requirePinnedFileStillSafe(
        displaced, leaf: record.replacementLeaf, parentDescriptor: destination.parentDescriptor)
      let displacedSize = try identity(of: displaced.descriptor).st_size
      guard filesEqual(displaced.descriptor, recovery.descriptor) || displacedSize == 0
      else { throw Error.pathChanged }
    } catch let error as Error where error == .pathChanged {
      throw Error.publicationCompleted(
        phase: .currentPublished,
        recoveryImageExists: hasValidRecoveryImage(
          leaf: recoveryURL.lastPathComponent, parentDescriptor: destination.parentDescriptor,
          expectedDigest: record.recoveryDigest, expectedIdentity: recovery.identity))
    }
    // Rebind every mutation authority after the final displaced-content comparison and
    // immediately before truncation.  In particular, a replaced lock pathname must not let a
    // second actor acquire a new lease while this reconciliation is still deciding.
    do {
      try requirePublishedRecoveryStillSafe(
        recovery, expectedDigest: record.recoveryDigest,
        leaf: recoveryURL.lastPathComponent, parentDescriptor: destination.parentDescriptor)
      try requirePinnedFileStillSafe(current, parentDescriptor: destination.parentDescriptor)
      try requirePinnedFileStillSafe(
        displaced, leaf: record.replacementLeaf, parentDescriptor: destination.parentDescriptor)
      let displacedSize = try identity(of: displaced.descriptor).st_size
      guard filesEqual(displaced.descriptor, recovery.descriptor) || displacedSize == 0
      else { throw Error.pathChanged }
      try requirePinnedFileBinding(current, parentDescriptor: destination.parentDescriptor)
      try requirePinnedFileBinding(
        displaced, leaf: record.replacementLeaf, parentDescriptor: destination.parentDescriptor)
      try requirePinnedFileBinding(state, parentDescriptor: destination.parentDescriptor)
      try requirePinnedFileBinding(
        recovery, leaf: recoveryURL.lastPathComponent,
        parentDescriptor: destination.parentDescriptor)
      // Lease binding is last; the ftruncate below performs no further content traversal.
      try lease.requireBound(destination)
    } catch {
      throw Error.publicationCompleted(
        phase: .currentPublished,
        recoveryImageExists: hasValidRecoveryImage(
          leaf: recoveryURL.lastPathComponent, parentDescriptor: destination.parentDescriptor,
          expectedDigest: record.recoveryDigest, expectedIdentity: recovery.identity))
    }
    guard ftruncate(displaced.descriptor, 0) == 0, fsync(displaced.descriptor) == 0 else {
      throw Error.publicationCompleted(
        phase: .currentPublished,
        recoveryImageExists: hasValidRecoveryImage(
          leaf: recoveryURL.lastPathComponent, parentDescriptor: destination.parentDescriptor,
          expectedDigest: record.recoveryDigest, expectedIdentity: recovery.identity))
    }
    try lease.requireBound(destination)
    try requireStateBound(state, destination: destination)
    do {
      try removeUpgradeState(state, destination: destination, lease: lease)
    } catch {
      throw Error.publicationCompleted(
        phase: .reconciledCurrent,
        recoveryImageExists: hasValidRecoveryImage(
          leaf: recoveryURL.lastPathComponent, parentDescriptor: destination.parentDescriptor,
          expectedDigest: record.recoveryDigest, expectedIdentity: recovery.identity))
    }
    return ReconciledRecovery(
      url: recoveryURL, identity: recovery.identity, digest: recovery.contentDigest)
  }

  private static func clearUnpublishedUpgradeState(
    _ source: PinnedFile, at url: URL, lease: LifecycleLease, hook: TestHook?
  ) throws {
    let destination = try Destination(url)
    defer { Darwin.close(destination.parentDescriptor) }
    let stateURL = upgradeStateURL(for: url)
    let stateLeaf = stateURL.lastPathComponent
    guard entryExists(stateLeaf, in: destination.parentDescriptor) else {
      try lease.requireBound(destination)
      try scavengeOrphanedTemporaries(in: destination, authenticatingAgainst: source)
      return
    }
    if try inactiveUpgradeState(stateLeaf, parentDescriptor: destination.parentDescriptor) {
      try lease.requireBound(destination)
      try scavengeOrphanedTemporaries(in: destination, authenticatingAgainst: source)
      return
    }
    let (state, record) = try openUpgradeState(
      at: stateURL, leaf: stateLeaf, parentDescriptor: destination.parentDescriptor,
      namespace: destination.namespace, writable: true)
    defer { Darwin.close(state.descriptor) }
    guard !(try hasNonemptyLifecycleTemporaries(in: destination, kinds: ["migration-state"]))
    else { throw Error.pathChanged }
    guard UInt64(source.identity.st_dev) == record.displacedDevice,
      UInt64(source.identity.st_ino) == record.displacedInode
    else {
      throw Error.pathChanged
    }
    try requireFileStillSafe(
      source.descriptor, expectedIdentity: source.identity,
      expectedDigest: source.contentDigest, leaf: destination.leaf,
      parentDescriptor: destination.parentDescriptor)
    let recoveryURL = recoveryImageURL(for: url)
    let recovery = try openValidatedRecovery(
      source: source, url: recoveryURL, leaf: recoveryURL.lastPathComponent,
      parentDescriptor: destination.parentDescriptor)
    defer { Darwin.close(recovery.descriptor) }
    guard try digest(source.descriptor) == record.recoveryDigest,
      try digest(recovery.descriptor) == record.recoveryDigest
    else { throw Error.pathChanged }
    let replacement = try openPinnedLeaf(
      record.replacementLeaf, parentDescriptor: destination.parentDescriptor, writable: true)
    defer { Darwin.close(replacement.descriptor) }
    let replacementIdentity = try identity(of: replacement.descriptor)
    guard UInt64(replacementIdentity.st_dev) == record.replacementDevice,
      UInt64(replacementIdentity.st_ino) == record.replacementInode
    else {
      throw Error.pathChanged
    }
    if replacementIdentity.st_size == 0 {
      try lease.requireBound(destination)
      try requireFileStillSafe(
        source.descriptor, expectedIdentity: source.identity,
        expectedDigest: source.contentDigest, leaf: destination.leaf,
        parentDescriptor: destination.parentDescriptor)
      try requireStateBound(state, destination: destination)
      try requirePinnedFileStillSafe(
        replacement, leaf: record.replacementLeaf,
        parentDescriptor: destination.parentDescriptor)
      try requireSourceCompanionsStillSafe(source, at: url)
      try removeUpgradeState(state, destination: destination, lease: lease)
      try lease.requireBound(destination)
      try scavengeOrphanedTemporaries(in: destination, authenticatingAgainst: source)
      return
    }
    guard
      try inspect(
        replacement, trustKey: try LedgerReceiptTrust.key(for: url, create: false)) == .current,
      try digest(replacement.descriptor) == record.currentDigest
    else { throw Error.pathChanged }
    try requirePath(url, matches: source.identity)
    try requirePinnedFileStillSafe(
      recovery, leaf: recoveryURL.lastPathComponent,
      parentDescriptor: destination.parentDescriptor)
    try requirePinnedFileStillSafe(
      replacement, leaf: record.replacementLeaf,
      parentDescriptor: destination.parentDescriptor)
    let expected = try migratedImage(from: source.descriptor, at: url)
    guard digest(expected) == replacement.contentDigest else { throw Error.pathChanged }
    try requirePath(url, matches: source.identity)
    try requirePinnedFileStillSafe(
      recovery, leaf: recoveryURL.lastPathComponent,
      parentDescriptor: destination.parentDescriptor)
    try requirePinnedFileStillSafe(
      replacement, leaf: record.replacementLeaf,
      parentDescriptor: destination.parentDescriptor)
    try lease.requireBound(destination)
    try requireFileStillSafe(
      source.descriptor, expectedIdentity: source.identity,
      expectedDigest: source.contentDigest, leaf: destination.leaf,
      parentDescriptor: destination.parentDescriptor)
    try requireStateBound(state, destination: destination)
    try requireSourceCompanionsStillSafe(source, at: url)
    try requirePinnedFileStillSafe(
      recovery, leaf: recoveryURL.lastPathComponent,
      parentDescriptor: destination.parentDescriptor)
    try requirePinnedFileStillSafe(
      replacement, leaf: record.replacementLeaf,
      parentDescriptor: destination.parentDescriptor)
    try invoke(hook, .beforeUnpublishedReplacementTruncate)
    try unlinkPinnedReplacement(
      replacement, state: state, destination: destination, lease: lease)
    try lease.requireBound(destination)
    try requireFileStillSafe(
      source.descriptor, expectedIdentity: source.identity,
      expectedDigest: source.contentDigest, leaf: destination.leaf,
      parentDescriptor: destination.parentDescriptor)
    try requireStateBound(state, destination: destination)
    try requireSourceCompanionsStillSafe(source, at: url)
    try removeUpgradeState(state, destination: destination, lease: lease)
    try lease.requireBound(destination)
    try scavengeOrphanedTemporaries(in: destination, authenticatingAgainst: source)
  }

  private static func openUpgradeState(
    at url: URL, leaf: String, parentDescriptor: Int32, namespace: String, writable: Bool = false
  ) throws -> (PinnedFile, UpgradeState) {
    let state = try openPinnedLeaf(
      leaf, parentDescriptor: parentDescriptor, url: url, writable: writable)
    do {
      let raw = try read(state.descriptor)
      let record = try JSONDecoder().decode(UpgradeState.self, from: raw)
      guard valid(record, namespace: namespace), try encodeUpgradeState(record) == raw else {
        throw Error.pathChanged
      }
      return (state, record)
    } catch {
      Darwin.close(state.descriptor)
      throw Error.pathChanged
    }
  }

  private static func openValidatedLegacyRecovery(
    at url: URL, leaf: String, parentDescriptor: Int32
  ) throws -> PinnedFile {
    try requireNoCompanions(leaf: leaf, in: parentDescriptor)
    let recovery = try openPinnedLeaf(leaf, parentDescriptor: parentDescriptor, url: url)
    do {
      try validate(recovery.descriptor, as: .legacy)
      return recovery
    } catch {
      Darwin.close(recovery.descriptor)
      throw error
    }
  }

  private static func openDisplaced(
    _ record: UpgradeState, destination: Destination, recovery: PinnedFile
  ) throws -> PinnedFile {
    let displaced = try openPinnedLeaf(
      record.replacementLeaf, parentDescriptor: destination.parentDescriptor, writable: true)
    do {
      let value = try identity(of: displaced.descriptor)
      guard UInt64(value.st_dev) == record.displacedDevice,
        UInt64(value.st_ino) == record.displacedInode,
        filesEqual(displaced.descriptor, recovery.descriptor) || value.st_size == 0
      else { throw Error.pathChanged }
      return displaced
    } catch {
      Darwin.close(displaced.descriptor)
      throw error
    }
  }

  private static func removeUpgradeState(
    _ state: PinnedFile, destination: Destination, lease: LifecycleLease
  ) throws {
    try requirePinnedFileStillSafe(state, parentDescriptor: destination.parentDescriptor)
    try requirePinnedFileBinding(state, parentDescriptor: destination.parentDescriptor)
    try lease.requireBound(destination)
    guard ftruncate(state.descriptor, 0) == 0, fsync(state.descriptor) == 0,
      fsync(destination.parentDescriptor) == 0
    else { throw Error.pathChanged }
  }

  private static func unlinkPinnedReplacement(
    _ replacement: PinnedFile, state: PinnedFile, destination: Destination,
    lease: LifecycleLease
  ) throws {
    try requirePinnedFileStillSafe(replacement, parentDescriptor: destination.parentDescriptor)
    try requirePinnedFileStillSafe(state, parentDescriptor: destination.parentDescriptor)
    try requirePinnedFileBinding(replacement, parentDescriptor: destination.parentDescriptor)
    try requirePinnedFileBinding(state, parentDescriptor: destination.parentDescriptor)
    try lease.requireBound(destination)
    guard ftruncate(replacement.descriptor, 0) == 0, fsync(replacement.descriptor) == 0,
      fsync(destination.parentDescriptor) == 0
    else { throw Error.pathChanged }
  }

  private static func inactiveUpgradeState(_ leaf: String, parentDescriptor: Int32) throws -> Bool {
    let state = try openPinnedLeaf(leaf, parentDescriptor: parentDescriptor)
    defer { Darwin.close(state.descriptor) }
    return try identity(of: state.descriptor).st_size == 0
  }

  private static func valid(_ state: UpgradeState, namespace: String) -> Bool {
    state.replacementLeaf.hasPrefix(".ledger-atlas-\(namespace)-upgrade-")
      && state.replacementLeaf.hasSuffix(".tmp")
      && !state.replacementLeaf.contains("/")
      && state.currentDigest.count == 64 && state.recoveryDigest.count == 64
      && state.currentDigest.allSatisfy { $0.isHexDigit }
      && state.recoveryDigest.allSatisfy { $0.isHexDigit }
      && state.replacementDevice > 0 && state.replacementInode > 0
  }

  private static func requireStateBound(_ state: PinnedFile, destination: Destination) throws {
    try requirePinnedFileStillSafe(state, parentDescriptor: destination.parentDescriptor)
  }

  /// Revalidates only descriptor/path identity.  Callers perform the full digest/schema
  /// authentication first, then use this lightweight binding immediately before the final lease
  /// check and destructive syscall so no O(file-size) read occurs after lease acquisition.
  private static func requireFileBinding(
    _ descriptor: Int32, expectedIdentity: stat, leaf: String,
    parentDescriptor: Int32, allowRenameCtime: Bool = false
  ) throws {
    let value = try identity(of: descriptor)
    var atPath = stat()
    let identityMatches =
      allowRenameCtime
      ? sameContentIdentity(value, expectedIdentity) : sameFile(value, expectedIdentity)
    guard
      safeFile(value), identityMatches,
      fstatat(parentDescriptor, leaf, &atPath, AT_SYMLINK_NOFOLLOW) == 0,
      safeFile(atPath),
      allowRenameCtime ? sameContentIdentity(value, atPath) : sameFile(value, atPath)
    else { throw Error.pathChanged }
  }

  @discardableResult
  private static func requireFileStillSafe(
    _ descriptor: Int32, expectedIdentity: stat, expectedDigest: String?, leaf: String,
    parentDescriptor: Int32, allowRenameCtime: Bool = false
  ) throws -> stat {
    try requireFileBinding(
      descriptor, expectedIdentity: expectedIdentity, leaf: leaf,
      parentDescriptor: parentDescriptor, allowRenameCtime: allowRenameCtime)
    if let expectedDigest {
      let authenticated = try digestedState(descriptor)
      guard authenticated.digest == expectedDigest else { throw Error.pathChanged }
      return authenticated.identity
    }
    return try identity(of: descriptor)
  }

  private static func requirePinnedFileBinding(
    _ file: PinnedFile, leaf: String? = nil, parentDescriptor: Int32
  ) throws {
    try requireFileBinding(
      file.descriptor, expectedIdentity: file.identity, leaf: leaf ?? file.url.lastPathComponent,
      parentDescriptor: parentDescriptor)
  }

  private static func requirePinnedFileStillSafe(
    _ file: PinnedFile, leaf: String? = nil, parentDescriptor: Int32
  ) throws {
    try requireFileStillSafe(
      file.descriptor, expectedIdentity: file.identity, expectedDigest: file.contentDigest,
      leaf: leaf ?? file.url.lastPathComponent, parentDescriptor: parentDescriptor)
  }

  private static func openValidatedRecovery(
    source: PinnedFile, url: URL, leaf: String, parentDescriptor: Int32
  ) throws -> PinnedFile {
    try requireNoCompanions(leaf: leaf, in: parentDescriptor)
    let descriptor = Darwin.openat(parentDescriptor, leaf, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw Error.recoveryImageExists }
    do {
      let value = try identity(of: descriptor)
      var atPath = stat()
      guard
        safeFile(value),
        fstatat(parentDescriptor, leaf, &atPath, AT_SYMLINK_NOFOLLOW) == 0,
        sameFile(value, atPath), filesEqual(source.descriptor, descriptor)
      else { throw Error.recoveryImageExists }
      try validate(descriptor, as: .legacy)
      return PinnedFile(
        descriptor: descriptor, identity: value, url: url, contentDigest: try digest(descriptor))
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  private static func requireTemporaryFileStillSafe(_ temporary: TemporaryFile) throws {
    try requireFileStillSafe(
      temporary.descriptor, expectedIdentity: temporary.lastAuthoredState.identity,
      expectedDigest: temporary.lastAuthoredState.digest, leaf: temporary.leaf,
      parentDescriptor: temporary.parentDescriptor)
  }

  private static func requireTemporaryFileBinding(_ temporary: TemporaryFile) throws {
    try requireFileBinding(
      temporary.descriptor, expectedIdentity: temporary.lastAuthoredState.identity,
      leaf: temporary.leaf, parentDescriptor: temporary.parentDescriptor)
  }

  private static func requireTemporaryRecoveryStillSafe(
    _ recovery: TemporaryFile, source: PinnedFile, parentDescriptor: Int32
  ) throws {
    try requireTemporaryFileStillSafe(recovery)
    guard filesEqual(source.descriptor, recovery.descriptor) else { throw Error.pathChanged }
  }

  private static func requireRecoveryStillSafe(
    _ recovery: PinnedFile, source: PinnedFile, leaf: String, parentDescriptor: Int32
  ) throws {
    try requireNoCompanions(leaf: leaf, in: parentDescriptor)
    let retained = try identity(of: recovery.descriptor)
    var atPath = stat()
    guard
      safeFile(retained), sameFile(recovery.identity, retained),
      fstatat(parentDescriptor, leaf, &atPath, AT_SYMLINK_NOFOLLOW) == 0,
      safeFile(atPath), sameFile(retained, atPath),
      filesEqual(source.descriptor, recovery.descriptor)
    else { throw Error.pathChanged }
  }

  private static func requirePublishedRecoveryStillSafe(
    _ recovery: PinnedFile, expectedDigest: String, leaf: String, parentDescriptor: Int32
  ) throws {
    try requireNoCompanions(leaf: leaf, in: parentDescriptor)
    let retained = try identity(of: recovery.descriptor)
    var atPath = stat()
    guard
      safeFile(retained), sameFile(recovery.identity, retained),
      fstatat(parentDescriptor, leaf, &atPath, AT_SYMLINK_NOFOLLOW) == 0,
      safeFile(atPath), sameFile(retained, atPath),
      try digest(recovery.descriptor) == expectedDigest
    else { throw Error.pathChanged }
    try validate(recovery.descriptor, as: .legacy)
  }

  private static func hasValidRecoveryImage(
    leaf: String, parentDescriptor: Int32, expectedDigest: String? = nil,
    expectedIdentity: stat? = nil
  ) -> Bool {
    guard (try? requireNoCompanions(leaf: leaf, in: parentDescriptor)) != nil,
      let recovery = try? openPinnedLeaf(leaf, parentDescriptor: parentDescriptor)
    else { return false }
    defer { Darwin.close(recovery.descriptor) }
    // Publishing by rename changes ctime.  The inode, size, mtime, digest, schema, and final
    // descriptor-to-path binding below are the retained-image identity at this boundary.
    guard expectedIdentity == nil || sameContentIdentity(recovery.identity, expectedIdentity!)
    else {
      return false
    }
    guard expectedDigest == nil || recovery.contentDigest == expectedDigest,
      (try? validate(recovery.descriptor, as: .legacy)) != nil
    else { return false }
    // Validation reads the database after the initial digest.  Re-read the digest at the
    // reporting boundary so a valid recovery image cannot be replaced during validation and
    // still be reported as present.
    guard let postValidationDigest = try? digest(recovery.descriptor),
      expectedDigest == nil || postValidationDigest == expectedDigest
    else {
      return false
    }
    guard (try? requireNoCompanions(leaf: leaf, in: parentDescriptor)) != nil,
      (try? requireFileStillSafe(
        recovery.descriptor, expectedIdentity: recovery.identity,
        expectedDigest: postValidationDigest, leaf: leaf,
        parentDescriptor: parentDescriptor)) != nil
    else { return false }
    return true
  }

  private static func scavengeOrphanedTemporaries(
    in destination: Destination, authenticatingAgainst _: PinnedFile
  ) throws {
    let duplicate = dup(destination.parentDescriptor)
    guard duplicate >= 0, let directory = fdopendir(duplicate) else {
      if duplicate >= 0 { Darwin.close(duplicate) }
      throw Error.pathChanged
    }
    defer { closedir(directory) }
    while let entry = readdir(directory) {
      let leaf = withUnsafePointer(to: entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)) { String(cString: $0) }
      }
      guard
        ["recovery", "upgrade", "migration-state"].contains(where: {
          leaf.hasPrefix(destination.temporaryPrefix($0))
        }),
        leaf.hasSuffix(".tmp")
      else { continue }
      // A namespaced temporary has no authenticated owner once its lifecycle state is
      // absent/inactive.  Even a byte-identical file could belong to another operation.
      // Inspect only; nonempty bytes are never truncated or otherwise repurposed here.
      let temporary = try openPinnedLeaf(
        leaf, parentDescriptor: destination.parentDescriptor)
      defer { Darwin.close(temporary.descriptor) }
      let value = try identity(of: temporary.descriptor)
      try requireFileStillSafe(
        temporary.descriptor, expectedIdentity: temporary.identity,
        expectedDigest: temporary.contentDigest, leaf: leaf,
        parentDescriptor: destination.parentDescriptor)
      if value.st_size > 0 { throw Error.pathChanged }
    }
  }

  private static func hasNonemptyUpgradeArtifacts(in destination: Destination) throws -> Bool {
    try hasNonemptyLifecycleTemporaries(
      in: destination, kinds: ["recovery", "upgrade", "migration-state"])
  }

  private static func hasNonemptyLifecycleTemporaries(
    in destination: Destination, kinds: [String] = ["recovery", "upgrade", "migration-state"]
  ) throws -> Bool {
    let duplicate = dup(destination.parentDescriptor)
    guard duplicate >= 0, let directory = fdopendir(duplicate) else {
      if duplicate >= 0 { Darwin.close(duplicate) }
      throw Error.pathChanged
    }
    defer { closedir(directory) }
    while let entry = readdir(directory) {
      let leaf = withUnsafePointer(to: entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)) { String(cString: $0) }
      }
      guard kinds.contains(where: { leaf.hasPrefix(destination.temporaryPrefix($0)) }),
        leaf.hasSuffix(".tmp")
      else {
        continue
      }
      let temporary = try openPinnedLeaf(
        leaf, parentDescriptor: destination.parentDescriptor)
      defer { Darwin.close(temporary.descriptor) }
      let value = try identity(of: temporary.descriptor)
      try requirePinnedFileStillSafe(
        temporary, leaf: leaf, parentDescriptor: destination.parentDescriptor)
      if value.st_size > 0 { return true }
    }
    return false
  }

  /// `checkingCurrent: false` only classifies a current-schema file; the caller must then run
  /// the full check itself before trusting it.
  private static func inspect(
    _ source: PinnedFile, trustKey: Data? = nil, checkingCurrent: Bool = true
  ) throws -> Inspection {
    let database = try openReadOnlyDatabase(source.descriptor)
    defer { sqlite3_close(database) }
    let version = scalarText(database, "SELECT value FROM ledger_meta WHERE key='schema_version'")
    let fingerprint = scalarText(
      database, "SELECT value FROM ledger_meta WHERE key='schema_fingerprint'")
    if version == String(CanonicalLedgerSchema.version),
      fingerprint == CanonicalLedgerSchema.fingerprint
    {
      if checkingCurrent {
        try validateDatabase(database, as: .current, trustKey: trustKey)
      } else {
        try validateHeader(database, as: CanonicalLedgerSchema.currentRelease)
      }
      return .current
    }
    if let version, let fingerprint, let versionNumber = Int(version),
      String(versionNumber) == version,
      let release = CanonicalLedgerSchema.lifecycleLegacyRelease(
        version: versionNumber, fingerprint: fingerprint),
      CanonicalLedgerSchema.lifecycleUpgradePath(from: release) != nil
    {
      // Validate only the cheap legacy metadata before accepting the file for an in-memory
      // migration.  The migration path uses sqlite3_backup/serialize and is bounded below;
      // current-schema inspection remains uncapped.
      try requireMigrationSizeBound(source.descriptor)
      try validateDatabase(database, as: .legacy)
      return .upgradeRequired
    }
    if scalarInt(database, "PRAGMA application_id") == Int(CanonicalLedgerSchema.applicationID),
      scalarText(database, "SELECT value FROM ledger_meta WHERE key='ledger_identity'")
        == "ledger-atlas-canonical"
    {
      throw Error.unsupportedStore
    }
    throw Error.invalidStore
  }

  /// `.legacy` is any released schema in the upgrade chain, identified by the file's own
  /// version and fingerprint and checked against that release's exact objects.
  private enum Schema { case current, legacy }

  private static func validate(_ descriptor: Int32, as schema: Schema, trustKey: Data? = nil) throws
  {
    let database = try openReadOnlyDatabase(descriptor)
    defer { sqlite3_close(database) }
    try validateDatabase(database, as: schema, trustKey: trustKey)
  }

  private static func validateDatabase(
    _ database: OpaquePointer, as schema: Schema, trustKey: Data? = nil
  ) throws {
    switch schema {
    case .current:
      try validateDatabase(database, as: CanonicalLedgerSchema.currentRelease, trustKey: trustKey)
    case .legacy:
      guard let release = legacyRelease(of: database) else { throw Error.invalidStore }
      try validateDatabase(database, as: release, trustKey: trustKey)
    }
  }

  private static func legacyRelease(of database: OpaquePointer)
    -> CanonicalLedgerSchema.SchemaRelease?
  {
    guard
      let versionText = scalarText(
        database, "SELECT value FROM ledger_meta WHERE key='schema_version'"),
      let version = Int(versionText), String(version) == versionText,
      let fingerprint = scalarText(
        database, "SELECT value FROM ledger_meta WHERE key='schema_fingerprint'")
    else { return nil }
    return CanonicalLedgerSchema.lifecycleLegacyRelease(version: version, fingerprint: fingerprint)
  }

  private static func validateDatabase(
    _ database: OpaquePointer, as release: CanonicalLedgerSchema.SchemaRelease,
    trustKey: Data? = nil
  ) throws {
    try validateHeader(database, as: release)
    guard
      scalarText(database, "PRAGMA quick_check") == "ok",
      hasNoRows(database, "PRAGMA foreign_key_check"),
      CanonicalLedgerHealth.isHealthy(database, trustKey: trustKey)
    else { throw Error.invalidStore }
  }

  /// The metadata and schema checks: cheap, and independent of the file's size.
  private static func validateHeader(
    _ database: OpaquePointer, as release: CanonicalLedgerSchema.SchemaRelease
  ) throws {
    guard
      scalarInt(database, "PRAGMA application_id") == Int(CanonicalLedgerSchema.applicationID),
      scalarText(database, "SELECT value FROM ledger_meta WHERE key='schema_version'")
        == String(release.version),
      scalarText(database, "SELECT value FROM ledger_meta WHERE key='ledger_identity'")
        == "ledger-atlas-canonical",
      scalarText(database, "SELECT value FROM ledger_meta WHERE key='schema_fingerprint'")
        == release.fingerprint,
      scalarInt(database, "SELECT count(*) FROM ledger_meta") == 3,
      schemaObjects(database) == release.objects
    else { throw Error.invalidStore }
  }

  private static func currentImage() throws -> Data {
    var database: OpaquePointer?
    guard sqlite3_open(":memory:", &database) == SQLITE_OK, let database else {
      throw Error.invalidStore
    }
    defer { sqlite3_close(database) }
    guard execute(database, "PRAGMA foreign_keys=ON"),
      execute(database, "PRAGMA application_id=\(CanonicalLedgerSchema.applicationID)")
    else { throw Error.invalidStore }
    for statement in CanonicalLedgerSchema.creationStatements {
      guard execute(database, statement) else { throw Error.invalidStore }
    }
    for (key, value) in CanonicalLedgerSchema.currentRelease.metaRows.sorted(by: { $0.key < $1.key })
    {
      guard execute(database, "INSERT INTO ledger_meta(key, value) VALUES('\(key)', '\(value)')")
      else { throw Error.invalidStore }
    }
    try validateDatabase(database, as: .current)
    return try serialized(database)
  }

  private static func requireMigrationSizeBound(_ descriptor: Int32) throws {
    let value = try identity(of: descriptor)
    guard value.st_size >= 0 else { throw Error.invalidStore }
    guard UInt64(value.st_size) <= maximumMigratedImageBytes else {
      throw Error.unsupportedStore
    }
  }

  private static func migratedImage(from descriptor: Int32, at _: URL) throws -> Data {
    try requireMigrationSizeBound(descriptor)
    let source = try openReadOnlyDatabase(descriptor)
    defer { sqlite3_close(source) }
    try validateDatabase(source, as: .legacy)
    guard let release = legacyRelease(of: source),
      let path = CanonicalLedgerSchema.lifecycleUpgradePath(from: release)
    else { throw Error.unsupportedStore }
    try requireMigrationSupported(source, from: release)
    var destination: OpaquePointer?
    guard sqlite3_open(":memory:", &destination) == SQLITE_OK, let destination else {
      throw Error.invalidStore
    }
    defer { sqlite3_close(destination) }
    guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
      throw Error.invalidStore
    }
    let step = sqlite3_backup_step(backup, -1)
    let finish = sqlite3_backup_finish(backup)
    guard step == SQLITE_DONE, finish == SQLITE_OK,
      execute(destination, "PRAGMA foreign_keys=ON"), execute(destination, "BEGIN IMMEDIATE")
    else { throw Error.invalidStore }
    // All steps share one transaction, so a failure at any step leaves nothing half-upgraded.
    do {
      for upgrade in path {
        for statement in upgrade.statements {
          guard execute(destination, statement) else { throw Error.invalidStore }
        }
        guard
          execute(
            destination,
            "UPDATE ledger_meta SET value='\(upgrade.to.version)' WHERE key='schema_version'; UPDATE ledger_meta SET value='\(upgrade.to.fingerprint)' WHERE key='schema_fingerprint'"
          ),
          schemaObjects(destination) == upgrade.to.objects
        else { throw Error.invalidStore }
      }
      guard execute(destination, "COMMIT") else { throw Error.invalidStore }
    } catch {
      _ = execute(destination, "ROLLBACK")
      throw error
    }
    try validateDatabase(destination, as: .current)
    return try serialized(destination)
  }

  private static func requireLegacyMigrationSupported(_ descriptor: Int32) throws {
    let database = try openReadOnlyDatabase(descriptor)
    defer { sqlite3_close(database) }
    guard let release = legacyRelease(of: database) else { throw Error.invalidStore }
    try requireMigrationSupported(database, from: release)
  }

  /// A release without receipt trust anchors has no external authenticator for the semantic
  /// fields later schemas protect.  Refuse to bless an admitted vendor graph after it has crossed
  /// that mutable boundary; callers must re-import from the immutable, authenticated source.
  private static func requireMigrationSupported(
    _ database: OpaquePointer, from release: CanonicalLedgerSchema.SchemaRelease
  ) throws {
    guard
      release.authenticatesImportedEvents
        || scalarText(
          database,
          "SELECT 1 FROM import_receipt WHERE profile_id IN (\(admittedProfileSQL())) LIMIT 1"
        ) == nil
    else { throw Error.unsupportedStore }
  }

  private static func admittedProfileSQL() -> String {
    MoneyManagerV19Semantics.admittedProfileIDs.sorted()
      .map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
      .joined(separator: ",")
  }

  private static func serialized(_ database: OpaquePointer) throws -> Data {
    var count: sqlite3_int64 = 0
    guard let bytes = sqlite3_serialize(database, "main", &count, 0), count > 0,
      count <= sqlite3_int64(Int.max)
    else { throw Error.invalidStore }
    defer { sqlite3_free(bytes) }
    return Data(bytes: bytes, count: Int(count))
  }

  private struct PinnedFile {
    let descriptor: Int32
    let identity: stat
    let url: URL
    let contentDigest: String
    let inactiveCompanions: InactiveCompanions?

    init(
      descriptor: Int32, identity: stat, url: URL, contentDigest: String,
      inactiveCompanions: InactiveCompanions? = nil
    ) {
      self.descriptor = descriptor
      self.identity = identity
      self.url = url
      self.contentDigest = contentDigest
      self.inactiveCompanions = inactiveCompanions
    }
  }

  private struct InactiveCompanions {
    let journalIdentity: stat
    let bindingIdentity: stat
    let bindingDigest: String
  }

  private struct AuthoredState {
    let identity: stat
    let digest: String
  }

  private static func openPinned(
    at url: URL, allowingUpgradeTransitionCompanions: Bool = false
  ) throws -> PinnedFile {
    guard url.isFileURL, url.path.hasPrefix("/"), !url.lastPathComponent.isEmpty else {
      throw Error.unsafePath
    }
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw Error.unsafePath }
    do {
      let value = try identity(of: descriptor)
      guard safeFile(value) else { throw Error.unsafePath }
      try requirePath(url, matches: value)
      let companions =
        try
        (allowingUpgradeTransitionCompanions
        ? captureInactiveCompanionFiles(at: url)
        : captureInactiveCompanions(at: url, databaseDescriptor: descriptor))
      try requirePath(url, matches: value)
      // The digest must be of the bytes the file had at `value`, the identity callers check
      // against later.
      let digested = try digestedState(descriptor)
      guard sameFile(value, digested.identity) else { throw Error.pathChanged }
      return PinnedFile(
        descriptor: descriptor, identity: value, url: url, contentDigest: digested.digest,
        inactiveCompanions: companions)
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  private static func openPinnedLeaf(
    _ leaf: String, parentDescriptor: Int32, url: URL? = nil, writable: Bool = false
  ) throws -> PinnedFile {
    guard !leaf.isEmpty, !leaf.contains("/") else { throw Error.unsafePath }
    let descriptor = Darwin.openat(
      parentDescriptor, leaf,
      (writable ? O_RDWR : O_RDONLY) | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw Error.pathChanged }
    do {
      let value = try identity(of: descriptor)
      var atPath = stat()
      guard safeFile(value),
        fstatat(parentDescriptor, leaf, &atPath, AT_SYMLINK_NOFOLLOW) == 0,
        sameFile(value, atPath)
      else { throw Error.pathChanged }
      return PinnedFile(
        descriptor: descriptor, identity: value,
        url: url ?? URL(fileURLWithPath: leaf), contentDigest: try digest(descriptor))
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  private struct Destination {
    let parentDescriptor: Int32
    let leaf: String
    let namespace: String

    init(_ url: URL) throws {
      guard url.isFileURL, url.path.hasPrefix("/"), !url.lastPathComponent.isEmpty,
        url.lastPathComponent != ".", url.lastPathComponent != ".."
      else { throw Error.unsafePath }
      leaf = url.lastPathComponent
      namespace = SHA256.hash(data: Data(leaf.utf8)).map { String(format: "%02x", $0) }.joined()
      parentDescriptor = Darwin.open(
        url.deletingLastPathComponent().path,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      guard parentDescriptor >= 0 else { throw Error.unsafePath }
    }

    func temporaryPrefix(_ kind: String) -> String {
      ".ledger-atlas-\(namespace)-\(kind)-"
    }

    var lockLeaf: String { ".ledger-atlas-\(namespace).lifecycle-lock" }
  }

  /// Serializes one ledger's lifecycle without exposing its name in the persistent lock artifact.
  private final class LifecycleLease: @unchecked Sendable {
    private let key: String
    private let descriptor: Int32
    private var held = true

    init(_ destination: Destination) throws {
      var parent = stat()
      guard fstat(destination.parentDescriptor, &parent) == 0 else { throw Error.unsafePath }
      key = "\(parent.st_dev):\(parent.st_ino):\(destination.namespace)"
      guard LifecycleLocks.shared.acquire(key) else { throw Error.busy }
      do { descriptor = try openLifecycleLock(destination) } catch {
        LifecycleLocks.shared.release(key)
        throw error
      }
      guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
        Darwin.close(descriptor)
        LifecycleLocks.shared.release(key)
        throw Error.busy
      }
    }

    func release() {
      guard held else { return }
      held = false
      _ = flock(descriptor, LOCK_UN)
      Darwin.close(descriptor)
      LifecycleLocks.shared.release(key)
    }

    func requireBound(_ destination: Destination) throws {
      let value = try LedgerStoreLifecycle.identity(of: descriptor)
      var atPath = stat()
      guard
        LedgerStoreLifecycle.safeFile(value), value.st_size == 0,
        fstatat(destination.parentDescriptor, destination.lockLeaf, &atPath, AT_SYMLINK_NOFOLLOW)
          == 0,
        LedgerStoreLifecycle.sameFile(value, atPath)
      else { throw Error.pathChanged }
    }

    deinit { release() }
  }

  private static func openLifecycleLock(_ destination: Destination) throws -> Int32 {
    let descriptor = Darwin.openat(
      destination.parentDescriptor, destination.lockLeaf,
      O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(S_IRUSR | S_IWUSR))
    guard descriptor >= 0 else { throw Error.unsafePath }
    do {
      let value = try identity(of: descriptor)
      var atPath = stat()
      guard
        safeFile(value), value.st_size == 0,
        fstatat(destination.parentDescriptor, destination.lockLeaf, &atPath, AT_SYMLINK_NOFOLLOW)
          == 0,
        sameFile(value, atPath)
      else { throw Error.unsafePath }
      return descriptor
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  private final class LifecycleLocks: @unchecked Sendable {
    static let shared = LifecycleLocks()
    private let lock = NSLock()
    private var keys = Set<String>()

    func acquire(_ key: String) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      return keys.insert(key).inserted
    }

    func release(_ key: String) {
      lock.lock()
      keys.remove(key)
      lock.unlock()
    }
  }

  private final class TemporaryFile {
    let parentDescriptor: Int32
    let leaf: String
    let descriptor: Int32
    var lastAuthoredState: AuthoredState
    private var expectedContent: ExpectedTemporaryContent?
    private var authoredLength = 0

    init(parentDescriptor: Int32, prefix: String) throws {
      self.parentDescriptor = parentDescriptor
      leaf = prefix + UUID().uuidString + ".tmp"
      descriptor = Darwin.openat(
        parentDescriptor, leaf, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        mode_t(S_IRUSR | S_IWUSR))
      guard descriptor >= 0, fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
        if descriptor >= 0 { Darwin.close(descriptor) }
        throw Error.publicationFailed
      }
      do { lastAuthoredState = try authoredState(of: descriptor) } catch {
        Darwin.close(descriptor)
        throw error
      }
    }

    func beginWrite(of data: Data) {
      expectedContent = .data(data)
      authoredLength = 0
    }

    func beginCopy(from source: Int32) throws {
      expectedContent = .descriptor(source, identity: try LedgerStoreLifecycle.identity(of: source))
      authoredLength = 0
    }

    func recordAuthoredBytes(_ count: Int) {
      authoredLength += count
    }

    func recordAuthoredState() throws {
      lastAuthoredState = try LedgerStoreLifecycle.authoredState(of: descriptor)
    }

    func closeAndNeutralizeUnlessPublished(_ published: Bool) {
      if !published {
        do {
          try LedgerStoreLifecycle.requireTemporaryFileStillSafe(self)
          _ = ftruncate(descriptor, 0)
          _ = fsync(descriptor)
          try unlinkIfStillBoundAndEmpty()
        } catch {
          // A descriptor can fail after writing an authenticated prefix (for example, on
          // fsync).  Neutralize only that exact intended prefix while the original inode
          // remains bound at its lifecycle leaf; a renamed or repurposed inode is untouched.
          try? neutralizeAuthorizedPrefix()
          try? unlinkIfStillBoundAndEmpty()
        }
      }
      Darwin.close(descriptor)
    }

    func unlinkAfterPublication() throws {
      try LedgerStoreLifecycle.requireTemporaryFileStillSafe(self)
      guard unlinkat(parentDescriptor, leaf, 0) == 0, fsync(parentDescriptor) == 0 else {
        throw Error.pathChanged
      }
    }

    private func unlinkIfStillBoundAndEmpty() throws {
      let value = try LedgerStoreLifecycle.identity(of: descriptor)
      guard value.st_size == 0 else { throw Error.pathChanged }
      try LedgerStoreLifecycle.requireFileBinding(
        descriptor, expectedIdentity: value, leaf: leaf, parentDescriptor: parentDescriptor)
      guard unlinkat(parentDescriptor, leaf, 0) == 0, fsync(parentDescriptor) == 0 else {
        throw Error.pathChanged
      }
    }

    private func neutralizeAuthorizedPrefix() throws {
      guard let expectedContent else { throw Error.pathChanged }
      let value = try LedgerStoreLifecycle.identity(of: descriptor)
      var atPath = stat()
      guard
        LedgerStoreLifecycle.safeFile(value),
        LedgerStoreLifecycle.sameInode(value, lastAuthoredState.identity),
        fstatat(parentDescriptor, leaf, &atPath, AT_SYMLINK_NOFOLLOW) == 0,
        LedgerStoreLifecycle.safeFile(atPath), LedgerStoreLifecycle.sameInode(value, atPath),
        value.st_size >= 0, Int(value.st_size) == authoredLength
      else { throw Error.pathChanged }
      switch expectedContent {
      case .data(let data):
        guard authoredLength <= data.count,
          try LedgerStoreLifecycle.prefixMatches(
            descriptor, expected: data, length: authoredLength)
        else { throw Error.pathChanged }
      case .descriptor(let source, let sourceIdentity):
        let currentSource = try LedgerStoreLifecycle.identity(of: source)
        guard LedgerStoreLifecycle.sameFile(currentSource, sourceIdentity),
          try LedgerStoreLifecycle.prefixMatches(
            descriptor, source: source, length: authoredLength)
        else { throw Error.pathChanged }
      }
      guard ftruncate(descriptor, 0) == 0, fsync(descriptor) == 0,
        fsync(parentDescriptor) == 0
      else { throw Error.pathChanged }
    }
  }

  private enum ExpectedTemporaryContent {
    case data(Data)
    case descriptor(Int32, identity: stat)
  }

  private static func openPublished(
    at url: URL, expected: stat, contentDigest: String? = nil
  ) throws -> LedgerStore {
    do {
      let store = try LedgerStore.openForMutation(
        at: url, expectedIdentity: expected, contentDigest: contentDigest, testing: nil)
      guard store.matchesPinnedInode(expected) else { throw Error.pathChanged }
      return store
    } catch let error as Error { throw error } catch { throw Error.invalidStore }
  }

  private static func invoke(_ hook: TestHook?, _ phase: TestPhase) throws {
    do { try hook?(phase) } catch { throw Error.interrupted }
  }

  private static func requireNoCompanions(at url: URL) throws {
    for suffix in ["-journal", "-journal.ledger-atlas-binding", "-wal", "-shm"] {
      var value = stat()
      errno = 0
      guard lstat(url.path + suffix, &value) != 0, errno == ENOENT else {
        throw Error.companionPresent
      }
    }
  }

  private static func requireNoCompanions(leaf: String, in parentDescriptor: Int32) throws {
    for suffix in ["-journal", "-journal.ledger-atlas-binding", "-wal", "-shm"] {
      var value = stat()
      errno = 0
      guard
        fstatat(parentDescriptor, leaf + suffix, &value, AT_SYMLINK_NOFOLLOW) != 0,
        errno == ENOENT
      else { throw Error.companionPresent }
    }
  }

  private static func captureInactiveCompanions(
    at url: URL, databaseDescriptor: Int32
  ) throws -> InactiveCompanions? {
    try requireInspectableCompanions(at: url, databaseDescriptor: databaseDescriptor)
    return try captureInactiveCompanionFiles(at: url)
  }

  private static func captureInactiveCompanionFiles(at url: URL) throws -> InactiveCompanions? {
    let destination = try Destination(url)
    defer { Darwin.close(destination.parentDescriptor) }
    let journalLeaf = destination.leaf + "-journal"
    let bindingLeaf = journalLeaf + ".ledger-atlas-binding"
    for suffix in ["-wal", "-shm"] {
      guard !entryExists(destination.leaf + suffix, in: destination.parentDescriptor) else {
        throw Error.companionPresent
      }
    }
    let journalExists = entryExists(journalLeaf, in: destination.parentDescriptor)
    let bindingExists = entryExists(bindingLeaf, in: destination.parentDescriptor)
    guard journalExists == bindingExists else { throw Error.companionPresent }
    guard journalExists else { return nil }
    let journal = try openPinnedLeaf(journalLeaf, parentDescriptor: destination.parentDescriptor)
    defer { Darwin.close(journal.descriptor) }
    let binding = try openPinnedLeaf(bindingLeaf, parentDescriptor: destination.parentDescriptor)
    defer { Darwin.close(binding.descriptor) }
    guard journal.identity.st_size == 0 else { throw Error.companionPresent }
    try requirePinnedFileStillSafe(
      journal, leaf: journalLeaf, parentDescriptor: destination.parentDescriptor)
    try requirePinnedFileStillSafe(
      binding, leaf: bindingLeaf, parentDescriptor: destination.parentDescriptor)
    return InactiveCompanions(
      journalIdentity: journal.identity, bindingIdentity: binding.identity,
      bindingDigest: binding.contentDigest)
  }

  private static func reconcilePublishedUpgradeCompanions(
    current: PinnedFile, displaced: PinnedFile, at url: URL, destination: Destination,
    lease: LifecycleLease
  ) throws {
    guard let companions = current.inactiveCompanions else {
      try requireNoCompanions(at: url)
      return
    }
    let journalLeaf = destination.leaf + "-journal"
    let bindingLeaf = journalLeaf + ".ledger-atlas-binding"
    let journal = try openPinnedLeaf(journalLeaf, parentDescriptor: destination.parentDescriptor)
    defer { Darwin.close(journal.descriptor) }
    let binding = try openPinnedLeaf(bindingLeaf, parentDescriptor: destination.parentDescriptor)
    defer { Darwin.close(binding.descriptor) }
    guard sameFile(journal.identity, companions.journalIdentity),
      sameFile(binding.identity, companions.bindingIdentity),
      binding.contentDigest == companions.bindingDigest
    else { throw Error.pathChanged }
    let bytes = try read(binding.descriptor)
    let currentPayload = Data(
      journalBindingPayload(database: current.identity, journal: journal.identity).utf8)
    if bytes == currentPayload {
      try requireInspectableCompanions(at: url, databaseDescriptor: current.descriptor)
      return
    }
    let displacedPayload = Data(
      journalBindingPayload(database: displaced.identity, journal: journal.identity).utf8)
    guard bytes == displacedPayload else { throw Error.pathChanged }
    try retargetInactiveJournal(
      companions: companions, fromDatabase: displaced, toDatabaseDescriptor: current.descriptor,
      at: url, destination: destination, lease: lease)
  }

  private static func requireSourceCompanionsStillSafe(_ source: PinnedFile, at url: URL) throws {
    let captured = try captureInactiveCompanions(at: url, databaseDescriptor: source.descriptor)
    switch (source.inactiveCompanions, captured) {
    case (nil, nil): return
    case (.some(let expected), .some(let current)):
      guard sameFile(expected.journalIdentity, current.journalIdentity),
        sameFile(expected.bindingIdentity, current.bindingIdentity),
        expected.bindingDigest == current.bindingDigest
      else { throw Error.pathChanged }
    default: throw Error.pathChanged
    }
  }

  private static func retargetInactiveJournal(
    from source: PinnedFile, to current: TemporaryFile, at url: URL, destination: Destination,
    lease: LifecycleLease
  ) throws {
    guard let companions = source.inactiveCompanions else {
      try requireNoCompanions(at: url)
      return
    }
    try retargetInactiveJournal(
      companions: companions, fromDatabase: source, toDatabaseDescriptor: current.descriptor,
      at: url, destination: destination, lease: lease)
  }

  private static func retargetInactiveJournal(
    companions: InactiveCompanions, fromDatabase: PinnedFile, toDatabaseDescriptor: Int32,
    at url: URL, destination: Destination, lease: LifecycleLease
  ) throws {
    let captured = try captureInactiveCompanions(
      at: url, databaseDescriptor: fromDatabase.descriptor)
    guard let captured, sameFile(captured.journalIdentity, companions.journalIdentity),
      sameFile(captured.bindingIdentity, companions.bindingIdentity),
      captured.bindingDigest == companions.bindingDigest
    else { throw Error.pathChanged }
    let journalLeaf = destination.leaf + "-journal"
    let bindingLeaf = journalLeaf + ".ledger-atlas-binding"
    let journal = try openPinnedLeaf(journalLeaf, parentDescriptor: destination.parentDescriptor)
    defer { Darwin.close(journal.descriptor) }
    let binding = try openPinnedLeaf(
      bindingLeaf, parentDescriptor: destination.parentDescriptor, writable: true)
    defer { Darwin.close(binding.descriptor) }
    guard sameFile(journal.identity, companions.journalIdentity),
      sameFile(binding.identity, companions.bindingIdentity),
      binding.contentDigest == companions.bindingDigest
    else { throw Error.pathChanged }

    let payload = Data(
      journalBindingPayload(
        database: try identity(of: toDatabaseDescriptor), journal: journal.identity
      ).utf8)
    let temporary = try TemporaryFile(
      parentDescriptor: destination.parentDescriptor,
      prefix: destination.temporaryPrefix("journal-binding"))
    var published = false
    defer { temporary.closeAndNeutralizeUnlessPublished(published) }
    try write(payload, to: temporary)
    try requireFileBinding(
      binding.descriptor, expectedIdentity: binding.identity, leaf: bindingLeaf,
      parentDescriptor: destination.parentDescriptor)
    try requireTemporaryFileBinding(temporary)
    try lease.requireBound(destination)
    guard
      Darwin.renameatx_np(
        destination.parentDescriptor, temporary.leaf, destination.parentDescriptor, bindingLeaf,
        UInt32(RENAME_SWAP)) == 0,
      fsync(destination.parentDescriptor) == 0
    else { throw Error.publicationFailed }
    published = true
    try requireInspectableCompanions(at: url, databaseDescriptor: toDatabaseDescriptor)

    let displacedBindingIdentity = try identity(of: binding.descriptor)
    try requireFileStillSafe(
      binding.descriptor, expectedIdentity: displacedBindingIdentity,
      expectedDigest: companions.bindingDigest, leaf: temporary.leaf,
      parentDescriptor: destination.parentDescriptor)
    try requireFileBinding(
      binding.descriptor, expectedIdentity: displacedBindingIdentity, leaf: temporary.leaf,
      parentDescriptor: destination.parentDescriptor)
    try lease.requireBound(destination)
    guard ftruncate(binding.descriptor, 0) == 0, fsync(binding.descriptor) == 0,
      fsync(destination.parentDescriptor) == 0
    else { throw Error.publicationFailed }
  }

  private static func journalBindingPayload(database: stat, journal: stat) -> String {
    """
    ledger-atlas-journal-v3
    \(UInt64(bitPattern: Int64(database.st_dev)))
    \(database.st_ino)
    \(database.st_birthtimespec.tv_sec)
    \(database.st_birthtimespec.tv_nsec)
    \(UInt64(bitPattern: Int64(journal.st_dev)))
    \(journal.st_ino)
    \(journal.st_birthtimespec.tv_sec)
    \(journal.st_birthtimespec.tv_nsec)

    """
  }

  /// A successfully mutated current store retains an authenticated, empty rollback journal.
  /// The pinned mutation VFS verifies the binding before reusing the journal for a write; this
  /// preflight only admits that inactive shape and still refuses WAL, SHM, hot journals, and
  /// orphan bindings.
  private static func requireInspectableCompanions(
    at url: URL, databaseDescriptor: Int32
  ) throws {
    do {
      try LedgerStore.validateInactiveSQLiteCompanions(
        at: url, databaseDescriptor: databaseDescriptor)
    } catch {
      throw Error.companionPresent
    }
  }

  private static func requirePath(_ url: URL, matches expected: stat) throws {
    var value = stat()
    guard lstat(url.path, &value) == 0, sameFile(value, expected), safeFile(value) else {
      throw Error.pathChanged
    }
  }

  private static func identity(of descriptor: Int32) throws -> stat {
    var value = stat()
    guard fstat(descriptor, &value) == 0 else { throw Error.unsafePath }
    return value
  }

  private static func authoredState(of descriptor: Int32) throws -> AuthoredState {
    try digestedState(descriptor)
  }

  private static func safeFile(_ value: stat) -> Bool {
    (value.st_mode & S_IFMT) == S_IFREG && value.st_uid == getuid() && value.st_nlink == 1
      && (value.st_mode & mode_t(0o777)) == mode_t(S_IRUSR | S_IWUSR)
  }

  private static func sameInode(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
  }

  private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
    sameContentIdentity(lhs, rhs)
      && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
      && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
  }

  private static func sameContentIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
    sameInode(lhs, rhs) && lhs.st_size == rhs.st_size
      && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
      && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
  }

  private static func entryExists(_ leaf: String, in parent: Int32) -> Bool {
    var value = stat()
    errno = 0
    return fstatat(parent, leaf, &value, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT
  }

  private static func requireNotCancelled() throws {
    guard !Task.isCancelled else { throw Error.interrupted }
  }

  private static func reportingPublication<T>(
    _ phase: PublicationPhase, recoveryImageExists: @autoclosure () -> Bool,
    _ operation: () throws -> T
  ) throws -> T {
    do {
      return try operation()
    } catch let error as Error {
      if case .publicationCompleted = error { throw error }
      throw Error.publicationCompleted(
        phase: phase, recoveryImageExists: recoveryImageExists())
    } catch {
      throw Error.publicationCompleted(
        phase: phase, recoveryImageExists: recoveryImageExists())
    }
  }

  private static func read(_ descriptor: Int32, maximumBytes: Int = 4_096) throws -> Data {
    let value = try identity(of: descriptor)
    guard value.st_size >= 0, value.st_size <= off_t(maximumBytes) else { throw Error.pathChanged }
    var data = Data(count: Int(value.st_size))
    let count = data.withUnsafeMutableBytes { bytes in
      Darwin.pread(descriptor, bytes.baseAddress, bytes.count, 0)
    }
    guard count == data.count, sameFile(value, try identity(of: descriptor)) else {
      throw Error.pathChanged
    }
    return data
  }

  private static func digest(_ descriptor: Int32) throws -> String {
    try digestedState(descriptor).digest
  }

  private static func digestedState(_ descriptor: Int32) throws -> AuthoredState {
    let value = try identity(of: descriptor)
    guard safeFile(value) else { throw Error.pathChanged }
    var hasher = SHA256()
    var offset: off_t = 0
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while offset < value.st_size {
      let count = pread(descriptor, &buffer, min(buffer.count, Int(value.st_size - offset)), offset)
      guard count > 0 else { throw Error.pathChanged }
      hasher.update(data: Data(buffer[0..<count]))
      offset += off_t(count)
    }
    let retained = try identity(of: descriptor)
    guard safeFile(retained), sameFile(value, retained) else { throw Error.pathChanged }
    return AuthoredState(
      identity: retained,
      digest: hasher.finalize().map { String(format: "%02x", $0) }.joined())
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func write(
    _ data: Data, to temporary: TemporaryFile, afterFsync: (() throws -> Void)? = nil
  ) throws {
    try requireTemporaryFileStillSafe(temporary)
    temporary.beginWrite(of: data)
    // beginWrite only records the intended bytes; it does not re-authenticate the descriptor.
    // Recheck the original lifecycle binding immediately before destructive truncation.
    try requireTemporaryFileStillSafe(temporary)
    guard ftruncate(temporary.descriptor, 0) == 0,
      lseek(temporary.descriptor, 0, SEEK_SET) == 0
    else {
      throw Error.publicationFailed
    }
    try data.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { throw Error.publicationFailed }
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(
          temporary.descriptor, base.advanced(by: offset), bytes.count - offset)
        guard count > 0 else { throw Error.publicationFailed }
        offset += count
        temporary.recordAuthoredBytes(count)
      }
    }
    guard fsync(temporary.descriptor) == 0, safeFile(try identity(of: temporary.descriptor)) else {
      throw Error.publicationFailed
    }
    try afterFsync?()
    try temporary.recordAuthoredState()
  }

  private static func copy(_ source: Int32, to temporary: TemporaryFile) throws {
    try requireTemporaryFileStillSafe(temporary)
    try temporary.beginCopy(from: source)
    // The copy source is authenticated as data is consumed, while this check protects the
    // destination from a last-moment rename or inode repurpose before truncation.
    try requireTemporaryFileStillSafe(temporary)
    guard ftruncate(temporary.descriptor, 0) == 0,
      lseek(temporary.descriptor, 0, SEEK_SET) == 0
    else {
      throw Error.publicationFailed
    }
    var offset: off_t = 0
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let count = pread(source, &buffer, buffer.count, offset)
      guard count >= 0 else { throw Error.publicationFailed }
      if count == 0 { break }
      var written = 0
      while written < count {
        let result = buffer.withUnsafeBytes {
          Darwin.write(
            temporary.descriptor, $0.baseAddress!.advanced(by: written), count - written)
        }
        guard result > 0 else { throw Error.publicationFailed }
        written += result
        temporary.recordAuthoredBytes(result)
      }
      offset += off_t(count)
    }
    guard fsync(temporary.descriptor) == 0,
      safeFile(try identity(of: temporary.descriptor))
    else {
      throw Error.publicationFailed
    }
    try temporary.recordAuthoredState()
  }

  private static func filesEqual(_ lhs: Int32, _ rhs: Int32) -> Bool {
    guard let left = try? identity(of: lhs), let right = try? identity(of: rhs),
      left.st_size == right.st_size
    else { return false }
    var offset: off_t = 0
    var leftBuffer = [UInt8](repeating: 0, count: 64 * 1_024)
    var rightBuffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while offset < left.st_size {
      let amount = min(leftBuffer.count, Int(left.st_size - offset))
      let leftCount = pread(lhs, &leftBuffer, amount, offset)
      let rightCount = pread(rhs, &rightBuffer, amount, offset)
      guard leftCount == amount, rightCount == amount,
        leftBuffer.prefix(amount).elementsEqual(rightBuffer.prefix(amount))
      else { return false }
      offset += off_t(amount)
    }
    return true
  }

  private static func prefixMatches(_ descriptor: Int32, expected: Data, length: Int) throws -> Bool
  {
    guard length >= 0, length <= expected.count else { return false }
    var offset = 0
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while offset < length {
      let amount = min(buffer.count, length - offset)
      let count = pread(descriptor, &buffer, amount, off_t(offset))
      guard count == amount else { return false }
      let matches = expected.withUnsafeBytes { bytes in
        buffer[..<amount].elementsEqual(bytes[offset..<offset + amount])
      }
      guard matches else { return false }
      offset += amount
    }
    return true
  }

  private static func prefixMatches(_ descriptor: Int32, source: Int32, length: Int) throws -> Bool
  {
    guard length >= 0 else { return false }
    var offset = 0
    var leftBuffer = [UInt8](repeating: 0, count: 64 * 1_024)
    var rightBuffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while offset < length {
      let amount = min(leftBuffer.count, length - offset)
      let leftCount = pread(descriptor, &leftBuffer, amount, off_t(offset))
      let rightCount = pread(source, &rightBuffer, amount, off_t(offset))
      guard leftCount == amount, rightCount == amount,
        leftBuffer[..<amount].elementsEqual(rightBuffer[..<amount])
      else { return false }
      offset += amount
    }
    return true
  }

  private static func openReadOnlyDatabase(_ descriptor: Int32) throws -> OpaquePointer {
    let duplicate = dup(descriptor)
    guard duplicate >= 0 else { throw Error.invalidStore }
    defer { Darwin.close(duplicate) }
    var database: OpaquePointer?
    let uri = "file:/dev/fd/\(duplicate)?mode=ro"
    guard
      sqlite3_open_v2(
        uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX, nil)
        == SQLITE_OK,
      let database, sqlite3_db_readonly(database, "main") == 1
    else {
      if database != nil { sqlite3_close(database) }
      throw Error.invalidStore
    }
    return database
  }

  private static func schemaObjects(_ database: OpaquePointer) -> [CanonicalSchemaObject]? {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "SELECT type, name, tbl_name, sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name",
        -1, &statement, nil) == SQLITE_OK,
      let statement
    else { return nil }
    defer { sqlite3_finalize(statement) }
    var objects: [CanonicalSchemaObject] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let type = text(statement, 0), let name = text(statement, 1),
        let table = text(statement, 2), let ddl = text(statement, 3)
      else { return nil }
      objects.append(
        CanonicalSchemaObject(
          type: type, name: name, tableName: table,
          ddl: CanonicalLedgerSchema.normalizedDDL(ddl)))
    }
    return objects.sorted { ($0.type, $0.name) < ($1.type, $1.name) }
  }

  private static func scalarInt(_ database: OpaquePointer, _ sql: String) -> Int? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement, sqlite3_step(statement) == SQLITE_ROW
    else {
      if statement != nil { sqlite3_finalize(statement) }
      return nil
    }
    defer { sqlite3_finalize(statement) }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private static func scalarText(_ database: OpaquePointer, _ sql: String) -> String? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement, sqlite3_step(statement) == SQLITE_ROW
    else {
      if statement != nil { sqlite3_finalize(statement) }
      return nil
    }
    defer { sqlite3_finalize(statement) }
    return text(statement, 0)
  }

  private static func textRows(_ database: OpaquePointer, _ sql: String) throws -> [String] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw Error.invalidStore }
    defer { sqlite3_finalize(statement) }
    var values: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let value = text(statement, 0) else { throw Error.invalidStore }
      values.append(value)
    }
    guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else {
      throw Error.invalidStore
    }
    return values
  }

  private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
    guard let value = sqlite3_column_text(statement, column) else { return nil }
    let count = sqlite3_column_bytes(statement, column)
    guard count >= 0 else { return nil }
    let data = Data(bytes: value, count: Int(count))
    guard !data.contains(0) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func hasNoRows(_ database: OpaquePointer, _ sql: String) -> Bool {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { return false }
    defer { sqlite3_finalize(statement) }
    return sqlite3_step(statement) == SQLITE_DONE
  }

  private static func execute(_ database: OpaquePointer, _ sql: String) -> Bool {
    sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
  }
}
