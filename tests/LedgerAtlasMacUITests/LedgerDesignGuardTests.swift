import Foundation
import Testing

/// Design guards from DESIGN.md: colours come from `LedgerTheme`, amounts on screen go through
/// `MoneyText` or the display formatter, and captions use the theme's caption style.
///
/// These are ratchets. A file not listed below may have none of these uses (system colours and
/// caption fonts are already gone everywhere). A listed file may have at most its count, so the
/// lists only shrink as screens move onto the design system.
/// When you remove uses, lower the count (or drop the file) in the same change.
@Test func designSystemUsesOnlyShrink() throws {
  for rule in DesignGuardRule.all {
    var found: [String: [String]] = [:]
    for (file, lines) in try guardedSources() where !rule.exempt.keys.contains(file) {
      for (index, line) in lines.enumerated() {
        for pattern in rule.patterns {
          let range = NSRange(line.startIndex..., in: line)
          for _ in pattern.matches(in: line, range: range) {
            found[file, default: []].append(
              "\(file):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
          }
        }
      }
    }
    for (file, uses) in found.sorted(by: { $0.key < $1.key }) {
      let allowed = rule.remaining[file] ?? 0
      #expect(
        uses.count <= allowed,
        "\(rule.name): \(file) has \(uses.count), allowed \(allowed). \(rule.fix)\n\(uses.joined(separator: "\n"))")
      if uses.count < allowed {
        print("DESIGN GUARD \(rule.name): \(file) is down to \(uses.count); lower its count to \(uses.count).")
      }
    }
  }
}

private struct DesignGuardRule {
  let name: String
  let fix: String
  let patterns: [NSRegularExpression]
  /// Files that still have these uses, with how many. Lower as they are fixed.
  let remaining: [String: Int]
  /// Files the rule doesn't apply to, with the reason.
  let exempt: [String: String]

  init(
    _ name: String, fix: String, patterns: [String], remaining: [String: Int],
    exempt: [String: String] = [:]
  ) {
    self.name = name
    self.fix = fix
    // The patterns are fixed literals checked by this test itself.
    self.patterns = patterns.map { try! NSRegularExpression(pattern: $0) }
    self.remaining = remaining
    self.exempt = exempt
  }

  static let all: [DesignGuardRule] = [
    DesignGuardRule(
      "system colour",
      fix: "Use a LedgerTheme token (ink, inkSecondary, negative, warning, accent, …).",
      patterns: [
        #"\.(foregroundStyle|foregroundColor|tint|fill|background|stroke|strokeBorder|border)\(\s*\.(primary|secondary|tertiary|quaternary|red|green|orange|blue|yellow|purple|pink|gray|mint|teal|cyan|indigo|brown)\b"#,
        #"\bColor\.(primary|secondary|red|green|orange|blue|yellow|purple|pink|gray|mint|teal|cyan|indigo|brown|accentColor)\b"#,
        #"\.buttonStyle\(\.link\)"#,
        #"\bNSColor\.(system[A-Z]\w*|labelColor|secondaryLabelColor|tertiaryLabelColor|controlAccentColor)\b"#,
      ],
      remaining: [:],
      exempt: ["LedgerTheme.swift": "defines the tokens"]),
    DesignGuardRule(
      "raw amount",
      fix: "Show money with MoneyText, or formatter.parts(_:).text in a sentence.",
      patterns: [#"\\\([\w.$]*rawLiteral\)"#],
      remaining: [
        "InsightsSurface.swift": 1, "LedgerJourney.swift": 4, "LedgerSession.swift": 1,
        "PlanningViews.swift": 6, "TransactionForms.swift": 2,
      ],
      exempt: ["InsightsReport.swift": "plain-text export, not shown on screen"]),
    DesignGuardRule(
      "raw caption font",
      fix: "Use LedgerTheme.Typeface.caption (Subheadline); .caption is below the design's size.",
      patterns: [#"\.font\(\.(caption2?|footnote)\)"#],
      remaining: [:]),
  ]
}

/// The Mac UI module's sources, by file name.
private func guardedSources() throws -> [(String, [String])] {
  let sources = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/LedgerAtlasMacUI")
  var result: [(String, [String])] = []
  let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
  while let file = files?.nextObject() as? URL {
    guard file.pathExtension == "swift" else { continue }
    result.append(
      (file.lastPathComponent,
       try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")))
  }
  return result
}
