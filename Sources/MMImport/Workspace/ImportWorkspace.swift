import Foundation
import LedgerCore

/// One safe preparation journey for Money Manager v19 family profiles (Mac, iOS, Android)
/// and the synthetic four-table fixture. It does not expose source values, paths,
/// identifiers, hashes, or a canonical write operation.
public struct ImportWorkspace: Sendable {
  fileprivate enum DestinationState: Equatable {
    case absent
    case existing(checksum: String)
  }

  fileprivate final class PreparedState: @unchecked Sendable {
    let id = UUID()
    let request: CanonicalCommitRequest
    var destination: DestinationState

    init(request: CanonicalCommitRequest, destination: DestinationState) {
      self.request = request
      self.destination = destination
    }
  }

  public struct Request: Sendable {
    public let sourceURL: URL
    public let stagingDatabaseURL: URL
    public let canonicalDatabaseURL: URL
    public let sourceTimeZone: SourceTimeZone

    public init(
      sourceURL: URL, stagingDatabaseURL: URL, canonicalDatabaseURL: URL,
      sourceTimeZone: SourceTimeZone
    ) {
      self.sourceURL = sourceURL
      self.stagingDatabaseURL = stagingDatabaseURL
      self.canonicalDatabaseURL = canonicalDatabaseURL
      self.sourceTimeZone = sourceTimeZone
    }
  }

  public enum Status: String, Codable, Sendable { case classificationOnly, prepared, blocked }

  public struct Review: Codable, Equatable, Sendable {
    public let reportVersion: Int
    public let status: Status
    public let classificationStatus: ClassificationStatus
    public let container: SourceContainer
    public let diagnosticCodes: [String]
    public let tableCount: Int?
    public let recordCount: Int?
    public let fieldCount: Int?
    public let mappedCount: Int?
    public let preservedCount: Int?
    public let excludedCount: Int?
    public let blockingCount: Int?
    public let profileID: String?
    public let familyMatch: Bool?
    public let unresolvedSemanticCount: Int?
    public let losslessCertificationBlocked: Bool?
  }

  /// A capability that can only be created by a successful, authenticated preparation.
  public struct PreparedHandle: Sendable {
    fileprivate let state: PreparedState
  }

  /// An explicit in-memory approval bound to exactly one prepared import.
  public struct Approval: Sendable {
    fileprivate let preparedID: UUID
  }

  /// Content-free outcome for the user-facing preparation journey.
  public struct CommitResult: Equatable, Sendable {
    public let status: CanonicalCommitStatus
    public let eventCount: Int
  }

  public struct Preparation: Sendable {
    public let review: Review
    public let preparedHandle: PreparedHandle?
  }

  public init() {}

  // ponytail: process-wide serialization; use per-ledger locking only if concurrent local imports
  // become a measured product requirement.
  private static let commitLock = NSLock()

  public func prepare(_ request: Request) throws -> Preparation {
    let classification = SourceClassifier(profiles: SourceProfile.moneyManagerImportProfiles)
      .classify(request.sourceURL)
    guard classification.status.admitsImportPreparation,
      let profile = classification.profile,
      MoneyManagerV19Adapter.admits(profile)
    else {
      return .init(
        review: review(of: classification, status: .classificationOnly), preparedHandle: nil)
    }

    let staging = try ImmutableSourceStager(classifier: { _ in classification }).stage(
      .init(
        sourceURL: request.sourceURL, stagingDatabaseURL: request.stagingDatabaseURL,
        adapterVersion: MoneyManagerV19Adapter.version))
    let plan = try MoneyManagerV19Adapter.prepare(
      stagingDatabaseURL: request.stagingDatabaseURL, expectedManifest: staging.manifest,
      expectedContentDigest: staging.stagingDigest)
    let commitRequest = try MoneyManagerV19Adapter.canonicalCommitRequest(
      canonicalDatabaseURL: request.canonicalDatabaseURL,
      stagingDatabaseURL: request.stagingDatabaseURL,
      expectedManifest: staging.manifest, expectedContentDigest: staging.stagingDigest,
      sourceTimeZone: request.sourceTimeZone)
    let reconciliation = try SQLiteCanonicalCommitter().prepare(commitRequest)
    guard reconciliation.blockingCount == 0 else {
      return .init(
        review: review(
          of: classification, status: .blocked, staging: staging, reconciliation: reconciliation),
        preparedHandle: nil)
    }
    let destination = try destinationState(at: request.canonicalDatabaseURL)
    return .init(
      review: review(
        of: classification, status: .prepared, staging: staging, reconciliation: reconciliation,
        unresolvedSemanticCount: plan.preservedReasons.values.filter {
          MoneyManagerV19Vocabulary.blocksLosslessCertification($0)
        }.count,
        losslessCertificationBlocked: plan.blocksLosslessCertification),
      preparedHandle: .init(state: PreparedState(request: commitRequest, destination: destination)))
  }

  public func approve(_ handle: PreparedHandle) -> Approval {
    .init(preparedID: handle.state.id)
  }

  /// Commits the authenticated preparation only after an explicit, matching approval.
  public func commit(_ handle: PreparedHandle, approval: Approval) throws -> CommitResult {
    guard approval.preparedID == handle.state.id else {
      throw ImportWorkspaceError.approvalMismatch
    }
    Self.commitLock.lock()
    defer { Self.commitLock.unlock() }
    let current: DestinationState
    do {
      current = try destinationState(at: handle.state.request.canonicalDatabaseURL)
    } catch {
      throw ImportWorkspaceError.destinationChanged
    }
    guard current == handle.state.destination else {
      throw ImportWorkspaceError.destinationChanged
    }
    let expectation: CanonicalDestinationExpectation
    switch handle.state.destination {
    case .absent: expectation = .absent
    case .existing(let checksum): expectation = .checksum(checksum)
    }
    let result = try SQLiteCanonicalCommitter().commit(handle.state.request, expecting: expectation)
    handle.state.destination = .existing(checksum: result.canonicalChecksum)
    return .init(status: result.status, eventCount: result.eventCount)
  }

  private func destinationState(at url: URL) throws -> DestinationState {
    guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
    return .existing(checksum: try SQLiteCanonicalCommitter().canonicalChecksum(at: url))
  }

  private func review(
    of classification: ClassificationResult, status: Status, staging: StagingResult? = nil,
    reconciliation: ReconciliationReport? = nil, unresolvedSemanticCount: Int? = nil,
    losslessCertificationBlocked: Bool? = nil
  ) -> Review {
    .init(
      reportVersion: 1, status: status, classificationStatus: classification.status,
      container: classification.container,
      diagnosticCodes: classification.diagnostics.map(\.rawValue).sorted(),
      tableCount: staging?.manifest.tableCount, recordCount: staging?.manifest.recordCount,
      fieldCount: staging?.manifest.fieldCount, mappedCount: reconciliation?.mappedCount,
      preservedCount: reconciliation?.preservedCount, excludedCount: reconciliation?.excludedCount,
      blockingCount: reconciliation?.blockingCount,
      profileID: classification.profile?.identifier,
      familyMatch: classification.diagnostics.contains(.familyProfileMatch),
      unresolvedSemanticCount: unresolvedSemanticCount,
      losslessCertificationBlocked: losslessCertificationBlocked)
  }
}

public enum ImportWorkspaceError: String, Error, Equatable, Sendable {
  case approvalMismatch = "approval_mismatch"
  case destinationChanged = "destination_changed"
}
