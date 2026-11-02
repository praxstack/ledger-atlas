import Foundation

#if canImport(WidgetKit)
  import WidgetKit
#endif

/// What the widget may show. It never holds names, notes, paths or amounts: only a fixed
/// state and, when a ledger is open and unlocked, two coarse counts.
///
/// This file is compiled into the widget too, so it depends on Foundation only.
public struct RedactedWidgetProjection: Codable, Equatable, Sendable {
  public enum State: String, Codable, Sendable {
    case empty
    case permissionDenied
    case ready
    case reopenRequired
    case locked
  }

  /// Budget health as one bucket, never an amount.
  public enum BudgetBucket: String, Codable, Sendable {
    case none
    case onTrack
    case nearLimit
    case over
  }

  public struct Summary: Codable, Equatable, Sendable {
    /// Active entries dated in the current month.
    public let entriesThisMonth: Int
    public let budgets: BudgetBucket

    public init(entriesThisMonth: Int, budgets: BudgetBucket) {
      self.entriesThisMonth = max(0, entriesThisMonth)
      self.budgets = budgets
    }

    private enum CodingKeys: String, CodingKey { case entriesThisMonth, budgets }

    public init(from decoder: any Decoder) throws {
      let raw = try decoder.container(keyedBy: AnyKey.self)
      guard Set(raw.allKeys.map(\.stringValue)) == ["entriesThisMonth", "budgets"] else {
        throw DecodingError.dataCorruptedError(
          forKey: AnyKey(stringValue: "budgets")!, in: raw,
          debugDescription: "Unexpected widget summary fields.")
      }
      let values = try decoder.container(keyedBy: CodingKeys.self)
      let count = try values.decode(Int.self, forKey: .entriesThisMonth)
      guard count >= 0 else {
        throw DecodingError.dataCorruptedError(
          forKey: .entriesThisMonth, in: values, debugDescription: "Negative count.")
      }
      self.init(
        entriesThisMonth: count, budgets: try values.decode(BudgetBucket.self, forKey: .budgets))
    }
  }

  public static let currentSchemaVersion = 2

  public let schemaVersion: Int
  public let state: State
  /// Present only when `state` is `.ready`.
  public let summary: Summary?

  public init(state: State, summary: Summary? = nil) {
    schemaVersion = Self.currentSchemaVersion
    self.state = state
    self.summary = state == .ready ? summary : nil
  }

  private enum CodingKeys: String, CodingKey { case schemaVersion, state, summary }
  fileprivate struct AnyKey: CodingKey {
    let stringValue: String
    init?(stringValue: String) { self.stringValue = stringValue }
    let intValue: Int? = nil
    init?(intValue: Int) { nil }
  }

  /// Reads version 2, and version 1 files written by earlier builds. Any other field, version
  /// or state is refused, so nothing unexpected reaches the widget.
  public init(from decoder: any Decoder) throws {
    let rawValues = try decoder.container(keyedBy: AnyKey.self)
    let keys = Set(rawValues.allKeys.map(\.stringValue))
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
    let allowed: Set<String> =
      switch schemaVersion {
      case 1: ["schemaVersion", "state"]
      case 2: ["schemaVersion", "state", "summary"]
      default:
        throw DecodingError.dataCorruptedError(
          forKey: .schemaVersion, in: values, debugDescription: "Unsupported widget projection.")
      }
    guard keys.isSubset(of: allowed), keys.contains("state") else {
      throw DecodingError.dataCorruptedError(
        forKey: AnyKey(stringValue: "state")!, in: rawValues,
        debugDescription: "Unexpected widget projection fields.")
    }
    let state = try values.decode(State.self, forKey: .state)
    if schemaVersion == 1, state == .locked {
      throw DecodingError.dataCorruptedError(
        forKey: .state, in: values, debugDescription: "Unsupported widget state.")
    }
    let summary = try values.decodeIfPresent(Summary.self, forKey: .summary)
    guard summary == nil || state == .ready else {
      throw DecodingError.dataCorruptedError(
        forKey: .summary, in: values, debugDescription: "Summary without a ready ledger.")
    }
    self.init(state: state, summary: summary)
  }

  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(schemaVersion, forKey: .schemaVersion)
    try values.encode(state, forKey: .state)
    try values.encodeIfPresent(summary, forKey: .summary)
  }

  public var message: String {
    switch state {
    case .empty: "Open Ledger Atlas to get started."
    case .permissionDenied: "Allow access in Ledger Atlas to continue."
    case .ready: "Ledger Atlas is ready."
    case .reopenRequired: "Open Ledger Atlas to continue."
    case .locked: "Ledger Atlas is locked."
    }
  }

  /// One line per summary fact, or none.
  public var summaryLines: [String] {
    guard let summary else { return [] }
    let entries =
      summary.entriesThisMonth == 1 ? "1 entry this month" : "\(summary.entriesThisMonth) entries this month"
    let budgets: String? =
      switch summary.budgets {
      case .none: nil
      case .onTrack: "Budgets on track"
      case .nearLimit: "A budget is near its limit"
      case .over: "A budget is over"
      }
    return [entries] + [budgets].compactMap { $0 }
  }

  public var accessibilityLabel: String {
    (["Ledger Atlas. \(message)"] + summaryLines.map { "\($0)." }).joined(separator: " ")
  }

  public static let empty = Self(state: .empty)
  public static let permissionDenied = Self(state: .permissionDenied)
  public static let reopenRequired = Self(state: .reopenRequired)
  public static let locked = Self(state: .locked)
}

public struct RedactedWidgetProjectionStore: Sendable {
  public static let appGroupIdentifier = "group.com.praxstack.ledgeratlas"
  public static let filename = "widget-projection-v1.json"

  public let url: URL

  public init(containerURL: URL) {
    url = containerURL.appendingPathComponent(Self.filename, isDirectory: false)
  }

  /// The app's read. A missing, damaged or unexpected file is replaced with `.empty`.
  public func read() -> RedactedWidgetProjection {
    guard let projection = readWithoutRepair() else {
      try? write(.empty)
      return .empty
    }
    return projection
  }

  /// The widget's read. It never writes; anything unreadable shows as `.reopenRequired`.
  public func readOnly() -> RedactedWidgetProjection {
    readWithoutRepair() ?? .reopenRequired
  }

  private func readWithoutRepair() -> RedactedWidgetProjection? {
    guard let data = try? Data(contentsOf: url), data.count <= 4096 else { return nil }
    return try? JSONDecoder().decode(RedactedWidgetProjection.self, from: data)
  }

  public func write(_ projection: RedactedWidgetProjection) throws {
    precondition(projection.schemaVersion == RedactedWidgetProjection.currentSchemaVersion)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(projection)
    try data.write(to: url, options: .atomic)
  }
}

public struct RedactedWidgetProjectionPublisher: Sendable {
  private let write: @Sendable (RedactedWidgetProjection) throws -> Void

  /// Writes to the shared store and asks the widget to redraw.
  public init(store: RedactedWidgetProjectionStore) {
    write = { projection in
      try store.write(projection)
      #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
      #endif
    }
  }

  public init(write: @escaping @Sendable (RedactedWidgetProjection) throws -> Void) {
    self.write = write
  }

  public func publish(_ state: RedactedWidgetProjection.State) throws {
    try write(.init(state: state))
  }

  public func publish(_ projection: RedactedWidgetProjection) throws {
    try write(projection)
  }
}
