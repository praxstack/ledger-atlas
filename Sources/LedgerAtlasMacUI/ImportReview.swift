import Foundation
import LedgerCore
internal import MMImport
import SwiftUI

public struct ImportReviewSummary: Equatable, Sendable {
  public enum Decision: Equatable, Sendable {
    case reviewable
    case classificationReady
    case blocked

    var title: String {
      switch self {
      case .reviewable:
        "Reviewable"
      case .classificationReady:
        "Classification ready"
      case .blocked:
        "Blocked"
      }
    }

    var message: String {
      switch self {
      case .reviewable:
        "The classified Money Manager source is staged and ready for approval. Approval writes a local canonical ledger; the original file stays read-only."
      case .classificationReady:
        "The source classified, but staging metadata is required before review."
      case .blocked:
        "The supplied metadata is invalid, inconsistent, unsupported, or explicitly blocked."
      }
    }

    var systemImageName: String {
      switch self {
      case .reviewable:
        "checkmark.shield"
      case .classificationReady:
        "hourglass"
      case .blocked:
        "exclamationmark.octagon"
      }
    }
  }

  public struct Row: Equatable, Sendable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
      self.label = label
      self.value = value
    }

    public var accessibilityLabel: String {
      "\(label): \(value)"
    }
  }

  public let decision: Decision
  public let rows: [Row]

  public var visibleText: String {
    ([decision.title, decision.message] + rows.map(\.accessibilityLabel))
      .joined(separator: "\n")
  }

  public init(classificationJSON: Data, stagingJSON: Data? = nil) {
    guard
      !classificationJSON.isEmpty,
      classificationJSON.count <= Limits.maximumClassificationJSONBytes,
      Self.hasAcceptableJSONNesting(classificationJSON)
    else {
      self = Self.rejectedInput
      return
    }
    if let stagingJSON,
      stagingJSON.isEmpty || stagingJSON.count > Limits.maximumStagingJSONBytes
        || !Self.hasAcceptableJSONNesting(stagingJSON)
    {
      self = Self.rejectedInput
      return
    }

    let decoder = JSONDecoder()
    guard
      let classification = try? decoder.decode(
        RedactedClassificationReport.self,
        from: classificationJSON
      )
    else {
      self = Self.rejectedInput
      return
    }
    let staging: RedactedStagingReport?
    if let stagingJSON {
      guard let decoded = try? decoder.decode(RedactedStagingReport.self, from: stagingJSON)
      else {
        self = Self.rejectedInput
        return
      }
      staging = decoded
    } else {
      staging = nil
    }

    self.init(classification: classification, staging: staging)
  }

  /// Displays the content-free result of synthetic import preparation.
  /// This is a review surface only; it cannot authorize or perform a commit.
  public init(workspaceReviewJSON: Data, sourceTimeZoneIdentifier: String? = nil) {
    guard
      !workspaceReviewJSON.isEmpty,
      workspaceReviewJSON.count <= Limits.maximumWorkspaceReviewJSONBytes,
      Self.hasAcceptableJSONNesting(workspaceReviewJSON),
      Self.hasOnlyUniqueWorkspaceReviewKeys(workspaceReviewJSON),
      let review = try? JSONDecoder().decode(
        ImportWorkspace.Review.self, from: workspaceReviewJSON),
      sourceTimeZoneIdentifier.map({ TimeZone(identifier: $0) != nil }) ?? true
    else {
      self = Self.rejectedInput
      return
    }
    self.init(workspaceReview: review, sourceTimeZoneIdentifier: sourceTimeZoneIdentifier)
  }

  init(
    classification: RedactedClassificationReport,
    staging: RedactedStagingReport? = nil
  ) {
    let classificationAssessment = ClassificationAssessment(classification)
    let stagingAssessment = staging.map(StagingAssessment.init)
    let stagingConsistent =
      stagingAssessment.map {
        $0.validSuccess
          && $0.tableCount == classificationAssessment.tableCount
      } ?? false

    let identityState: IdentityState
    if !classificationAssessment.ready {
      identityState = .unavailable
    } else if let stagingAssessment {
      if stagingAssessment.validSuccess,
        stagingAssessment.artifactSHA256 != classificationAssessment.sourceSHA256
      {
        identityState = .mismatch
      } else if stagingConsistent,
        stagingAssessment.artifactSHA256 == classificationAssessment.sourceSHA256,
        stagingAssessment.profile == classificationAssessment.profile
      {
        identityState = .matched
      } else {
        identityState = .unavailable
      }
    } else {
      identityState = .awaitingStaging
    }

    if classificationAssessment.ready, staging == nil {
      decision = .classificationReady
    } else if classificationAssessment.ready, stagingConsistent, identityState == .matched {
      decision = .reviewable
    } else {
      decision = .blocked
    }

    var reportRows = classificationAssessment.rows
    if let stagingAssessment {
      reportRows.append(contentsOf: stagingAssessment.rows)
    } else {
      reportRows.append(Row(label: "Staging status", value: "Not provided"))
      reportRows.append(Row(label: "Staging structure", value: "Not available"))
      reportRows.append(Row(label: "Staging reason codes", value: "None"))
    }
    reportRows.append(Row(label: "Identity check", value: identityState.displayValue))
    rows = reportRows
  }

  static let awaitingSyntheticMetadata = ImportReviewSummary(
    decision: .blocked,
    rows: [
      Row(label: "Classification status", value: "Not provided"),
      Row(label: "Profile", value: "Not available"),
      Row(label: "Source structure", value: "Not available"),
      Row(label: "Classification diagnostics", value: "None"),
      Row(label: "Staging status", value: "Not provided"),
      Row(label: "Staging structure", value: "Not available"),
      Row(label: "Staging reason codes", value: "None"),
      Row(label: "Identity check", value: "Awaiting metadata"),
    ]
  )

  private static let rejectedInput = ImportReviewSummary(
    decision: .blocked,
    rows: [
      Row(label: "Classification status", value: "Invalid metadata"),
      Row(label: "Profile", value: "Not available"),
      Row(label: "Source structure", value: "Invalid or unavailable"),
      Row(label: "Classification diagnostics", value: "Unrecognized code"),
      Row(label: "Staging status", value: "Invalid or unavailable"),
      Row(label: "Staging structure", value: "Invalid or unavailable"),
      Row(label: "Staging reason codes", value: "Unrecognized code"),
      Row(label: "Identity check", value: "Unavailable — review blocked"),
    ]
  )

  private init(decision: Decision, rows: [Row]) {
    self.decision = decision
    self.rows = rows
  }

  private init(
    workspaceReview: ImportWorkspace.Review, sourceTimeZoneIdentifier: String?
  ) {
    let diagnosticCodesValid =
      workspaceReview.diagnosticCodes.isEmpty
      || workspaceReview.diagnosticCodes == ["family_profile_match"]
    let sourceCountsValid =
      Self.validWorkspaceCount(workspaceReview.tableCount, maximum: Limits.maximumTables)
      && Self.validWorkspaceCount(workspaceReview.recordCount, maximum: Limits.maximumRecords)
      && Self.validWorkspaceCount(workspaceReview.fieldCount, maximum: Limits.maximumFields)
      && (workspaceReview.fieldCount ?? 0) >= (workspaceReview.recordCount ?? 0)
    let reconciliationCountsValid = [
      workspaceReview.mappedCount, workspaceReview.preservedCount, workspaceReview.excludedCount,
      workspaceReview.blockingCount,
    ].allSatisfy { Self.validWorkspaceCount($0, maximum: Limits.maximumFields) }
    let reconciliationCount = Self.checkedCountSum([
      workspaceReview.mappedCount, workspaceReview.preservedCount, workspaceReview.excludedCount,
      workspaceReview.blockingCount,
    ])
    let expectedSubjectCount = Self.checkedCountSum([
      1, workspaceReview.tableCount, workspaceReview.recordCount, workspaceReview.fieldCount,
    ])
    let admitsPreparation =
      workspaceReview.classificationStatus == .supported
      || workspaceReview.classificationStatus == .familyMatch
    let admitsContainer =
      workspaceReview.container == .sqlite || workspaceReview.container == .zip
    let familyMatch =
      workspaceReview.classificationStatus == .familyMatch
      || workspaceReview.familyMatch == true
    let prepared =
      workspaceReview.reportVersion == 1
      && workspaceReview.status == .prepared
      && admitsPreparation
      && admitsContainer
      && diagnosticCodesValid
      && sourceCountsValid
      && reconciliationCountsValid
      && reconciliationCount != nil
      && reconciliationCount == expectedSubjectCount
      && workspaceReview.blockingCount == 0
    let classificationOnly =
      workspaceReview.reportVersion == 1
      && workspaceReview.status == .classificationOnly
      && admitsPreparation
      && admitsContainer
      && diagnosticCodesValid
      && workspaceReview.tableCount == nil
      && workspaceReview.recordCount == nil
      && workspaceReview.fieldCount == nil
      && workspaceReview.mappedCount == nil
      && workspaceReview.preservedCount == nil
      && workspaceReview.excludedCount == nil
      && workspaceReview.blockingCount == nil

    if prepared {
      decision = .reviewable
      rows = [
        Row(
          label: "Classification status",
          value: familyMatch ? "Inferred family" : "Supported"),
        Row(
          label: "Source structure",
          value:
            "\(workspaceReview.tableCount!) tables, \(workspaceReview.recordCount!) records, \(workspaceReview.fieldCount!) fields"
        ),
        Row(
          label: "Reconciliation",
          value:
            "\(workspaceReview.mappedCount!) mapped, \(workspaceReview.preservedCount!) preserved, \(workspaceReview.excludedCount!) excluded, 0 blocking"
        ),
        Row(label: "Profile", value: workspaceReview.profileID ?? "Named family or exact cell"),
        Row(
          label: "Match",
          value: familyMatch ? "Family match (not an exact schema cell)" : "Exact"),
        Row(
          label: "Lossless certification",
          value: familyMatch || (workspaceReview.losslessCertificationBlocked ?? false)
            ? "Blocked — unresolved source types preserved"
            : "Not claimed"),
        Row(
          label: "Source time zone",
          value: sourceTimeZoneIdentifier ?? SourceTimeZone.explicitSourceTimeZoneDisclosure),
        Row(label: "Commit", value: "Approve writes the local canonical ledger"),
      ]
    } else if classificationOnly {
      decision = .classificationReady
      rows = [
        Row(label: "Classification status", value: "Classification only"),
        Row(label: "Source structure", value: "Not staged"),
        Row(label: "Commit", value: "Not available"),
      ]
    } else {
      self = Self.rejectedInput
    }
  }

  private static func validWorkspaceCount(_ value: Int?, maximum: Int) -> Bool {
    value.map { $0 >= 0 && $0 <= maximum } == true
  }

  private static func checkedCountSum(_ values: [Int?]) -> Int? {
    var total = 0
    for value in values {
      guard let value else { return nil }
      let (next, overflow) = total.addingReportingOverflow(value)
      guard !overflow else { return nil }
      total = next
    }
    return total
  }

  private static func hasAcceptableJSONNesting(_ data: Data) -> Bool {
    var depth = 0
    var isInsideString = false
    var isEscaped = false

    for byte in data {
      if isInsideString {
        if isEscaped {
          isEscaped = false
        } else if byte == 0x5c {
          isEscaped = true
        } else if byte == 0x22 {
          isInsideString = false
        }
      } else if byte == 0x22 {
        isInsideString = true
      } else if byte == 0x7b || byte == 0x5b {
        depth += 1
        if depth > Limits.maximumJSONNestingDepth { return false }
      } else if byte == 0x7d || byte == 0x5d {
        depth -= 1
        if depth < 0 { return false }
      }
    }
    return depth == 0 && !isInsideString && !isEscaped
  }

  /// JSONDecoder intentionally accepts unknown and duplicate keys. This bounded report is a
  /// flat wire format, so reject both before decoding rather than treating them as harmless.
  private static func hasOnlyUniqueWorkspaceReviewKeys(_ data: Data) -> Bool {
    let permitted = Set([
      "reportVersion", "status", "classificationStatus", "container", "diagnosticCodes",
      "tableCount", "recordCount", "fieldCount", "mappedCount", "preservedCount",
      "excludedCount", "blockingCount", "profileID", "familyMatch",
      "unresolvedSemanticCount", "losslessCertificationBlocked",
    ])
    var depth = 0
    var isInsideString = false
    var isEscaped = false
    var stringBytes: [UInt8] = []
    var seen: Set<String> = []
    var index = data.startIndex
    while index < data.endIndex {
      let byte = data[index]
      if isInsideString {
        if isEscaped {
          isEscaped = false
        } else if byte == 0x5C {
          isEscaped = true
        } else if byte == 0x22 {
          isInsideString = false
          var next = data.index(after: index)
          while next < data.endIndex,
            data[next] == 0x20 || data[next] == 0x09
              || data[next] == 0x0A || data[next] == 0x0D
          {
            next = data.index(after: next)
          }
          if depth == 1, next < data.endIndex, data[next] == 0x3A {
            guard let key = String(bytes: stringBytes, encoding: .utf8), permitted.contains(key),
              seen.insert(key).inserted
            else { return false }
          }
        } else {
          stringBytes.append(byte)
        }
      } else if byte == 0x22 {
        isInsideString = true
        stringBytes = []
      } else if byte == 0x7B || byte == 0x5B {
        depth += 1
      } else if byte == 0x7D || byte == 0x5D {
        depth -= 1
      }
      index = data.index(after: index)
    }
    return !seen.isEmpty
  }
}

extension ImportReviewSummary {
  fileprivate enum Limits {
    static let maximumClassificationJSONBytes = 16_384
    static let maximumStagingJSONBytes = 16_384
    static let maximumWorkspaceReviewJSONBytes = 4_096
    static let maximumJSONNestingDepth = 3
    static let maximumStringBytes = 80
    static let maximumCodes = 8
    static let maximumTables = 100_000
    static let maximumIndexes = 1_000_000
    static let maximumRecords = 2_000_000
    static let maximumFields = 10_000_000
    static let maximumOpaqueBytes = 512 * 1_024 * 1_024
    static let maximumSourceBytes: UInt64 = 1_099_511_627_776
  }

  fileprivate enum SyntheticProfile: Equatable {
    case version19

    static let identifier = "synthetic-profile-v19"
    static let adapterVersion = "synthetic-adapter-v1"
    static let schemaSHA256 = String(repeating: "b", count: 64)

    init?(_ value: String?) {
      guard value == Self.identifier else { return nil }
      self = .version19
    }

    var displayName: String { "Synthetic profile v19" }
  }

  fileprivate enum ClassificationStatusToken: String {
    case supported
    case familyMatch = "family_match"
    case unsupported
    case unavailable
    case incomplete
    case corrupt

    var displayName: String {
      switch self {
      case .familyMatch: "Inferred family"
      default: rawValue.replacingOccurrences(of: "_", with: " ").capitalized
      }
    }
  }

  fileprivate enum StagingStatusToken: String {
    case staged
    case reused
    case blocked

    var displayName: String { rawValue.capitalized }
  }

  fileprivate enum ClassificationCode: String {
    case fileNotFound = "file_not_found"
    case fileUnreadable = "file_unreadable"
    case sourceSymlink = "source_symlink"
    case sourceNotRegular = "source_not_regular_file"
    case unsupportedContainer = "unsupported_container"
    case truncatedInput = "truncated_input"
    case invalidSQLite = "invalid_or_corrupt_sqlite"
    case sourceChanged = "source_changed_during_inspection"
    case sqliteNotReadonly = "sqlite_not_readonly"
    case integrityFailed = "integrity_check_failed"
    case companionFiles = "sqlite_companion_files_present"
    case archivedCompanionFiles = "archived_sqlite_companion_files_present"
    case unknownProfile = "unknown_source_profile"
    case schemaDrift = "schema_drift"
    case unknownSchema = "unknown_schema_fingerprint"
    case malformedZIP = "malformed_zip"
    case unsupportedZIP64 = "unsupported_zip64"
    case encryptedZIP = "encrypted_zip"
    case multidiskZIP = "multidisk_zip"
    case unsafeZIPPath = "unsafe_zip_path"
    case duplicateZIPName = "duplicate_zip_name"
    case symlinkZIPEntry = "symlink_zip_entry"
    case unsupportedZIPCompression = "unsupported_zip_compression"
    case unsupportedZIPDataDescriptor = "unsupported_zip_data_descriptor"
    case zipStructureOverlap = "zip_structure_overlap"
    case zipBoundsExceeded = "zip_bounds_exceeded"
    case zipCRCFailed = "zip_crc_failed"
    case duplicateSQLiteCandidates = "duplicate_sqlite_candidates"
    case noSQLiteCandidate = "no_sqlite_candidate"
    case zipSQLiteInspectionUnavailable = "zip_sqlite_inspection_unavailable"
    case familyProfileMatch = "family_profile_match"

    var expectedStatus: ClassificationStatusToken {
      switch self {
      case .fileNotFound, .fileUnreadable:
        .unavailable
      case .sourceSymlink, .sourceNotRegular, .unsupportedContainer, .unknownProfile,
        .schemaDrift, .unknownSchema, .zipSQLiteInspectionUnavailable:
        .unsupported
      case .familyProfileMatch:
        .familyMatch
      case .sourceChanged, .companionFiles, .archivedCompanionFiles:
        .incomplete
      default:
        .corrupt
      }
    }
  }

  fileprivate enum StagingReason: String {
    case invalidLimits = "invalid_limits"
    case invalidRequest = "invalid_request"
    case unsupportedClassification = "unsupported_classification"
    case selectedZIPMemberUnavailable = "zip_selected_member_unavailable"
    case sourceChanged = "source_changed"
    case sourceReadFailed = "source_read_failed"
    case sourceSQLiteInvalid = "source_sqlite_invalid"
    case tableLimitExceeded = "table_limit_exceeded"
    case recordCountLimitExceeded = "record_count_limit_exceeded"
    case fieldLimitExceeded = "field_count_limit_exceeded"
    case metadataLimitExceeded = "metadata_byte_limit_exceeded"
    case canonicalLimitExceeded = "canonical_byte_limit_exceeded"
    case valueLimitExceeded = "value_limit_exceeded"
    case recordLimitExceeded = "record_byte_limit_exceeded"
    case totalLimitExceeded = "total_byte_limit_exceeded"
    case destinationExists = "destination_conflict"
    case stagingWriteFailed = "staging_write_failed"
  }

  fileprivate enum IdentityState: Equatable {
    case matched
    case mismatch
    case unavailable
    case awaitingStaging

    var displayValue: String {
      switch self {
      case .matched:
        "Matched"
      case .mismatch:
        "Mismatch — review blocked"
      case .unavailable:
        "Unavailable — review blocked"
      case .awaitingStaging:
        "Awaiting staging"
      }
    }
  }

  fileprivate struct ClassificationAssessment {
    let rows: [Row]
    let ready: Bool
    let sourceSHA256: String?
    let profile: SyntheticProfile?
    let tableCount: Int?

    init(_ report: RedactedClassificationReport) {
      let status = ClassificationStatusToken(rawValue: report.status)
      let profile = SyntheticProfile(report.profile)
      let codesWithinBounds =
        report.diagnosticCodes.count <= Limits.maximumCodes
        && report.diagnosticCodes.allSatisfy {
          !$0.isEmpty && $0.utf8.count <= Limits.maximumStringBytes
        }
      let codes =
        codesWithinBounds
        ? report.diagnosticCodes.compactMap(ClassificationCode.init(rawValue:))
        : []
      let codesKnown = codesWithinBounds && codes.count == report.diagnosticCodes.count
      let diagnosticsConsistent: Bool
      if status == .supported {
        diagnosticsConsistent = report.diagnosticCodes.isEmpty
      } else if let status {
        diagnosticsConsistent = codesKnown && codes.count == 1 && codes[0].expectedStatus == status
      } else {
        diagnosticsConsistent = false
      }

      let stringsBounded = [
        report.container,
        report.status,
        report.sourceSHA256Before,
        report.sourceSHA256After,
        report.profile,
        report.encoding,
        report.schemaSHA256,
      ].compactMap { $0 }.allSatisfy {
        !$0.isEmpty && $0.utf8.count <= Limits.maximumStringBytes
      }
      let tableCountValid = Self.validCount(report.tableCount, maximum: Limits.maximumTables)
      let indexCountValid = Self.validCount(report.indexCount, maximum: Limits.maximumIndexes)
      let sourceStructure =
        tableCountValid && indexCountValid
        ? "\(report.tableCount!) tables, \(report.indexCount!) indexes"
        : "Invalid or unavailable"
      let diagnosticDisplay =
        report.diagnosticCodes.isEmpty
        ? "None"
        : codesKnown && report.diagnosticCodes.count <= 1
          ? codes.map(\.rawValue).joined(separator: ", ")
          : "Unrecognized code"

      rows = [
        Row(
          label: "Classification status",
          value: status?.displayName ?? "Unrecognized status"
        ),
        Row(
          label: "Profile",
          value: report.profile == nil
            ? "Not available" : profile?.displayName ?? "Unrecognized profile"
        ),
        Row(label: "Source structure", value: sourceStructure),
        Row(label: "Classification diagnostics", value: diagnosticDisplay),
      ]

      let beforeValid = Self.isLowerHexDigest(report.sourceSHA256Before)
      let afterValid = Self.isLowerHexDigest(report.sourceSHA256After)
      let metadataValid =
        report.sourceSizeBytes.map { $0 > 0 && $0 <= Limits.maximumSourceBytes } == true
        && report.applicationID == 0
        && report.userVersion == 19
        && report.pageSize.map(Self.validPageSize) == true
        && report.encoding == "UTF-8"
        && report.schemaSHA256 == SyntheticProfile.schemaSHA256
        && tableCountValid
        && indexCountValid

      ready =
        report.reportVersion == 2
        && report.container == "sqlite"
        && status == .supported
        && profile != nil
        && stringsBounded
        && diagnosticsConsistent
        && beforeValid
        && afterValid
        && report.sourceSHA256Before == report.sourceSHA256After
        && metadataValid
      sourceSHA256 = ready ? report.sourceSHA256Before : nil
      self.profile = ready ? profile : nil
      tableCount = ready ? report.tableCount : nil
    }

    private static func validCount(_ value: Int?, maximum: Int) -> Bool {
      value.map { $0 >= 0 && $0 <= maximum } == true
    }

    private static func validPageSize(_ value: Int32) -> Bool {
      value >= 512 && value <= 65_536 && value.nonzeroBitCount == 1
    }

    fileprivate static func isLowerHexDigest(_ value: String?) -> Bool {
      guard let value, value.utf8.count == 64 else { return false }
      return value.utf8.allSatisfy {
        ($0 >= Character("0").asciiValue! && $0 <= Character("9").asciiValue!)
          || ($0 >= Character("a").asciiValue! && $0 <= Character("f").asciiValue!)
      }
    }
  }

  fileprivate struct StagingAssessment {
    let rows: [Row]
    let validSuccess: Bool
    let artifactSHA256: String?
    let profile: SyntheticProfile?
    let tableCount: Int?

    init(_ report: RedactedStagingReport) {
      let status = StagingStatusToken(rawValue: report.status)
      let reasonsWithinBounds =
        report.reasonCodes.count <= Limits.maximumCodes
        && report.reasonCodes.allSatisfy {
          !$0.isEmpty && $0.utf8.count <= Limits.maximumStringBytes
        }
      let reasons =
        reasonsWithinBounds
        ? report.reasonCodes.compactMap(StagingReason.init(rawValue:))
        : []
      let reasonsKnown = reasonsWithinBounds && reasons.count == report.reasonCodes.count
      let validBlockedShape =
        status == .blocked
        && report.reportVersion == 2
        && reasonsKnown
        && reasons.count == 1
        && report.manifest == nil
        && report.stagingID == nil
        && report.stagingDigest == nil
        && report.artifactSHA256 == nil
        && report.profileID == nil
        && report.adapterVersion == nil
        && report.tableCount == nil
        && report.recordCount == nil
        && report.fieldCount == nil
        && report.opaqueByteCount == nil
      let reasonDisplay =
        report.reasonCodes.isEmpty
        ? "None"
        : validBlockedShape
          ? reasons.map(\.rawValue).joined(separator: ", ")
          : "Unrecognized code"

      let tableCountValid = Self.validCount(report.tableCount, maximum: Limits.maximumTables)
      let recordCountValid = Self.validCount(report.recordCount, maximum: Limits.maximumRecords)
      let fieldCountValid = Self.validCount(report.fieldCount, maximum: Limits.maximumFields)
      let countsConsistent =
        tableCountValid
        && recordCountValid
        && fieldCountValid
        && report.fieldCount! >= report.recordCount!
      let structure =
        countsConsistent
        ? "\(report.tableCount!) tables, \(report.recordCount!) records, \(report.fieldCount!) fields"
        : "Invalid or unavailable"
      rows = [
        Row(label: "Staging status", value: status?.displayName ?? "Unrecognized status"),
        Row(label: "Staging structure", value: structure),
        Row(label: "Staging reason codes", value: reasonDisplay),
      ]

      let stringsBounded = [
        report.status,
        report.stagingID,
        report.stagingDigest,
        report.artifactSHA256,
        report.profileID,
        report.adapterVersion,
      ].compactMap { $0 }.allSatisfy {
        !$0.isEmpty && $0.utf8.count <= Limits.maximumStringBytes
      }
      let manifestStringsBounded =
        report.manifest.map {
          [$0.stagingID, $0.artifactSHA256, $0.profileID, $0.adapterVersion]
            .allSatisfy {
              !$0.isEmpty && $0.utf8.count <= Limits.maximumStringBytes
            }
        } ?? true
      let manifestCountsBounded =
        report.manifest.map {
          $0.tableCount >= 0 && $0.tableCount <= Limits.maximumTables
            && $0.recordCount >= 0 && $0.recordCount <= Limits.maximumRecords
            && $0.fieldCount >= 0 && $0.fieldCount <= Limits.maximumFields
            && $0.opaqueByteCount >= 0
            && $0.opaqueByteCount <= Limits.maximumOpaqueBytes
        } ?? true
      let opaqueCountValid =
        report.opaqueByteCount.map { $0 >= 0 && $0 <= Limits.maximumOpaqueBytes } == true
      let identifiersValid =
        ClassificationAssessment.isLowerHexDigest(report.stagingID)
        && ClassificationAssessment.isLowerHexDigest(report.stagingDigest)
        && ClassificationAssessment.isLowerHexDigest(report.artifactSHA256)
      let profile = SyntheticProfile(report.profileID)
      let manifestConsistent =
        report.manifest.map {
          $0.formatVersion == 1
            && $0.stagingID == report.stagingID
            && $0.artifactSHA256 == report.artifactSHA256
            && $0.profileID == report.profileID
            && $0.adapterVersion == report.adapterVersion
            && $0.tableCount == report.tableCount
            && $0.recordCount == report.recordCount
            && $0.fieldCount == report.fieldCount
            && $0.opaqueByteCount == report.opaqueByteCount
        } == true
      let successfulStatus = status == .staged || status == .reused
      validSuccess =
        report.reportVersion == 2
        && successfulStatus
        && report.reasonCodes.isEmpty
        && reasonsKnown
        && stringsBounded
        && manifestStringsBounded
        && manifestCountsBounded
        && identifiersValid
        && profile != nil
        && report.adapterVersion == SyntheticProfile.adapterVersion
        && countsConsistent
        && opaqueCountValid
        && manifestConsistent

      artifactSHA256 = validSuccess ? report.artifactSHA256 : nil
      self.profile = validSuccess ? profile : nil
      tableCount = validSuccess ? report.tableCount : nil

    }

    private static func validCount(_ value: Int?, maximum: Int) -> Bool {
      value.map { $0 >= 0 && $0 <= maximum } == true
    }
  }
}

/// The Import Review screen: what the backup is, the decision, the redacted metadata, and the
/// actions that move the import on. Everything the person needs to approve sits on one page.
struct ImportReviewSurface: View {
  let summary: ImportReviewSummary
  let failure: String?
  @Binding var sourceTimeZoneIdentifier: String
  let timeZoneLocked: Bool
  let backgroundWork: LedgerJourney.BackgroundWork?
  let canApprove: Bool
  let chooseBackup: () -> Void
  let approve: () -> Void
  /// The open ledger's balance-match receipt (#172), shown above the review when there is one.
  var balanceReceipt: ImportBalanceReceipt?
  var saveReceipt: () -> Void = {}
  var continueTitle: String?
  var continueAfterReceipt: () -> Void = {}

  private var decisionTint: Color {
    if balanceReceipt != nil { return LedgerTheme.positive }
    return switch summary.decision {
    case .reviewable: LedgerTheme.positive
    case .classificationReady: LedgerTheme.warning
    case .blocked: LedgerTheme.negative
    }
  }

  var body: some View {
    LedgerCardColumn {
      if let balanceReceipt {
        ImportBalanceReceiptView(
          receipt: balanceReceipt, saveAsPDF: saveReceipt, continueTitle: continueTitle,
          continueAction: continueAfterReceipt)
      }
      // After an import the receipt leads; the introduction is for a backup still to approve.
      if balanceReceipt == nil { header }
      decisionCard
      metadataCard
      actionsCard
    }
    .navigationTitle("Import Review")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: LedgerTheme.Space.s) {
      Text("Check the backup before anything is written")
        .font(LedgerTheme.Typeface.screenTitle)
        .foregroundStyle(LedgerTheme.ink)
        .accessibilityAddTraits(.isHeader)
      Text(
        "This page shows what the Money Manager backup contains, without any of your entries. Approving writes a new ledger on this Mac; the backup file itself is only read."
      )
      .font(LedgerTheme.Typeface.secondary)
      .foregroundStyle(LedgerTheme.inkSecondary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }

  private var decisionCard: some View {
    HStack(alignment: .top, spacing: LedgerTheme.Space.m) {
      LedgerIconTile(
        .symbol(balanceReceipt == nil ? summary.decision.systemImageName : "checkmark.seal"),
        swatch: LedgerTheme.Swatch(color: decisionTint, soft: LedgerTheme.fieldFill), size: 36)
      VStack(alignment: .leading, spacing: LedgerTheme.Space.xs) {
        // With a receipt the import has already committed, so the preparation status ("ready
        // for approval", or "Blocked" for a ledger reopened later) no longer applies.
        Text(balanceReceipt == nil ? summary.decision.title : "Imported")
          .font(LedgerTheme.Typeface.figure)
          .foregroundStyle(LedgerTheme.ink)
        Text(
          balanceReceipt == nil
            ? summary.decision.message
            : "This ledger was written from the backup. The receipt above compares every account with Money Manager. From today, log on the Mac. Re-importing newer phone backups arrives in January."
        )
        .font(LedgerTheme.Typeface.secondary)
        .foregroundStyle(LedgerTheme.inkSecondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .ledgerCard()
    .accessibilityElement(children: .combine)
  }

  private var metadataCard: some View {
    VStack(alignment: .leading, spacing: LedgerTheme.Space.m) {
      LedgerCardHeader("What the backup contains")
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(summary.rows.enumerated()), id: \.offset) { offset, row in
          LedgerKeyValue(row.label, row.value)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.accessibilityLabel)
          if offset < summary.rows.count - 1 { LedgerRowDivider() }
        }
      }
      .padding(.horizontal, LedgerTheme.Space.m)
      .ledgerGroupBox()
    }
    .ledgerCard()
  }

  private var actionsCard: some View {
    VStack(alignment: .leading, spacing: LedgerTheme.Space.m) {
      LedgerCardHeader("Choose a backup")
      Text("Choose a Money Manager backup to classify it. The original file is never opened read-write.")
        .font(LedgerTheme.Typeface.secondary)
        .foregroundStyle(LedgerTheme.inkSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(
          "Choose a Money Manager backup to classify it. The original file is never opened read-write.")
      LedgerStatusLine(failure: failure)
      HStack(spacing: LedgerTheme.Space.m) {
        Picker("Backup source time zone", selection: $sourceTimeZoneIdentifier) {
          Text("Choose source time zone…").tag("")
          ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { identifier in
            Text(identifier).tag(identifier)
          }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityLabel("Backup source time zone")
        .accessibilityHint("Required to preserve the backup's civil date and time meaning.")
        .disabled(timeZoneLocked)
      }
      HStack(spacing: LedgerTheme.Space.s) {
        if canApprove {
          Button("Approve import", action: approve)
            .buttonStyle(LedgerPrimaryButtonStyle())
            .accessibilityLabel("Approve import")
            .disabled(backgroundWork != nil)
          Button("Choose Money Manager backup…", action: chooseBackup)
            .buttonStyle(LedgerSecondaryButtonStyle())
            .accessibilityLabel("Choose Money Manager backup")
            .disabled(sourceTimeZoneIdentifier.isEmpty || backgroundWork != nil)
        } else {
          Button("Choose Money Manager backup…", action: chooseBackup)
            .buttonStyle(LedgerPrimaryButtonStyle())
            .accessibilityLabel("Choose Money Manager backup")
            .disabled(sourceTimeZoneIdentifier.isEmpty || backgroundWork != nil)
        }
      }
      if let backgroundWork {
        ImportProgressView(work: backgroundWork)
      }
    }
    .ledgerCard()
  }
}
