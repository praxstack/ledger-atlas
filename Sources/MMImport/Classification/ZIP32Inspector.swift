import CSQLite
import Foundation

enum ZIP32Inspector {
  private struct Entry {
    let flags: UInt16
    let method: UInt16
    let crc: UInt32
    let compressedSize: Int
    let uncompressedSize: Int
    let localOffset: Int
    let rawName: Data
    let normalizedName: String
    let directory: Bool
  }

  private struct LocalLayout {
    let dataStart: Int
    let dataEnd: Int
  }

  static func sqliteCandidate(
    in archive: Data,
    limits: ZIPInspectionLimits
  ) -> Result<Data, ClassificationDiagnostic> {
    guard archive.count >= 22 else { return .failure(.malformedZIP) }
    let signature = Data([0x50, 0x4b, 0x05, 0x06])
    let start = max(0, archive.count - 65_557)
    guard
      let eocdRange = archive.range(
        of: signature,
        options: .backwards,
        in: start..<archive.count
      )
    else { return .failure(.malformedZIP) }
    let eocd = eocdRange.lowerBound
    guard has(archive, eocd, 22),
      let disk = u16(archive, eocd + 4),
      let centralDisk = u16(archive, eocd + 6),
      let diskEntries = u16(archive, eocd + 8),
      let totalEntries = u16(archive, eocd + 10),
      let centralSize = u32(archive, eocd + 12),
      let centralOffset = u32(archive, eocd + 16),
      let commentLength = u16(archive, eocd + 20),
      eocd + 22 + Int(commentLength) == archive.count
    else { return .failure(.malformedZIP) }
    guard disk == 0, centralDisk == 0, diskEntries == totalEntries else {
      return .failure(.multidiskZIP)
    }
    guard totalEntries != UInt16.max, centralSize != UInt32.max,
      centralOffset != UInt32.max
    else { return .failure(.unsupportedZIP64) }
    guard Int(totalEntries) <= limits.maximumEntries,
      has(archive, Int(centralOffset), Int(centralSize)),
      Int(centralOffset) + Int(centralSize) <= eocd
    else { return .failure(.zipBoundsExceeded) }

    var entries: [Entry] = []
    var normalizedNames = Set<String>()
    var totalUncompressed = 0
    var cursor = Int(centralOffset)
    for _ in 0..<Int(totalEntries) {
      guard u32(archive, cursor) == 0x0201_4b50, has(archive, cursor, 46),
        let versionMade = u16(archive, cursor + 4),
        let flags = u16(archive, cursor + 8),
        let method = u16(archive, cursor + 10),
        let crc = u32(archive, cursor + 16),
        let compressed = u32(archive, cursor + 20),
        let uncompressed = u32(archive, cursor + 24),
        let nameLength = u16(archive, cursor + 28),
        let extraLength = u16(archive, cursor + 30),
        let entryCommentLength = u16(archive, cursor + 32),
        let startDisk = u16(archive, cursor + 34),
        let externalAttributes = u32(archive, cursor + 38),
        let localOffset = u32(archive, cursor + 42)
      else { return .failure(.malformedZIP) }
      if compressed == UInt32.max || uncompressed == UInt32.max
        || localOffset == UInt32.max
      {
        return .failure(.unsupportedZIP64)
      }
      if startDisk != 0 { return .failure(.multidiskZIP) }
      if flags & 0x0001 != 0 || flags & 0x0040 != 0 {
        return .failure(.encryptedZIP)
      }
      guard method == 0 || method == 8 else {
        return .failure(.unsupportedZIPCompression)
      }
      let variableLength = Int(nameLength) + Int(extraLength) + Int(entryCommentLength)
      guard has(archive, cursor + 46, variableLength) else {
        return .failure(.malformedZIP)
      }
      let nameStart = cursor + 46
      let rawName = archive.subdata(in: nameStart..<(nameStart + Int(nameLength)))
      let extraStart = nameStart + Int(nameLength)
      let extra = archive.subdata(in: extraStart..<(extraStart + Int(extraLength)))
      if containsZIP64(extra) { return .failure(.unsupportedZIP64) }
      guard let normalized = normalizedName(rawName) else {
        return .failure(.unsafeZIPPath)
      }
      guard normalizedNames.insert(normalized).inserted else {
        return .failure(.duplicateZIPName)
      }
      if versionMade >> 8 == 3,
        ((externalAttributes >> 16) & 0xf000) == 0xa000
      {
        return .failure(.symlinkZIPEntry)
      }
      let compressedCount = Int(compressed)
      let uncompressedCount = Int(uncompressed)
      guard uncompressedCount <= limits.maximumMemberBytes else {
        return .failure(.zipBoundsExceeded)
      }
      totalUncompressed += uncompressedCount
      guard totalUncompressed <= limits.maximumTotalUncompressedBytes else {
        return .failure(.zipBoundsExceeded)
      }
      if uncompressedCount > 0 {
        guard compressedCount > 0 else { return .failure(.zipBoundsExceeded) }
        let ratio = Double(uncompressedCount) / Double(compressedCount)
        guard ratio.isFinite, ratio <= limits.maximumCompressionRatio else {
          return .failure(.zipBoundsExceeded)
        }
      }
      entries.append(
        Entry(
          flags: flags,
          method: method,
          crc: crc,
          compressedSize: compressedCount,
          uncompressedSize: uncompressedCount,
          localOffset: Int(localOffset),
          rawName: rawName,
          normalizedName: normalized,
          directory: normalized.hasSuffix("/")
        )
      )
      cursor += 46 + variableLength
    }
    guard cursor == Int(centralOffset) + Int(centralSize) else {
      return .failure(.malformedZIP)
    }

    var localRanges: [(start: Int, end: Int)] = []
    for entry in entries {
      if entry.directory && (entry.compressedSize != 0 || entry.uncompressedSize != 0) {
        return .failure(.malformedZIP)
      }
      switch roughLocalRange(entry, from: archive, centralOffset: Int(centralOffset)) {
      case .success(let range): localRanges.append(range)
      case .failure(let diagnostic): return .failure(diagnostic)
      }
    }
    for index in localRanges.indices {
      for other in localRanges.indices where other > index {
        if max(localRanges[index].start, localRanges[other].start)
          < min(localRanges[index].end, localRanges[other].end)
        {
          return .failure(.zipStructureOverlap)
        }
      }
    }
    for entry in entries {
      switch localLayout(entry, from: archive, centralOffset: Int(centralOffset)) {
      case .success: break
      case .failure(let diagnostic): return .failure(diagnostic)
      }
    }

    var candidates: [Data] = []
    var candidateName: String?
    for entry in entries where !entry.directory {
      switch materialize(entry, from: archive) {
      case .success(let member):
        if member.starts(with: Data("SQLite format 3\0".utf8)) {
          candidates.append(member)
          candidateName = entry.normalizedName
          if candidates.count > 1 { return .failure(.duplicateSQLiteCandidates) }
        }
      case .failure(let diagnostic): return .failure(diagnostic)
      }
    }
    guard let candidate = candidates.first else { return .failure(.noSQLiteCandidate) }
    if let candidateName,
      entries.contains(where: {
        $0.normalizedName == candidateName + "-wal"
          || $0.normalizedName == candidateName + "-shm"
      })
    {
      return .failure(.archivedCompanionFiles)
    }
    return .success(candidate)
  }

  private static func materialize(
    _ entry: Entry,
    from archive: Data
  ) -> Result<Data, ClassificationDiagnostic> {
    let layout: LocalLayout
    switch localLayout(entry, from: archive, centralOffset: archive.count) {
    case .success(let value): layout = value
    case .failure(let diagnostic): return .failure(diagnostic)
    }
    let compressed = archive.subdata(in: layout.dataStart..<layout.dataEnd)
    let output: Data
    if entry.method == 0 {
      guard compressed.count == entry.uncompressedSize else {
        return .failure(.malformedZIP)
      }
      output = compressed
    } else if entry.uncompressedSize == 0 {
      output = Data()
    } else {
      var destination = Data(count: entry.uncompressedSize)
      let destinationCount = destination.count
      let result = compressed.withUnsafeBytes { sourceBuffer in
        destination.withUnsafeMutableBytes { destinationBuffer in
          csqlite_inflate_raw(
            sourceBuffer.bindMemory(to: UInt8.self).baseAddress,
            compressed.count,
            destinationBuffer.bindMemory(to: UInt8.self).baseAddress,
            destinationCount
          )
        }
      }
      guard result == 0 else { return .failure(.malformedZIP) }
      output = destination
    }
    let actualCRC = output.withUnsafeBytes { buffer in
      csqlite_crc32(buffer.bindMemory(to: UInt8.self).baseAddress, output.count)
    }
    guard actualCRC == entry.crc else { return .failure(.zipCRCFailed) }
    return .success(output)
  }

  private static func localLayout(
    _ entry: Entry,
    from archive: Data,
    centralOffset: Int
  ) -> Result<LocalLayout, ClassificationDiagnostic> {
    let offset = entry.localOffset
    guard offset >= 0, offset < centralOffset, has(archive, offset, 30),
      u32(archive, offset) == 0x0403_4b50,
      let localFlags = u16(archive, offset + 6),
      let localMethod = u16(archive, offset + 8),
      let localCRC = u32(archive, offset + 14),
      let localCompressed = u32(archive, offset + 18),
      let localUncompressed = u32(archive, offset + 22),
      let nameLength = u16(archive, offset + 26),
      let extraLength = u16(archive, offset + 28)
    else { return .failure(.malformedZIP) }
    if entry.flags & 0x0008 != 0 || localFlags & 0x0008 != 0 {
      return .failure(.unsupportedZIPDataDescriptor)
    }
    guard localFlags == entry.flags, localMethod == entry.method,
      localCRC == entry.crc,
      localCompressed == UInt32(entry.compressedSize),
      localUncompressed == UInt32(entry.uncompressedSize)
    else { return .failure(.malformedZIP) }
    let nameStart = offset + 30
    let variableLength = Int(nameLength) + Int(extraLength)
    guard has(archive, nameStart, variableLength) else {
      return .failure(.malformedZIP)
    }
    let localName = archive.subdata(in: nameStart..<(nameStart + Int(nameLength)))
    guard localName == entry.rawName else { return .failure(.malformedZIP) }
    let extraStart = nameStart + Int(nameLength)
    let localExtra = archive.subdata(in: extraStart..<(extraStart + Int(extraLength)))
    if containsZIP64(localExtra) { return .failure(.unsupportedZIP64) }
    let dataStart = extraStart + Int(extraLength)
    guard has(archive, dataStart, entry.compressedSize),
      dataStart + entry.compressedSize <= centralOffset
    else { return .failure(.malformedZIP) }
    return .success(LocalLayout(dataStart: dataStart, dataEnd: dataStart + entry.compressedSize))
  }

  private static func roughLocalRange(
    _ entry: Entry,
    from archive: Data,
    centralOffset: Int
  ) -> Result<(start: Int, end: Int), ClassificationDiagnostic> {
    let offset = entry.localOffset
    guard offset >= 0, offset < centralOffset, has(archive, offset, 30),
      u32(archive, offset) == 0x0403_4b50,
      let nameLength = u16(archive, offset + 26),
      let extraLength = u16(archive, offset + 28)
    else { return .failure(.malformedZIP) }
    let dataStart = offset + 30 + Int(nameLength) + Int(extraLength)
    guard has(archive, dataStart, entry.compressedSize),
      dataStart + entry.compressedSize <= centralOffset
    else { return .failure(.malformedZIP) }
    return .success((offset, dataStart + entry.compressedSize))
  }

  private static func normalizedName(_ bytes: Data) -> String? {
    guard !bytes.contains(0), var name = String(data: bytes, encoding: .utf8) else {
      return nil
    }
    name = name.precomposedStringWithCanonicalMapping
    guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"),
      !name.contains(":")
    else { return nil }
    let isDirectory = name.hasSuffix("/")
    let components = name.split(separator: "/", omittingEmptySubsequences: false)
    guard components.allSatisfy({ !$0.isEmpty || isDirectory }) else { return nil }
    var normalized: [Substring] = []
    for component in components where !component.isEmpty {
      if component == ".." { return nil }
      if component != "." { normalized.append(component) }
    }
    guard !normalized.isEmpty else { return nil }
    return normalized.joined(separator: "/") + (isDirectory ? "/" : "")
  }

  private static func containsZIP64(_ extra: Data) -> Bool {
    var cursor = 0
    while cursor + 4 <= extra.count {
      guard let identifier = u16(extra, cursor), let size = u16(extra, cursor + 2),
        cursor + 4 + Int(size) <= extra.count
      else { return true }
      if identifier == 0x0001 { return true }
      cursor += 4 + Int(size)
    }
    return cursor != extra.count
  }

  private static func has(_ data: Data, _ offset: Int, _ count: Int) -> Bool {
    offset >= 0 && count >= 0 && offset <= data.count && count <= data.count - offset
  }

  private static func u16(_ data: Data, _ offset: Int) -> UInt16? {
    guard has(data, offset, 2) else { return nil }
    return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
  }

  private static func u32(_ data: Data, _ offset: Int) -> UInt32? {
    guard has(data, offset, 4) else { return nil }
    return UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
      | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
  }
}
