import Foundation

/// The small part of ZIP that XLSX needs, with no system compression library.
///
/// Writing stores entries uncompressed, which every spreadsheet app reads. Reading accepts
/// stored and deflated entries, and refuses encryption, ZIP64, multi-disk archives and
/// anything that does not add up, so a hostile file fails closed instead of misreading.
public enum XLSXArchive {
  public enum Error: Swift.Error, Equatable, Sendable {
    case notAnArchive
    case unsupported(String)
    case damaged(String)
    case tooLarge
    case duplicateEntry(String)
    case unsafeEntryName(String)
  }

  /// Limits for reading. The defaults cover any realistic personal ledger.
  public struct Limits: Equatable, Sendable {
    public var maximumEntries: Int
    public var maximumEntryBytes: Int
    public var maximumTotalBytes: Int

    public init(
      maximumEntries: Int = 4_096, maximumEntryBytes: Int = 256 << 20,
      maximumTotalBytes: Int = 512 << 20
    ) {
      self.maximumEntries = maximumEntries
      self.maximumEntryBytes = maximumEntryBytes
      self.maximumTotalBytes = maximumTotalBytes
    }
  }

  // MARK: Writing

  /// A stored (uncompressed) ZIP of `entries`, in the given order. Timestamps are fixed so
  /// the same entries always produce the same bytes.
  public static func write(_ entries: [(name: String, data: Data)]) throws -> Data {
    var seen: Set<String> = []
    var output = Data()
    var central = Data()
    for (name, data) in entries {
      guard isSafe(name) else { throw Error.unsafeEntryName(name) }
      guard seen.insert(name).inserted else { throw Error.duplicateEntry(name) }
      let nameBytes = Data(name.utf8)
      guard data.count < Int(UInt32.max), output.count < Int(UInt32.max),
        nameBytes.count <= Int(UInt16.max), seen.count < Int(UInt16.max)
      else { throw Error.tooLarge }
      let crc = CRC32.checksum(data)
      let offset = UInt32(output.count)

      output.appendLE(UInt32(0x0403_4b50))
      output.appendLE(UInt16(20))  // version needed
      output.appendLE(UInt16(0x0800))  // flags: UTF-8 names
      output.appendLE(UInt16(0))  // stored
      output.appendLE(UInt16(0))  // time
      output.appendLE(UInt16(0x0021))  // date: 1980-01-01
      output.appendLE(crc)
      output.appendLE(UInt32(data.count))
      output.appendLE(UInt32(data.count))
      output.appendLE(UInt16(nameBytes.count))
      output.appendLE(UInt16(0))
      output.append(nameBytes)
      output.append(data)

      central.appendLE(UInt32(0x0201_4b50))
      central.appendLE(UInt16(20))  // version made by
      central.appendLE(UInt16(20))
      central.appendLE(UInt16(0x0800))
      central.appendLE(UInt16(0))
      central.appendLE(UInt16(0))
      central.appendLE(UInt16(0x0021))
      central.appendLE(crc)
      central.appendLE(UInt32(data.count))
      central.appendLE(UInt32(data.count))
      central.appendLE(UInt16(nameBytes.count))
      central.appendLE(UInt16(0))  // extra
      central.appendLE(UInt16(0))  // comment
      central.appendLE(UInt16(0))  // disk
      central.appendLE(UInt16(0))  // internal attributes
      central.appendLE(UInt32(0))  // external attributes
      central.appendLE(offset)
      central.append(nameBytes)
    }
    guard output.count + central.count < Int(UInt32.max) else { throw Error.tooLarge }
    let centralOffset = UInt32(output.count)
    output.append(central)
    output.appendLE(UInt32(0x0605_4b50))
    output.appendLE(UInt16(0))
    output.appendLE(UInt16(0))
    output.appendLE(UInt16(entries.count))
    output.appendLE(UInt16(entries.count))
    output.appendLE(UInt32(central.count))
    output.appendLE(centralOffset)
    output.appendLE(UInt16(0))
    return output
  }

  // MARK: Reading

  /// Every entry by name. Directory entries are skipped.
  public static func read(_ archive: Data, limits: Limits = Limits()) throws -> [String: Data] {
    let bytes = [UInt8](archive)
    guard bytes.count >= 22, bytes.starts(with: [0x50, 0x4b]) else { throw Error.notAnArchive }

    // The end record sits in the last 22 + 65,535 bytes.
    var endOffset: Int?
    var probe = bytes.count - 22
    let floor = max(0, bytes.count - 22 - 0xFFFF)
    while probe >= floor {
      if bytes.u32(probe) == 0x0605_4b50, probe + 22 + Int(bytes.u16(probe + 20)) == bytes.count {
        endOffset = probe
        break
      }
      probe -= 1
    }
    guard let end = endOffset else { throw Error.notAnArchive }
    guard bytes.u16(end + 4) == 0, bytes.u16(end + 6) == 0,
      bytes.u16(end + 8) == bytes.u16(end + 10)
    else { throw Error.unsupported("multi-disk archive") }
    let count = Int(bytes.u16(end + 10))
    let centralSize = Int(bytes.u32(end + 12))
    let centralOffset = Int(bytes.u32(end + 16))
    if count == 0xFFFF || centralSize == 0xFFFF_FFFF || centralOffset == 0xFFFF_FFFF {
      throw Error.unsupported("ZIP64")
    }
    guard count <= limits.maximumEntries else { throw Error.tooLarge }
    guard centralOffset + centralSize <= end else { throw Error.damaged("central directory") }

    var entries: [String: Data] = [:]
    var total = 0
    var cursor = centralOffset
    for _ in 0..<count {
      guard cursor + 46 <= end, bytes.u32(cursor) == 0x0201_4b50 else {
        throw Error.damaged("central directory")
      }
      let flags = bytes.u16(cursor + 8)
      let method = bytes.u16(cursor + 10)
      let crc = bytes.u32(cursor + 16)
      let compressedSize = Int(bytes.u32(cursor + 20))
      let size = Int(bytes.u32(cursor + 24))
      let nameLength = Int(bytes.u16(cursor + 28))
      let extraLength = Int(bytes.u16(cursor + 30))
      let commentLength = Int(bytes.u16(cursor + 32))
      let localOffset = Int(bytes.u32(cursor + 42))
      let nameEnd = cursor + 46 + nameLength
      guard nameEnd <= end else { throw Error.damaged("entry name") }
      guard let name = String(bytes: bytes[(cursor + 46)..<nameEnd], encoding: .utf8) else {
        throw Error.damaged("entry name")
      }
      cursor = nameEnd + extraLength + commentLength
      guard cursor <= end else { throw Error.damaged("central directory") }

      if flags & 0x0001 != 0 || flags & 0x0040 != 0 { throw Error.unsupported("encryption") }
      if compressedSize == 0xFFFF_FFFF || size == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
        throw Error.unsupported("ZIP64")
      }
      if name.hasSuffix("/") {
        guard size == 0 else { throw Error.damaged(name) }
        continue
      }
      guard isSafe(name) else { throw Error.unsafeEntryName(name) }
      guard entries[name] == nil else { throw Error.duplicateEntry(name) }
      guard size <= limits.maximumEntryBytes else { throw Error.tooLarge }
      total += size
      guard total <= limits.maximumTotalBytes else { throw Error.tooLarge }

      guard localOffset + 30 <= centralOffset, bytes.u32(localOffset) == 0x0403_4b50 else {
        throw Error.damaged(name)
      }
      let localName = Int(bytes.u16(localOffset + 26))
      let localExtra = Int(bytes.u16(localOffset + 28))
      let dataStart = localOffset + 30 + localName + localExtra
      let dataEnd = dataStart + compressedSize
      guard dataEnd <= centralOffset,
        bytes[(localOffset + 30)..<(localOffset + 30 + localName)].elementsEqual(name.utf8)
      else { throw Error.damaged(name) }

      let payload: [UInt8]
      switch method {
      case 0:
        guard compressedSize == size else { throw Error.damaged(name) }
        payload = Array(bytes[dataStart..<dataEnd])
      case 8:
        payload = try Inflate.decompress(bytes[dataStart..<dataEnd], expectedSize: size)
      default:
        throw Error.unsupported("compression method \(method)")
      }
      let data = Data(payload)
      guard payload.count == size, CRC32.checksum(data) == crc else { throw Error.damaged(name) }
      entries[name] = data
    }
    return entries
  }

  /// Relative, forward-slash names with no `..`, empty or absolute parts.
  static func isSafe(_ name: String) -> Bool {
    guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.utf8.contains(0)
    else { return false }
    return !name.split(separator: "/", omittingEmptySubsequences: false).contains {
      $0.isEmpty || $0 == "." || $0 == ".."
    }
  }
}

// MARK: - CRC-32

enum CRC32 {
  private static let table: [UInt32] = (0..<256).map { index in
    var value = UInt32(index)
    for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
    return value
  }

  static func checksum(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
    return crc ^ 0xFFFF_FFFF
  }
}

// MARK: - DEFLATE decoding (RFC 1951)

enum Inflate {
  private struct Huffman {
    var counts = [Int](repeating: 0, count: 16)
    var symbols: [Int]

    init(lengths: [Int]) throws {
      symbols = [Int](repeating: 0, count: lengths.count)
      for length in lengths { counts[length] += 1 }
      counts[0] = 0
      var left = 1
      for length in 1..<16 {
        left = (left << 1) - counts[length]
        guard left >= 0 else { throw XLSXArchive.Error.damaged("deflate code") }
      }
      var offsets = [Int](repeating: 0, count: 16)
      for length in 1..<15 { offsets[length + 1] = offsets[length] + counts[length] }
      for (symbol, length) in lengths.enumerated() where length != 0 {
        symbols[offsets[length]] = symbol
        offsets[length] += 1
      }
    }
  }

  private struct BitReader {
    let input: ArraySlice<UInt8>
    var position: Int
    var buffer = 0
    var available = 0

    init(_ input: ArraySlice<UInt8>) {
      self.input = input
      self.position = input.startIndex
    }

    mutating func bits(_ count: Int) throws -> Int {
      while available < count {
        guard position < input.endIndex else { throw XLSXArchive.Error.damaged("deflate data") }
        buffer |= Int(input[position]) << available
        position += 1
        available += 8
      }
      let value = buffer & ((1 << count) - 1)
      buffer >>= count
      available -= count
      return value
    }

    mutating func alignToByte() {
      buffer = 0
      available = 0
    }

    mutating func decode(_ code: Huffman) throws -> Int {
      var value = 0
      var first = 0
      var index = 0
      for length in 1..<16 {
        value |= try bits(1)
        let count = code.counts[length]
        if value - count < first { return code.symbols[index + (value - first)] }
        index += count
        first = (first + count) << 1
        value <<= 1
      }
      throw XLSXArchive.Error.damaged("deflate code")
    }
  }

  private static let lengthBase = [
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115,
    131, 163, 195, 227, 258,
  ]
  private static let lengthExtra = [
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
  ]
  private static let distanceBase = [
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537,
    2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
  ]
  private static let distanceExtra = [
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13,
    13,
  ]
  private static let fixed: (Huffman, Huffman) = {
    var lengths = [Int](repeating: 8, count: 288)
    for index in 144..<256 { lengths[index] = 9 }
    for index in 256..<280 { lengths[index] = 7 }
    return (
      try! Huffman(lengths: lengths), try! Huffman(lengths: [Int](repeating: 5, count: 30))
    )
  }()

  /// Decodes raw DEFLATE data that must expand to exactly `expectedSize` bytes.
  static func decompress(_ input: ArraySlice<UInt8>, expectedSize: Int) throws -> [UInt8] {
    var reader = BitReader(input)
    var output: [UInt8] = []
    output.reserveCapacity(expectedSize)
    var last = 0
    repeat {
      last = try reader.bits(1)
      switch try reader.bits(2) {
      case 0:
        reader.alignToByte()
        let start = reader.position
        guard start + 4 <= input.endIndex else { throw XLSXArchive.Error.damaged("deflate data") }
        let length = Int(input[start]) | Int(input[start + 1]) << 8
        let check = Int(input[start + 2]) | Int(input[start + 3]) << 8
        guard length == ~check & 0xFFFF, start + 4 + length <= input.endIndex,
          output.count + length <= expectedSize
        else { throw XLSXArchive.Error.damaged("deflate data") }
        output.append(contentsOf: input[(start + 4)..<(start + 4 + length)])
        reader.position = start + 4 + length
      case 1:
        try inflateBlock(&reader, &output, fixed.0, fixed.1, limit: expectedSize)
      case 2:
        let (lengths, distances) = try dynamicCodes(&reader)
        try inflateBlock(&reader, &output, lengths, distances, limit: expectedSize)
      default:
        throw XLSXArchive.Error.damaged("deflate block")
      }
    } while last == 0
    return output
  }

  private static func dynamicCodes(_ reader: inout BitReader) throws -> (Huffman, Huffman) {
    let literalCount = try reader.bits(5) + 257
    let distanceCount = try reader.bits(5) + 1
    let codeCount = try reader.bits(4) + 4
    guard literalCount <= 286, distanceCount <= 30 else {
      throw XLSXArchive.Error.damaged("deflate header")
    }
    let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
    var codeLengths = [Int](repeating: 0, count: 19)
    for index in 0..<codeCount { codeLengths[order[index]] = try reader.bits(3) }
    let lengthCode = try Huffman(lengths: codeLengths)

    var lengths: [Int] = []
    while lengths.count < literalCount + distanceCount {
      let symbol = try reader.decode(lengthCode)
      switch symbol {
      case 0..<16:
        lengths.append(symbol)
      case 16:
        guard let previous = lengths.last else { throw XLSXArchive.Error.damaged("deflate header") }
        lengths += [Int](repeating: previous, count: 3 + (try reader.bits(2)))
      case 17:
        lengths += [Int](repeating: 0, count: 3 + (try reader.bits(3)))
      default:
        lengths += [Int](repeating: 0, count: 11 + (try reader.bits(7)))
      }
    }
    guard lengths.count == literalCount + distanceCount, lengths[256] != 0 else {
      throw XLSXArchive.Error.damaged("deflate header")
    }
    return (
      try Huffman(lengths: Array(lengths[0..<literalCount])),
      try Huffman(lengths: Array(lengths[literalCount...]))
    )
  }

  private static func inflateBlock(
    _ reader: inout BitReader, _ output: inout [UInt8], _ lengths: Huffman, _ distances: Huffman,
    limit: Int
  ) throws {
    while true {
      let symbol = try reader.decode(lengths)
      if symbol < 256 {
        guard output.count < limit else { throw XLSXArchive.Error.damaged("deflate size") }
        output.append(UInt8(symbol))
      } else if symbol == 256 {
        return
      } else {
        let index = symbol - 257
        guard index < 29 else { throw XLSXArchive.Error.damaged("deflate length") }
        let length = lengthBase[index] + (try reader.bits(lengthExtra[index]))
        let distanceSymbol = try reader.decode(distances)
        guard distanceSymbol < 30 else { throw XLSXArchive.Error.damaged("deflate distance") }
        let distance = distanceBase[distanceSymbol] + (try reader.bits(distanceExtra[distanceSymbol]))
        guard distance <= output.count, output.count + length <= limit else {
          throw XLSXArchive.Error.damaged("deflate distance")
        }
        let start = output.count - distance
        for offset in 0..<length { output.append(output[start + offset]) }
      }
    }
  }
}

// MARK: - Little-endian helpers

extension Data {
  fileprivate mutating func appendLE(_ value: UInt16) {
    append(UInt8(value & 0xFF))
    append(UInt8(value >> 8))
  }

  fileprivate mutating func appendLE(_ value: UInt32) {
    for shift in stride(from: 0, to: 32, by: 8) { append(UInt8((value >> UInt32(shift)) & 0xFF)) }
  }
}

extension Array where Element == UInt8 {
  fileprivate func u16(_ offset: Int) -> UInt16 {
    guard offset + 2 <= count else { return 0 }
    return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
  }

  fileprivate func u32(_ offset: Int) -> UInt32 {
    guard offset + 4 <= count else { return 0 }
    return (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[offset + $1]) << UInt32(8 * $1) }
  }
}
