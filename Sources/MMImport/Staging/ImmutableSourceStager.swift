import CSQLite
import CryptoKit
import Darwin
import Foundation
import LedgerCore

public struct ImmutableSourceStager: Sendable {
  typealias Classifier = @Sendable (URL) -> ClassificationResult
  typealias BeforePublish = @Sendable (URL) throws -> Void
  typealias AfterTemporaryAuthentication = @Sendable (URL) throws -> Void

  private let classifier: Classifier
  private let beforePublish: BeforePublish
  private let afterTemporaryAuthentication: AfterTemporaryAuthentication

  public init() {
    classifier = { SourceClassifier().classify($0) }
    beforePublish = { _ in }
    afterTemporaryAuthentication = { _ in }
  }

  init(
    classifier: @escaping Classifier,
    beforePublish: @escaping BeforePublish = { _ in },
    afterTemporaryAuthentication: @escaping AfterTemporaryAuthentication = { _ in }
  ) {
    self.classifier = classifier
    self.beforePublish = beforePublish
    self.afterTemporaryAuthentication = afterTemporaryAuthentication
  }

  public func stage(_ request: StagingRequest) throws -> StagingResult {
    let sourceURL = request.sourceURL.standardizedFileURL
    let destinationURL = request.stagingDatabaseURL.standardizedFileURL
    guard sourceURL != destinationURL, !request.adapterVersion.isEmpty,
      request.adapterVersion.utf8.count <= 1_024
    else { throw StagingError.invalidRequest }

    let classification = classifier(sourceURL)
    guard classification.status.admitsImportPreparation else {
      throw StagingError.unsupportedClassification
    }
    if classification.container == .zip {
      return try stageZIP(
        request: request, sourceURL: sourceURL, classification: classification)
    }
    guard classification.container == .sqlite else {
      throw StagingError.selectedZIPMemberUnavailable
    }
    guard let profile = classification.profile,
      let before = classification.fingerprintBefore,
      classification.fingerprintAfter == before
    else { throw StagingError.sourceChanged }
    guard !profile.identifier.isEmpty, profile.identifier.utf8.count <= 1_024,
      before.sha256.utf8.count == 64,
      before.sha256.utf8.allSatisfy({
        ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
      })
    else { throw StagingError.unsupportedClassification }
    guard sqliteCompanionsAbsent(sourceURL) else { throw StagingError.sourceChanged }
    let (sourceDescriptor, sourceIdentity) = try openBoundSource(sourceURL)
    defer { Darwin.close(sourceDescriptor) }
    guard
      try fingerprint(
        descriptor: sourceDescriptor, initial: sourceIdentity, sourceURL: sourceURL) == before
    else {
      throw StagingError.sourceChanged
    }
    let usesMoneyManagerV19Adapter = MoneyManagerV19Adapter.admits(profile)
    let effectiveAdapterVersion =
      request.adapterVersion == StagingRequest.automaticAdapterVersion
        && usesMoneyManagerV19Adapter
      ? MoneyManagerV19Adapter.version
      : request.adapterVersion
    let effectiveRequest = StagingRequest(
      sourceURL: request.sourceURL, stagingDatabaseURL: request.stagingDatabaseURL,
      adapterVersion: effectiveAdapterVersion, limits: request.limits)
    return try stageSource(
      request: effectiveRequest,
      sourceURL: sourceURL,
      sourceDescriptor: sourceDescriptor,
      sourceIdentity: sourceIdentity,
      destinationURL: destinationURL,
      profile: profile,
      before: before)
  }

  private func stageSource(
    request: StagingRequest,
    sourceURL: URL,
    sourceDescriptor: Int32,
    sourceIdentity: stat,
    destinationURL: URL,
    profile: SourceProfile,
    before: SourceFingerprint,
    contents: StagingContents? = nil
  ) throws -> StagingResult {
    let stagingID = StableStagingID.stage(
      artifactSHA256: before.sha256,
      profileID: profile.identifier,
      adapterVersion: request.adapterVersion)
    let contents = try contents ?? readSource(
      descriptor: sourceDescriptor,
      artifactSHA256: before.sha256,
      profileID: profile.identifier,
      adapterVersion: request.adapterVersion,
      stagingID: stagingID,
      limits: request.limits)
    let manifest = StagingManifest(
      stagingID: stagingID,
      artifactSHA256: before.sha256,
      profileID: profile.identifier,
      adapterVersion: request.adapterVersion,
      tableCount: contents.tables.count,
      recordCount: contents.recordCount,
      fieldCount: contents.fieldCount,
      opaqueByteCount: contents.opaqueByteCount)
    let temporaryURL = siblingTemporaryURL(for: destinationURL)
    let publicationPinURL = siblingPublicationPinURL(for: destinationURL)
    let store = SQLiteStagingStore()
    let expectedDigest: String
    do {
      expectedDigest = try store.write(
        contents,
        manifest: manifest,
        sourceSizeBytes: before.sizeBytes,
        limitsDescription: request.limits.stableDescription,
        to: temporaryURL)
    } catch {
      let original = error
      do { try removeTemporary(temporaryURL) } catch { throw StagingError.stagingWriteFailed }
      throw original
    }

    if FileManager.default.fileExists(atPath: destinationURL.path) {
      do {
        guard
          let reusePin = try? store.publicationPin(
            at: destinationURL,
            expectedManifest: manifest,
            expectedDigest: expectedDigest,
            limitsDescription: request.limits.stableDescription)
        else { throw StagingError.destinationExists }
        try beforePublish(sourceURL)
        guard sqliteCompanionsAbsent(sourceURL),
          try fingerprint(
            descriptor: sourceDescriptor, initial: sourceIdentity, sourceURL: sourceURL) == before
        else {
          throw StagingError.sourceChanged
        }
        guard reusePin.remainsAuthenticated(at: destinationURL),
          sqliteCompanionsAbsent(destinationURL)
        else {
          throw StagingError.destinationExists
        }
        try removeTemporary(temporaryURL)
        return StagingResult(
          status: .reused, manifest: reusePin.manifest, stagingDigest: expectedDigest)
      } catch {
        let original = error
        do { try removeTemporary(temporaryURL) } catch { throw StagingError.stagingWriteFailed }
        throw original
      }
    }

    var publicationPin: PublicationPin? = nil
    do {
      let pin = try store.publicationPin(
        at: temporaryURL,
        expectedManifest: manifest,
        expectedDigest: expectedDigest,
        limitsDescription: request.limits.stableDescription,
        pinURL: publicationPinURL)
      publicationPin = pin
      try beforePublish(sourceURL)
      try afterTemporaryAuthentication(temporaryURL)
      guard sqliteCompanionsAbsent(sourceURL),
        try fingerprint(
          descriptor: sourceDescriptor, initial: sourceIdentity, sourceURL: sourceURL) == before
      else {
        throw StagingError.sourceChanged
      }
      guard pin.remainsAuthenticated(at: temporaryURL) else {
        throw StagingError.stagingWriteFailed
      }
      try pin.publishNoOverwrite(to: destinationURL)
      guard pin.unlinkIfCurrentDescriptor(temporaryURL) else {
        _ = pin.unlinkIfCurrentDescriptor(destinationURL)
        throw StagingError.stagingWriteFailed
      }
    } catch {
      let original = error
      publicationPin?.discardPinnedLink()
      _ = publicationPin?.unlinkIfCurrentDescriptor(temporaryURL)
      throw original
    }
    return StagingResult(status: .staged, manifest: manifest, stagingDigest: expectedDigest)
  }

  private func stageZIP(
    request: StagingRequest, sourceURL: URL, classification: ClassificationResult
  ) throws -> StagingResult {
    guard let profile = classification.profile,
      let before = classification.fingerprintBefore,
      classification.fingerprintAfter == before
    else { throw StagingError.sourceChanged }
    guard !profile.identifier.isEmpty, profile.identifier.utf8.count <= 1_024,
      before.sha256.utf8.count == 64,
      before.sha256.utf8.allSatisfy({
        ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
      })
    else { throw StagingError.unsupportedClassification }
    guard sqliteCompanionsAbsent(sourceURL) else { throw StagingError.sourceChanged }
    let (sourceDescriptor, sourceIdentity) = try openBoundSource(sourceURL)
    defer { Darwin.close(sourceDescriptor) }
    guard
      try fingerprint(
        descriptor: sourceDescriptor, initial: sourceIdentity, sourceURL: sourceURL) == before
    else {
      throw StagingError.sourceChanged
    }
    let usesMoneyManagerV19Adapter = MoneyManagerV19Adapter.admits(profile)
    let effectiveAdapterVersion =
      request.adapterVersion == StagingRequest.automaticAdapterVersion
        && usesMoneyManagerV19Adapter
      ? MoneyManagerV19Adapter.version
      : request.adapterVersion
    let effectiveRequest = StagingRequest(
      sourceURL: request.sourceURL, stagingDatabaseURL: request.stagingDatabaseURL,
      adapterVersion: effectiveAdapterVersion, limits: request.limits)
    let archive = try readDescriptorData(sourceDescriptor, expectedSize: before.sizeBytes)
    guard
      try fingerprint(
        descriptor: sourceDescriptor, initial: sourceIdentity, sourceURL: sourceURL) == before
    else {
      throw StagingError.sourceChanged
    }
    let sqliteBytes: Data
    switch ZIP32Inspector.sqliteCandidate(in: archive, limits: .default) {
    case .success(let bytes):
      sqliteBytes = bytes
    case .failure:
      throw StagingError.selectedZIPMemberUnavailable
    }
    let database = try openDeserializedReadOnly(sqliteBytes)
    defer { sqlite3_close(database) }
    return try stageSource(
      request: effectiveRequest,
      sourceURL: sourceURL,
      sourceDescriptor: sourceDescriptor,
      sourceIdentity: sourceIdentity,
      destinationURL: request.stagingDatabaseURL.standardizedFileURL,
      profile: profile,
      before: before,
      contents: try zipContents(
        database, artifactSHA256: before.sha256, profileID: profile.identifier,
        adapterVersion: effectiveRequest.adapterVersion, limits: effectiveRequest.limits,
        stagingID: StableStagingID.stage(
          artifactSHA256: before.sha256, profileID: profile.identifier,
          adapterVersion: effectiveRequest.adapterVersion)))
  }

  private func zipContents(
    _ database: OpaquePointer, artifactSHA256: String, profileID: String, adapterVersion: String,
    limits: StagingLimits, stagingID: String
  ) throws -> StagingContents {
    try readContents(
      database, artifactSHA256: artifactSHA256, profileID: profileID,
      adapterVersion: adapterVersion, stagingID: stagingID, limits: limits)
  }

  private func openDeserializedReadOnly(_ bytes: Data) throws -> OpaquePointer {
    guard bytes.count >= 100, bytes.starts(with: Data("SQLite format 3\0".utf8)) else {
      throw StagingError.sourceSQLiteInvalid
    }
    var database: OpaquePointer?
    guard
      sqlite3_open_v2(
        ":memory:", &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_MEMORY, nil)
        == SQLITE_OK, let database
    else {
      if database != nil { sqlite3_close(database) }
      throw StagingError.sourceSQLiteInvalid
    }
    // FREEONCLOSE hands the buffer to SQLite, which frees it with sqlite3_free (also when
    // deserialize fails), so it must come from sqlite3_malloc64.
    guard let raw = sqlite3_malloc64(UInt64(bytes.count)) else {
      sqlite3_close(database)
      throw StagingError.sourceSQLiteInvalid
    }
    let copy = raw.assumingMemoryBound(to: UInt8.self)
    bytes.copyBytes(to: copy, count: bytes.count)
    let flags: UInt32 = 0x01 | 0x04
    guard sqlite3_deserialize(database, "main", copy, Int64(bytes.count), Int64(bytes.count), flags)
      == SQLITE_OK
    else {
      sqlite3_close(database)
      throw StagingError.sourceSQLiteInvalid
    }
    guard sqlite3_exec(database, "PRAGMA query_only=ON", nil, nil, nil) == SQLITE_OK,
      sqlite3_exec(database, "PRAGMA trusted_schema=OFF", nil, nil, nil) == SQLITE_OK
    else {
      sqlite3_close(database)
      throw StagingError.sourceSQLiteInvalid
    }
    return database
  }

  private func readDescriptorData(_ descriptor: Int32, expectedSize: UInt64) throws -> Data {
    guard lseek(descriptor, 0, SEEK_SET) == 0 else { throw StagingError.sourceReadFailed }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    guard let data = try? handle.readToEnd(), UInt64(data.count) == expectedSize else {
      throw StagingError.sourceReadFailed
    }
    return data
  }

  private func readSource(
    descriptor: Int32,
    artifactSHA256: String,
    profileID: String,
    adapterVersion: String,
    stagingID: String,
    limits: StagingLimits
  ) throws -> StagingContents {
    let sqliteDescriptor = Darwin.dup(descriptor)
    guard sqliteDescriptor >= 0 else { throw StagingError.sourceReadFailed }
    defer { Darwin.close(sqliteDescriptor) }
    var database: OpaquePointer?
    let uri = "file:/dev/fd/\(sqliteDescriptor)?mode=ro&immutable=1"
    guard
      sqlite3_open_v2(
        uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
      let database
    else {
      if database != nil { sqlite3_close(database) }
      throw StagingError.sourceSQLiteInvalid
    }
    defer { sqlite3_close(database) }
    guard sqlite3_db_readonly(database, "main") == 1,
      sqlite3_exec(database, "PRAGMA query_only=ON", nil, nil, nil) == SQLITE_OK,
      sqlite3_exec(database, "PRAGMA trusted_schema=OFF", nil, nil, nil) == SQLITE_OK
    else { throw StagingError.sourceSQLiteInvalid }
    return try readContents(
      database, artifactSHA256: artifactSHA256, profileID: profileID,
      adapterVersion: adapterVersion, stagingID: stagingID, limits: limits)
  }

  private func readContents(
    _ database: OpaquePointer,
    artifactSHA256: String,
    profileID: String,
    adapterVersion: String,
    stagingID: String,
    limits: StagingLimits
  ) throws -> StagingContents {
    var totalMetadataBytes = 0
    let tableNames = try readTableNames(
      database, limits: limits, totalMetadataBytes: &totalMetadataBytes)
    var tables: [StagedTable] = []
    var totalRecords = 0
    var totalFields = 0
    var totalBytes = 0
    var totalCanonicalBytes = 0
    for tableName in tableNames {
      let rawRecords = try readRecords(
        database,
        tableName: tableName,
        limits: limits,
        totalRecords: &totalRecords,
        totalFields: &totalFields,
        totalBytes: &totalBytes,
        totalMetadataBytes: &totalMetadataBytes,
        totalCanonicalBytes: &totalCanonicalBytes)
      let sortedRecords = rawRecords.sorted {
        $0.canonical.lexicographicallyPrecedes($1.canonical)
      }
      var previousCanonical: Data?
      var duplicateOrdinal = 0
      var records: [StagedRecord] = []
      for rawRecord in sortedRecords {
        if previousCanonical == rawRecord.canonical {
          duplicateOrdinal += 1
        } else {
          previousCanonical = rawRecord.canonical
          duplicateOrdinal = 0
        }
        let recordKey = StableStagingID.rowKey(
          canonicalRecord: rawRecord.canonical,
          duplicateOrdinal: duplicateOrdinal)
        let recordID = StableStagingID.record(
          stagingID: stagingID, table: tableName, recordKey: recordKey)
        let fields = try rawRecord.fields.map { rawField -> StagedField in
          let locator = SourceLocator(
            table: tableName,
            recordKey: recordKey,
            columnOrdinal: rawField.ordinal,
            columnName: rawField.name)
          let fieldID = StableStagingID.field(stagingID: stagingID, locator: locator)
          let provenance = FieldProvenance(
            artifactSHA256: artifactSHA256,
            profileID: profileID,
            adapterVersion: adapterVersion,
            locator: locator,
            deterministicID: fieldID)
          return StagedField(
            id: fieldID,
            ordinal: rawField.ordinal,
            name: rawField.name,
            sidecar: try OpaqueSidecar(
              declaredType: rawField.declaredType,
              storageClass: rawField.storageClass,
              payload: rawField.payload,
              provenance: provenance,
              maximumBytes: limits.maximumValueBytes))
        }
        records.append(
          StagedRecord(
            id: recordID,
            recordKey: recordKey,
            fields: fields,
            opaqueByteCount: rawRecord.opaqueByteCount))
      }
      tables.append(
        StagedTable(
          id: StableStagingID.table(stagingID: stagingID, table: tableName),
          name: tableName,
          records: records))
    }
    return StagingContents(
      stagingID: stagingID,
      tables: tables,
      recordCount: totalRecords,
      fieldCount: totalFields,
      opaqueByteCount: totalBytes)
  }

  private func readTableNames(
    _ database: OpaquePointer,
    limits: StagingLimits,
    totalMetadataBytes: inout Int
  ) throws -> [String] {
    let sql = """
      SELECT name, sql
      FROM sqlite_schema
      WHERE type = 'table'
      ORDER BY CAST(name AS BLOB)
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw StagingError.sourceSQLiteInvalid }
    defer { sqlite3_finalize(statement) }
    var names: [String] = []
    while true {
      let step = sqlite3_step(statement)
      if step == SQLITE_DONE { break }
      guard step == SQLITE_ROW,
        let name = strictMetadataText(statement, ordinal: 0),
        // Validate the table definition before using its name to prepare a
        // query. This makes hidden NUL-suffixed sqlite_schema edits fail closed.
        strictMetadataText(statement, ordinal: 1) != nil
      else {
        throw StagingError.sourceSQLiteInvalid
      }
      totalMetadataBytes = try boundedAdd(
        totalMetadataBytes, name.utf8.count,
        limit: limits.maximumMetadataBytes, error: .metadataLimitExceeded)
      names.append(name)
      guard names.count <= limits.maximumTables else {
        throw StagingError.tableLimitExceeded
      }
    }
    return names
  }

  private func readRecords(
    _ database: OpaquePointer,
    tableName: String,
    limits: StagingLimits,
    totalRecords: inout Int,
    totalFields: inout Int,
    totalBytes: inout Int,
    totalMetadataBytes: inout Int,
    totalCanonicalBytes: inout Int
  ) throws -> [RawRecord] {
    let columns = try readColumns(
      database, tableName: tableName, limits: limits,
      totalMetadataBytes: &totalMetadataBytes)
    let selection = columns.map { quoteIdentifier($0.name) }.joined(separator: ", ")
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database, "SELECT \(selection) FROM \(quoteIdentifier(tableName))", -1, &statement,
        nil) == SQLITE_OK,
      let statement
    else { throw StagingError.sourceSQLiteInvalid }
    defer { sqlite3_finalize(statement) }

    let columnCount = Int(sqlite3_column_count(statement))
    guard columnCount == columns.count else { throw StagingError.sourceSQLiteInvalid }
    var records: [RawRecord] = []
    while true {
      let step = sqlite3_step(statement)
      if step == SQLITE_DONE { break }
      guard step == SQLITE_ROW else { throw StagingError.sourceSQLiteInvalid }
      totalRecords += 1
      guard totalRecords <= limits.maximumRecords else {
        throw StagingError.recordCountLimitExceeded
      }
      totalFields = try boundedAdd(
        totalFields, columnCount,
        limit: limits.maximumFields, error: .fieldLimitExceeded)
      var fields: [RawField] = []
      var recordBytes = 0
      for ordinal in 0..<columnCount {
        let sqliteOrdinal = Int32(ordinal)
        let column = columns[ordinal]
        let (storageClass, payload) = try opaqueValue(
          statement, ordinal: sqliteOrdinal, maximumBytes: limits.maximumValueBytes)
        recordBytes = try boundedAdd(
          recordBytes, payload.count,
          limit: limits.maximumRecordBytes,
          error: .recordLimitExceeded)
        totalBytes = try boundedAdd(
          totalBytes, payload.count,
          limit: limits.maximumTotalBytes,
          error: .totalLimitExceeded)
        fields.append(
          RawField(
            ordinal: ordinal,
            name: column.name,
            declaredType: column.declaredType,
            storageClass: storageClass,
            payload: payload))
      }
      let canonical = try canonicalRecord(fields, maximumBytes: limits.maximumCanonicalBytes)
      totalCanonicalBytes = try boundedAdd(
        totalCanonicalBytes, canonical.count,
        limit: limits.maximumCanonicalBytes, error: .canonicalLimitExceeded)
      records.append(
        RawRecord(fields: fields, canonical: canonical, opaqueByteCount: recordBytes))
    }
    return records
  }

  private func readColumns(
    _ database: OpaquePointer,
    tableName: String,
    limits: StagingLimits,
    totalMetadataBytes: inout Int
  ) throws -> [RawColumn] {
    let literal = tableName.replacingOccurrences(of: "'", with: "''")
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database, "PRAGMA table_xinfo('\(literal)')", -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw StagingError.sourceSQLiteInvalid }
    defer { sqlite3_finalize(statement) }
    var columns: [RawColumn] = []
    while true {
      let step = sqlite3_step(statement)
      if step == SQLITE_DONE { break }
      guard step == SQLITE_ROW, let name = strictMetadataText(statement, ordinal: 1) else {
        throw StagingError.sourceSQLiteInvalid
      }
      let rawDeclaredType: String?
      if sqlite3_column_type(statement, 2) == SQLITE_NULL {
        rawDeclaredType = nil
      } else if let type = strictMetadataText(statement, ordinal: 2) {
        rawDeclaredType = type
      } else {
        throw StagingError.sourceSQLiteInvalid
      }
      let declaredType = rawDeclaredType?.isEmpty == true ? nil : rawDeclaredType
      totalMetadataBytes = try boundedAdd(
        totalMetadataBytes, name.utf8.count,
        limit: limits.maximumMetadataBytes, error: .metadataLimitExceeded)
      totalMetadataBytes = try boundedAdd(
        totalMetadataBytes, declaredType?.utf8.count ?? 0,
        limit: limits.maximumMetadataBytes, error: .metadataLimitExceeded)
      columns.append(
        RawColumn(ordinal: columns.count, name: name, declaredType: declaredType))
      guard columns.count <= limits.maximumFieldsPerRecord else {
        throw StagingError.fieldLimitExceeded
      }
    }
    guard !columns.isEmpty else { throw StagingError.sourceSQLiteInvalid }
    return columns
  }

  private func quoteIdentifier(_ identifier: String) -> String {
    "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }

  /// Source table and column metadata becomes part of staging IDs and SQL.
  /// Decode the exact SQLite byte sequence and reject invalid UTF-8/NUL rather
  /// than accepting the C-string prefix.
  private func strictMetadataText(_ statement: OpaquePointer, ordinal: Int32) -> String? {
    guard sqlite3_column_type(statement, ordinal) == SQLITE_TEXT,
      let bytes = sqlite3_column_text(statement, ordinal)
    else { return nil }
    let count = Int(sqlite3_column_bytes(statement, ordinal))
    guard count >= 0 else { return nil }
    let data = Data(bytes: bytes, count: count)
    guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return nil }
    return text
  }

  private func opaqueValue(
    _ statement: OpaquePointer,
    ordinal: Int32,
    maximumBytes: Int
  ) throws -> (SQLiteStorageClass, Data) {
    switch sqlite3_column_type(statement, ordinal) {
    case SQLITE_NULL:
      return (.null, Data())
    case SQLITE_INTEGER:
      let bits = UInt64(bitPattern: sqlite3_column_int64(statement, ordinal))
      guard MemoryLayout<UInt64>.size <= maximumBytes else {
        throw StagingError.valueLimitExceeded
      }
      return (.integer, bigEndianData(bits))
    case SQLITE_FLOAT:
      guard MemoryLayout<UInt64>.size <= maximumBytes else {
        throw StagingError.valueLimitExceeded
      }
      return (.real, bigEndianData(sqlite3_column_double(statement, ordinal).bitPattern))
    case SQLITE_BLOB:
      let byteCount = Int(sqlite3_column_bytes(statement, ordinal))
      guard byteCount <= maximumBytes else { throw StagingError.valueLimitExceeded }
      guard byteCount > 0 else { return (.blob, Data()) }
      guard let bytes = sqlite3_column_blob(statement, ordinal) else {
        throw StagingError.sourceSQLiteInvalid
      }
      return (.blob, Data(bytes: bytes, count: byteCount))
    case SQLITE_TEXT:
      guard let bytes = sqlite3_column_text(statement, ordinal) else {
        throw StagingError.sourceSQLiteInvalid
      }
      let byteCount = Int(sqlite3_column_bytes(statement, ordinal))
      guard byteCount <= maximumBytes else { throw StagingError.valueLimitExceeded }
      return (.text, Data(bytes: bytes, count: byteCount))
    default:
      throw StagingError.sourceSQLiteInvalid
    }
  }

  private func boundedAdd(
    _ left: Int,
    _ right: Int,
    limit: Int,
    error: StagingError
  ) throws -> Int {
    let (sum, overflow) = left.addingReportingOverflow(right)
    guard !overflow, sum <= limit else { throw error }
    return sum
  }

  private func canonicalRecord(_ fields: [RawField], maximumBytes: Int) throws -> Data {
    var data = Data()
    for field in fields {
      for component in [
        Data(String(field.ordinal).utf8), Data(field.name.utf8),
        Data((field.declaredType ?? "").utf8), Data(field.storageClass.rawValue.utf8),
        field.payload,
      ] {
        let framedCount = try boundedAdd(
          MemoryLayout<UInt64>.size, component.count,
          limit: maximumBytes, error: .canonicalLimitExceeded)
        _ = try boundedAdd(
          data.count, framedCount,
          limit: maximumBytes, error: .canonicalLimitExceeded)
        appendLengthPrefixed(component, to: &data)
      }
    }
    return data
  }

  private func appendLengthPrefixed(_ component: Data, to data: inout Data) {
    var length = UInt64(component.count).bigEndian
    withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
    data.append(component)
  }

  private func bigEndianData(_ value: UInt64) -> Data {
    var bigEndian = value.bigEndian
    return withUnsafeBytes(of: &bigEndian) { Data($0) }
  }

  private func fingerprint(
    descriptor: Int32,
    initial: stat,
    sourceURL: URL
  ) throws -> SourceFingerprint {
    let digest = try hashDescriptor(descriptor)
    var final = stat()
    guard fstat(descriptor, &final) == 0, stableIdentity(initial, final) else {
      throw StagingError.sourceChanged
    }
    var path = stat()
    guard lstat(sourceURL.path, &path) == 0, stableIdentity(final, path) else {
      throw StagingError.sourceChanged
    }
    return sourceFingerprint(digest: digest, status: final)
  }

  private func openBoundSource(_ url: URL) throws -> (Int32, stat) {
    var path = stat()
    guard lstat(url.path, &path) == 0, (path.st_mode & S_IFMT) == S_IFREG else {
      throw StagingError.sourceReadFailed
    }
    let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw StagingError.sourceReadFailed }
    var opened = stat()
    guard fstat(descriptor, &opened) == 0, stableIdentity(path, opened) else {
      Darwin.close(descriptor)
      throw StagingError.sourceChanged
    }
    return (descriptor, opened)
  }

  private func hashDescriptor(_ descriptor: Int32) throws -> String {
    guard lseek(descriptor, 0, SEEK_SET) == 0 else { throw StagingError.sourceReadFailed }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    var hasher = SHA256()
    do {
      while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
        hasher.update(data: chunk)
      }
    } catch {
      throw StagingError.sourceReadFailed
    }
    return CanonicalReceiptDigest.hex(hasher.finalize())
  }

  private func stableIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
      && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
      && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
      && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
      && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
  }

  private func sourceFingerprint(digest: String, status: stat) -> SourceFingerprint {
    SourceFingerprint(
      sha256: digest,
      sizeBytes: UInt64(status.st_size),
      deviceID: UInt64(status.st_dev),
      inode: UInt64(status.st_ino),
      modificationTimeSeconds: Int64(status.st_mtimespec.tv_sec),
      modificationTimeNanoseconds: Int64(status.st_mtimespec.tv_nsec))
  }

  private func sqliteCompanionsAbsent(_ url: URL) -> Bool {
    ["-journal", "-wal", "-shm"].allSatisfy { suffix in
      var companion = stat()
      errno = 0
      return lstat(url.path + suffix, &companion) != 0 && errno == ENOENT
    }
  }

  private func siblingTemporaryURL(for destination: URL) -> URL {
    destination.deletingLastPathComponent().appendingPathComponent(
      ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
  }

  private func siblingPublicationPinURL(for destination: URL) -> URL {
    destination.deletingLastPathComponent().appendingPathComponent(
      ".\(destination.lastPathComponent).\(UUID().uuidString).pin")
  }

  private func removeTemporary(_ url: URL) throws {
    if Darwin.unlink(url.path) == 0 { return }
    if errno == ENOENT { return }
    throw StagingError.stagingWriteFailed
  }
}

struct RawColumn {
  let ordinal: Int
  let name: String
  let declaredType: String?
}

struct RawField {
  let ordinal: Int
  let name: String
  let declaredType: String?
  let storageClass: SQLiteStorageClass
  let payload: Data
}

struct RawRecord {
  let fields: [RawField]
  let canonical: Data
  let opaqueByteCount: Int
}

struct StagedField {
  let id: String
  let ordinal: Int
  let name: String
  let sidecar: OpaqueSidecar
}

struct StagedRecord {
  let id: String
  let recordKey: String
  let fields: [StagedField]
  let opaqueByteCount: Int
}

struct StagedTable {
  let id: String
  let name: String
  let records: [StagedRecord]
}

struct StagingContents {
  let stagingID: String
  let tables: [StagedTable]
  let recordCount: Int
  let fieldCount: Int
  let opaqueByteCount: Int
}
