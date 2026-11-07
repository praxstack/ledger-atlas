import AppKit
import CryptoKit
import Foundation
import Testing

// Synthetic data only: the baseline describes captures of the made-up demo ledger.

/// #57 snapshot regression on the capture set: each capture is compared with a committed
/// baseline of the synthetic set, and a change beyond a small tolerance fails CI until the
/// baseline is deliberately updated.
///
/// Two readings per capture, so a change in words and a change in looks are both caught:
///
/// - **Text**: a hash of what the screen says (the Accessibility text the capture test already
///   reads), with digits, month and day names, relative days, UUIDs and temp paths masked. The
///   demo ledger's rows are fixed, but the screens use today's date, so the text would otherwise
///   change every day. The hash must match exactly.
/// - **Looks**: a 64-bit difference hash of the PNG (9×8 greyscale, each bit says whether a
///   pixel is brighter than its right neighbour). Hamming distance up to `looksTolerance` bits
///   passes, so anti-aliasing, a changed digit or a moved scroll bar don't fail; a moved
///   section, a missing control or a changed colour scheme do.
///
/// Every run writes the current readings to `ui-captures/capture-baseline.json` and the
/// normalised text of each capture to `ui-captures/snapshot-text/` in the CI artifact. To update
/// the committed baseline after a deliberate change, download that `ui-captures` artifact from
/// the run and copy its `capture-baseline.json` over `Fixtures/capture-baseline.json`, or run
/// `scripts/ci/update-capture-baseline.sh <run-id>`, which does both.
@MainActor
final class CaptureSnapshots {
  static let looksTolerance = 10
  static let baselineURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent("Fixtures/capture-baseline.json")

  struct Reading: Codable, Equatable {
    let text: String
    let looks: String
    let lines: Int
  }

  private(set) var readings: [String: Reading] = [:]
  private var texts: [String: String] = [:]

  func add(file: String, png: Data, text: [String]) {
    let normalised = Self.normalise(text)
    let digest = SHA256.hash(data: Data(normalised.utf8)).map { String(format: "%02x", $0) }.joined()
    let looks = Self.differenceHash(png).map { String(format: "%016llx", $0) } ?? ""
    readings[file] = Reading(text: digest, looks: looks, lines: text.count)
    texts[file] = normalised
  }

  /// Writes this run's readings and texts into the artifact folder, then compares the readings
  /// with the committed baseline.
  func verify(writingTo output: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(readings).write(to: output.appendingPathComponent("capture-baseline.json"))
    let textFolder = output.appendingPathComponent("snapshot-text")
    try FileManager.default.createDirectory(at: textFolder, withIntermediateDirectories: true)
    for (file, text) in texts {
      try text.write(
        to: textFolder.appendingPathComponent(file + ".txt"), atomically: true, encoding: .utf8)
    }

    guard let data = try? Data(contentsOf: Self.baselineURL) else {
      Issue.record(
        "no committed capture baseline at \(Self.baselineURL.path); copy capture-baseline.json from the ui-captures artifact there"
      )
      return
    }
    let baseline = try JSONDecoder().decode([String: Reading].self, from: data)
    var problems: [String] = []
    for file in Set(baseline.keys).union(readings.keys).sorted() {
      guard let expected = baseline[file] else {
        problems.append("\(file): captured, but not in the baseline")
        continue
      }
      guard let actual = readings[file] else {
        problems.append("\(file): in the baseline, but not captured")
        continue
      }
      if actual.text != expected.text {
        problems.append(
          "\(file): the screen's text changed (\(expected.lines) -> \(actual.lines) lines); see snapshot-text/\(file).txt in the ui-captures artifact"
        )
      }
      if let distance = Self.distance(actual.looks, expected.looks) {
        if distance > Self.looksTolerance {
          problems.append("\(file): the picture changed (\(distance) of 64 bits, tolerance \(Self.looksTolerance))")
        }
      } else {
        problems.append("\(file): no difference hash (\(expected.looks) vs \(actual.looks))")
      }
    }
    print("SNAPSHOT \(readings.count) captures compared with the baseline, \(problems.count) changed")
    #expect(
      problems.isEmpty,
      "captures differ from the committed baseline. If the change is intended, update Fixtures/capture-baseline.json from the ui-captures artifact.\n\(problems.joined(separator: "\n"))"
    )
  }

  // MARK: Readings

  static func normalise(_ lines: [String]) -> String {
    let masks: [(String, String)] = [
      (#"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#, "UUID"),
      (#"(/private)?/var/folders/\S+"#, "TMPPATH"),
      (#"\b(January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)\b"#, "MONTH"),
      (#"\b(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday|Mon|Tue|Wed|Thu|Fri|Sat|Sun)\b"#, "DAY"),
      (#"\b(Today|Yesterday|Tomorrow|today|yesterday|tomorrow)\b"#, "RELDAY"),
      (#"\d"#, "#"),
    ]
    return lines.map { line in
      masks.reduce(line) { text, mask in
        text.replacingOccurrences(of: mask.0, with: mask.1, options: .regularExpression)
      }
    }.joined(separator: "\n")
  }

  /// A difference hash: the PNG shrunk to 9×8 grey, one bit per horizontal neighbour pair.
  static func differenceHash(_ png: Data) -> UInt64? {
    guard let rep = NSBitmapImageRep(data: png), let image = rep.cgImage else { return nil }
    let width = 9
    let height = 8
    var pixels = [UInt8](repeating: 0, count: width * height)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
          bitmapInfo: CGImageAlphaInfo.none.rawValue)
      else { return false }
      context.interpolationQuality = .high
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn else { return nil }
    var hash: UInt64 = 0
    for y in 0..<height {
      for x in 0..<(width - 1) {
        hash <<= 1
        if pixels[y * width + x] < pixels[y * width + x + 1] { hash |= 1 }
      }
    }
    return hash
  }

  static func distance(_ a: String, _ b: String) -> Int? {
    guard let x = UInt64(a, radix: 16), let y = UInt64(b, radix: 16) else { return nil }
    return (x ^ y).nonzeroBitCount
  }
}
