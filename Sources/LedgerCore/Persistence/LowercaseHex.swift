extension Sequence where Element == UInt8 {
  /// Two lowercase hex digits per byte: the same text as `String(format: "%02x")` per byte,
  /// without a Foundation format call per byte (that was a large share of import time).
  package var lowercaseHex: String {
    let digits: [UInt8] = Array("0123456789abcdef".utf8)
    var bytes: [UInt8] = []
    bytes.reserveCapacity(underestimatedCount * 2)
    for byte in self {
      bytes.append(digits[Int(byte >> 4)])
      bytes.append(digits[Int(byte & 0x0f)])
    }
    return String(decoding: bytes, as: UTF8.self)
  }
}
