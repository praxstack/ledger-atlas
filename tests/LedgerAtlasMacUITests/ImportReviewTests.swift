import Foundation
import LedgerAtlasMacUI
import Testing

private let sourceHash = String(repeating: "a", count: 64)
private let schemaHash = String(repeating: "b", count: 64)
private let stagingID = String(repeating: "c", count: 64)
private let stagingDigest = String(repeating: "d", count: 64)

@Test func validatedSyntheticReportsAreReviewableAndExposeOnlyStructuralMetadata() {
  let summary = ImportReviewSummary(
    classificationJSON: syntheticClassification(),
    stagingJSON: syntheticStaging()
  )

  #expect(summary.decision == .reviewable)
  #expect(summary.rows.contains(.init(label: "Classification status", value: "Supported")))
  #expect(summary.rows.contains(.init(label: "Profile", value: "Synthetic profile v19")))
  #expect(summary.rows.contains(.init(label: "Source structure", value: "12 tables, 4 indexes")))
  #expect(summary.rows.contains(.init(label: "Classification diagnostics", value: "None")))
  #expect(summary.rows.contains(.init(label: "Staging status", value: "Staged")))
  #expect(
    summary.rows.contains(
      .init(label: "Staging structure", value: "12 tables, 80 records, 640 fields")
    )
  )
  #expect(summary.rows.contains(.init(label: "Staging reason codes", value: "None")))
  #expect(summary.rows.contains(.init(label: "Identity check", value: "Matched")))
}

@Test func supportedClassificationWithoutStagingIsNotReviewable() {
  let summary = ImportReviewSummary(classificationJSON: syntheticClassification())

  #expect(summary.decision == .classificationReady)
  #expect(summary.rows.contains(.init(label: "Staging status", value: "Not provided")))
  #expect(summary.rows.contains(.init(label: "Identity check", value: "Awaiting staging")))
}

@Test func preparedWorkspaceReviewIsReviewableWithoutExposingIdentityOrCommit() {
  let summary = ImportReviewSummary(
    workspaceReviewJSON: jsonData([
      "reportVersion": 1,
      "status": "prepared",
      "classificationStatus": "supported",
      "container": "sqlite",
      "diagnosticCodes": [],
      "tableCount": 4,
      "recordCount": 4,
      "fieldCount": 12,
      "mappedCount": 2,
      "preservedCount": 19,
      "excludedCount": 0,
      "blockingCount": 0,
    ]))

  #expect(summary.decision == .reviewable)
  #expect(
    summary.rows.contains(
      .init(label: "Classification status", value: "Supported")))
  #expect(
    summary.rows.contains(
      .init(label: "Commit", value: "Approve writes the local canonical ledger")))
}

@Test func preparedFamilyWorkspaceReviewIsNotLabeledSupported() {
  let summary = ImportReviewSummary(
    workspaceReviewJSON: jsonData([
      "reportVersion": 1,
      "status": "prepared",
      "classificationStatus": "family_match",
      "container": "sqlite",
      "diagnosticCodes": ["family_profile_match"],
      "tableCount": 5,
      "recordCount": 8,
      "fieldCount": 20,
      "mappedCount": 2,
      "preservedCount": 32,
      "excludedCount": 0,
      "blockingCount": 0,
      "profileID": "realbyte-macos-sqlite-v19-family",
      "familyMatch": true,
      "unresolvedSemanticCount": 3,
      "losslessCertificationBlocked": true,
    ]))

  #expect(summary.decision == .reviewable)
  #expect(
    summary.rows.contains(
      .init(label: "Classification status", value: "Inferred family")))
  #expect(
    !summary.rows.contains(
      .init(label: "Classification status", value: "Supported")))
  #expect(
    summary.rows.contains(
      .init(label: "Match", value: "Family match (not an exact schema cell)")))
  #expect(
    summary.rows.contains(
      .init(label: "Lossless certification", value: "Blocked — unresolved source types preserved")))
  #expect(
    summary.rows.contains(
      .init(label: "Source time zone", value: "Explicit source time zone required before import")))
}

@Test func preparedZIPWorkspaceReviewIsReviewable() {
  let summary = ImportReviewSummary(
    workspaceReviewJSON: jsonData([
      "reportVersion": 1,
      "status": "prepared",
      "classificationStatus": "family_match",
      "container": "zip",
      "diagnosticCodes": ["family_profile_match"],
      "tableCount": 5,
      "recordCount": 8,
      "fieldCount": 20,
      "mappedCount": 2,
      "preservedCount": 32,
      "excludedCount": 0,
      "blockingCount": 0,
      "familyMatch": true,
      "losslessCertificationBlocked": true,
    ]))

  #expect(summary.decision == .reviewable)
  #expect(
    summary.rows.contains(
      .init(label: "Classification status", value: "Inferred family")))
}

@Test func malformedWorkspaceReviewFailsClosedWithoutEchoingInput() {
  let marker = "Alice-999.99-550e8400-e29b-41d4-a716-446655440000"
  let summary = ImportReviewSummary(
    workspaceReviewJSON: jsonData([
      "reportVersion": 1,
      "status": "prepared",
      "classificationStatus": "supported",
      "container": "sqlite",
      "diagnosticCodes": [marker],
      "tableCount": 4,
      "recordCount": 4,
      "fieldCount": 12,
      "mappedCount": 2,
      "preservedCount": 19,
      "excludedCount": 0,
      "blockingCount": 0,
    ]))

  #expect(summary.decision == .blocked)
  assertAbsent([marker], from: summary)
}

@Test func workspaceReviewRejectsUnknownDuplicateAndInconsistentClassificationFields() {
  let unknown = ImportReviewSummary(
    workspaceReviewJSON: jsonData([
      "reportVersion": 1,
      "status": "classificationOnly",
      "classificationStatus": "supported",
      "container": "sqlite",
      "diagnosticCodes": [],
      "unexpected": "ignored-by-jsondecoder",
    ]))
  let duplicate = ImportReviewSummary(
    workspaceReviewJSON: Data(
      "{\"reportVersion\":1,\"reportVersion\":1,\"status\":\"classificationOnly\",\"classificationStatus\":\"supported\",\"container\":\"sqlite\",\"diagnosticCodes\":[]}"
        .utf8))
  let corrupt = ImportReviewSummary(
    workspaceReviewJSON: jsonData([
      "reportVersion": 1,
      "status": "classificationOnly",
      "classificationStatus": "corrupt",
      "container": "sqlite",
      "diagnosticCodes": [],
    ]))

  #expect(unknown.decision == .blocked)
  #expect(duplicate.decision == .blocked)
  #expect(corrupt.decision == .blocked)
}

@Test func workspaceReviewRejectsExtremeCountsWithoutOverflowing() {
  let summary = ImportReviewSummary(
    workspaceReviewJSON: jsonData([
      "reportVersion": 1,
      "status": "prepared",
      "classificationStatus": "supported",
      "container": "sqlite",
      "diagnosticCodes": [],
      "tableCount": Int.max,
      "recordCount": Int.max,
      "fieldCount": Int.max,
      "mappedCount": Int.max,
      "preservedCount": Int.max,
      "excludedCount": 0,
      "blockingCount": 0,
    ]))

  #expect(summary.decision == .blocked)
}

@Test func knownClassifierFailureStatesRemainContentFreeAndBlocked() {
  let cases = [
    ("unsupported", "unknown_schema_fingerprint"),
    ("corrupt", "invalid_or_corrupt_sqlite"),
    ("incomplete", "sqlite_companion_files_present"),
  ]

  for (status, diagnostic) in cases {
    let summary = ImportReviewSummary(
      classificationJSON: syntheticClassification(
        status: status,
        profile: nil,
        diagnostics: [diagnostic]
      )
    )

    #expect(summary.decision == .blocked)
    #expect(
      summary.rows.contains(
        .init(label: "Classification status", value: status.capitalized)
      )
    )
    #expect(
      summary.rows.contains(
        .init(label: "Classification diagnostics", value: diagnostic)
      )
    )
  }
}

@Test func blockedStagingReportBlocksReviewAndReportsRegisteredReasonCode() {
  let summary = ImportReviewSummary(
    classificationJSON: syntheticClassification(),
    stagingJSON: syntheticBlockedStaging()
  )

  #expect(summary.decision == .blocked)
  #expect(summary.rows.contains(.init(label: "Staging status", value: "Blocked")))
  #expect(
    summary.rows.contains(
      .init(label: "Staging reason codes", value: "record_count_limit_exceeded")
    )
  )
}

@Test func stagingIdentityMismatchBlocksWithoutDisplayingIdentifiers() {
  let mismatchedHash = String(repeating: "e", count: 64)
  let summary = ImportReviewSummary(
    classificationJSON: syntheticClassification(),
    stagingJSON: syntheticStaging(artifactSHA256: mismatchedHash)
  )

  #expect(summary.decision == .blocked)
  #expect(summary.rows.contains(.init(label: "Identity check", value: "Mismatch — review blocked")))
  assertAbsent([sourceHash, mismatchedHash], from: summary)
}

@Test func arbitraryNamesAmountsUUIDsCodesAndProfilesAreNeverEchoed() {
  let fullUUID = "550e8400-e29b-41d4-a716-446655440000"
  let summary = ImportReviewSummary(
    classificationJSON: syntheticClassification(
      profile: "Alice",
      diagnostics: ["999.99", fullUUID]
    )
  )

  #expect(summary.decision == .blocked)
  #expect(summary.rows.contains(.init(label: "Profile", value: "Unrecognized profile")))
  #expect(
    summary.rows.contains(
      .init(label: "Classification diagnostics", value: "Unrecognized code")
    )
  )
  assertAbsent(["Alice", "999.99", fullUUID], from: summary)
}

@Test func arbitraryStagingStatusAndReasonCodesAreNeverEchoed() {
  let fullUUID = "550e8400-e29b-41d4-a716-446655440000"
  let summary = ImportReviewSummary(
    classificationJSON: syntheticClassification(),
    stagingJSON: syntheticStaging(
      status: "Alice",
      reasonCodes: ["999.99", fullUUID]
    )
  )

  #expect(summary.decision == .blocked)
  #expect(
    summary.rows.contains(
      .init(label: "Staging status", value: "Unrecognized status")
    )
  )
  #expect(
    summary.rows.contains(
      .init(label: "Staging reason codes", value: "Unrecognized code")
    )
  )
  assertAbsent(["Alice", "999.99", fullUUID], from: summary)
}

@Test func nilAndEqualInvalidIdentitiesNeverMatch() {
  let missing = ImportReviewSummary(
    classificationJSON: syntheticClassification(
      sourceSHA256Before: nil,
      sourceSHA256After: nil
    ),
    stagingJSON: syntheticStaging(artifactSHA256: nil)
  )
  let invalid = ImportReviewSummary(
    classificationJSON: syntheticClassification(
      sourceSHA256Before: "same",
      sourceSHA256After: "same"
    ),
    stagingJSON: syntheticStaging(artifactSHA256: "same")
  )

  #expect(missing.decision == .blocked)
  #expect(invalid.decision == .blocked)
  #expect(!missing.rows.contains(.init(label: "Identity check", value: "Matched")))
  #expect(!invalid.rows.contains(.init(label: "Identity check", value: "Matched")))
  assertAbsent(["same"], from: invalid)
}

@Test func wrongReportVersionContainerAndUnknownStatusFailClosed() {
  let wrongVersion = ImportReviewSummary(
    classificationJSON: syntheticClassification(reportVersion: 99)
  )
  let wrongContainer = ImportReviewSummary(
    classificationJSON: syntheticClassification(container: "zip")
  )
  let unknownStatus = ImportReviewSummary(
    classificationJSON: syntheticClassification(status: "Alice-999.99")
  )

  #expect(wrongVersion.decision == .blocked)
  #expect(wrongContainer.decision == .blocked)
  #expect(unknownStatus.decision == .blocked)
  #expect(
    unknownStatus.rows.contains(
      .init(label: "Classification status", value: "Unrecognized status")
    )
  )
  assertAbsent(["Alice-999.99"], from: unknownStatus)
}

@Test func inconsistentStatusDiagnosticsFailClosed() {
  let supportedWithDiagnostic = ImportReviewSummary(
    classificationJSON: syntheticClassification(diagnostics: ["unknown_schema_fingerprint"])
  )
  let unsupportedWithoutDiagnostic = ImportReviewSummary(
    classificationJSON: syntheticClassification(
      status: "unsupported",
      profile: nil,
      diagnostics: []
    )
  )
  let wrongDiagnosticFamily = ImportReviewSummary(
    classificationJSON: syntheticClassification(
      status: "corrupt",
      profile: nil,
      diagnostics: ["unknown_schema_fingerprint"]
    )
  )

  #expect(supportedWithDiagnostic.decision == .blocked)
  #expect(unsupportedWithoutDiagnostic.decision == .blocked)
  #expect(wrongDiagnosticFamily.decision == .blocked)
}

@Test func negativeHugeAndInconsistentCountsFailClosed() {
  let negative = ImportReviewSummary(
    classificationJSON: syntheticClassification(tableCount: -1)
  )
  let huge = ImportReviewSummary(
    classificationJSON: syntheticClassification(tableCount: 100_001)
  )
  let inconsistent = ImportReviewSummary(
    classificationJSON: syntheticClassification(),
    stagingJSON: syntheticStaging(tableCount: 11, recordCount: 80, fieldCount: 40)
  )

  #expect(negative.decision == .blocked)
  #expect(huge.decision == .blocked)
  #expect(inconsistent.decision == .blocked)
  assertAbsent(["-1", "100001"], from: negative)
}

@Test func oversizedJSONIsRejectedBeforeDecodeWithoutEchoingPayload() {
  let marker = "Alice-999.99-550e8400-e29b-41d4-a716-446655440000"
  let oversized = Data((marker + String(repeating: "x", count: 100_000)).utf8)
  let oversizedClassification = ImportReviewSummary(classificationJSON: oversized)
  let oversizedStaging = ImportReviewSummary(
    classificationJSON: syntheticClassification(),
    stagingJSON: oversized
  )

  #expect(oversizedClassification.decision == .blocked)
  #expect(oversizedStaging.decision == .blocked)
  assertAbsent([marker], from: oversizedClassification)
  assertAbsent([marker], from: oversizedStaging)
}

@Test func excessiveJSONNestingIsRejectedBeforeConcreteDecode() {
  let marker = "Alice-999.99"
  var nested: Any = marker
  for _ in 0..<12 {
    nested = ["nested": nested]
  }
  var object = try! #require(
    JSONSerialization.jsonObject(with: syntheticClassification()) as? [String: Any]
  )
  object["unexpected"] = nested
  let summary = ImportReviewSummary(classificationJSON: jsonData(object))

  #expect(summary.decision == .blocked)
  assertAbsent([marker], from: summary)
}

@Test func oversizedArraysAndStringsProduceOnlyGenericTokens() {
  let manyCodes = Array(repeating: "unknown_schema_fingerprint", count: 65)
  let longProfile = String(repeating: "Alice", count: 100)
  let arraySummary = ImportReviewSummary(
    classificationJSON: syntheticClassification(diagnostics: manyCodes)
  )
  let stringSummary = ImportReviewSummary(
    classificationJSON: syntheticClassification(profile: longProfile)
  )

  #expect(arraySummary.decision == .blocked)
  #expect(stringSummary.decision == .blocked)
  #expect(arraySummary.visibleText.count < 1_000)
  #expect(stringSummary.visibleText.count < 1_000)
  assertAbsent([longProfile], from: stringSummary)
}

@Test func reviewAndAccessibilityTextExcludeAllOpaqueIdentifiersAndPayloads() {
  let privateStagingID = "/private/tmp/Personal Backup.mmbak"
  let privateAdapterValue = "payload: account name, note, amount 999.99"
  let privateDigest = String(repeating: "f", count: 64)
  let summary = ImportReviewSummary(
    classificationJSON: syntheticClassification(),
    stagingJSON: syntheticStaging(
      stagingID: privateStagingID,
      stagingDigest: privateDigest,
      adapterVersion: privateAdapterValue
    )
  )

  #expect(summary.decision == .blocked)
  assertAbsent(
    [
      privateStagingID,
      privateAdapterValue,
      sourceHash,
      schemaHash,
      privateDigest,
      "Personal Backup",
      "999.99",
      "/private/tmp",
    ],
    from: summary
  )
}

@Test func semanticRowsHaveBoundedExplicitAccessibilityLabels() {
  let summary = ImportReviewSummary(
    classificationJSON: syntheticClassification(),
    stagingJSON: syntheticStaging()
  )

  for row in summary.rows {
    #expect(row.accessibilityLabel == "\(row.label): \(row.value)")
    #expect(!row.accessibilityLabel.isEmpty)
    #expect(row.accessibilityLabel.utf8.count <= 160)
  }
}

private func syntheticClassification(
  reportVersion: Int = 2,
  container: String = "sqlite",
  status: String = "supported",
  profile: String? = "synthetic-profile-v19",
  diagnostics: [String] = [],
  sourceSHA256Before: String? = sourceHash,
  sourceSHA256After: String? = sourceHash,
  schemaSHA256: String? = schemaHash,
  tableCount: Int? = 12,
  indexCount: Int? = 4
) -> Data {
  jsonData([
    "reportVersion": reportVersion,
    "container": container,
    "status": status,
    "sourceSHA256Before": sourceSHA256Before ?? NSNull(),
    "sourceSHA256After": sourceSHA256After ?? NSNull(),
    "sourceSizeBytes": 4_096,
    "profile": profile ?? NSNull(),
    "applicationID": 0,
    "userVersion": 19,
    "pageSize": 4_096,
    "encoding": "UTF-8",
    "schemaSHA256": schemaSHA256 ?? NSNull(),
    "tableCount": tableCount ?? NSNull(),
    "indexCount": indexCount ?? NSNull(),
    "diagnosticCodes": diagnostics,
  ])
}

private func syntheticStaging(
  status: String = "staged",
  reasonCodes: [String] = [],
  stagingID: String? = stagingID,
  stagingDigest: String? = stagingDigest,
  artifactSHA256: String? = sourceHash,
  adapterVersion: String? = "synthetic-adapter-v1",
  tableCount: Int? = 12,
  recordCount: Int? = 80,
  fieldCount: Int? = 640
) -> Data {
  let profileID = "synthetic-profile-v19"
  let opaqueByteCount = 2_048
  let manifest: Any
  if let stagingID, let artifactSHA256, let adapterVersion, let tableCount,
    let recordCount, let fieldCount
  {
    manifest = [
      "formatVersion": 1,
      "stagingID": stagingID,
      "artifactSHA256": artifactSHA256,
      "profileID": profileID,
      "adapterVersion": adapterVersion,
      "tableCount": tableCount,
      "recordCount": recordCount,
      "fieldCount": fieldCount,
      "opaqueByteCount": opaqueByteCount,
    ]
  } else {
    manifest = NSNull()
  }
  return jsonData([
    "reportVersion": 2,
    "status": status,
    "manifest": manifest,
    "stagingID": stagingID ?? NSNull(),
    "stagingDigest": stagingDigest ?? NSNull(),
    "artifactSHA256": artifactSHA256 ?? NSNull(),
    "profileID": profileID,
    "adapterVersion": adapterVersion ?? NSNull(),
    "tableCount": tableCount ?? NSNull(),
    "recordCount": recordCount ?? NSNull(),
    "fieldCount": fieldCount ?? NSNull(),
    "opaqueByteCount": opaqueByteCount,
    "reasonCodes": reasonCodes,
  ])
}

private func syntheticBlockedStaging() -> Data {
  jsonData([
    "reportVersion": 2,
    "status": "blocked",
    "manifest": NSNull(),
    "stagingID": NSNull(),
    "stagingDigest": NSNull(),
    "artifactSHA256": NSNull(),
    "profileID": NSNull(),
    "adapterVersion": NSNull(),
    "tableCount": NSNull(),
    "recordCount": NSNull(),
    "fieldCount": NSNull(),
    "opaqueByteCount": NSNull(),
    "reasonCodes": ["record_count_limit_exceeded"],
  ])
}

private func jsonData(_ object: [String: Any]) -> Data {
  try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func assertAbsent(
  _ forbiddenValues: [String],
  from summary: ImportReviewSummary,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  let accessibilityText = summary.rows.map(\.accessibilityLabel).joined(separator: "\n")
  for value in forbiddenValues {
    #expect(!summary.visibleText.contains(value), sourceLocation: sourceLocation)
    #expect(!accessibilityText.contains(value), sourceLocation: sourceLocation)
  }
}
