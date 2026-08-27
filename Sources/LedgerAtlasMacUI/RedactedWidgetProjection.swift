import Foundation

public struct RedactedWidgetProjection: Codable, Equatable, Sendable {
  public enum State: String, Codable, Sendable {
    case empty
    case permissionDenied
    case ready
    case reopenRequired
  }

  public let schemaVersion: Int
  public let state: State

  public init(state: State) {
    schemaVersion = 1
    self.state = state
  }

  private enum CodingKeys: String, CodingKey { case schemaVersion, state }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
    guard schemaVersion == 1 else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion, in: values, debugDescription: "Unsupported widget projection.")
    }
    self.schemaVersion = schemaVersion
    state = try values.decode(State.self, forKey: .state)
  }

  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(schemaVersion, forKey: .schemaVersion)
    try values.encode(state, forKey: .state)
  }

  public var message: String {
    switch state {
    case .empty: "Open Ledger Atlas to get started."
    case .permissionDenied: "Allow access in Ledger Atlas to continue."
    case .ready: "Ledger Atlas is ready."
    case .reopenRequired: "Open Ledger Atlas to continue."
    }
  }

  public static let empty = Self(state: .empty)
  public static let permissionDenied = Self(state: .permissionDenied)
  public static let reopenRequired = Self(state: .reopenRequired)
}

public struct RedactedWidgetProjectionStore: Sendable {
  public static let appGroupIdentifier = "group.com.praxstack.ledgeratlas"
  public static let filename = "widget-projection-v1.json"

  public let url: URL

  public init(containerURL: URL) {
    url = containerURL.appendingPathComponent(Self.filename, isDirectory: false)
  }

  public func read() -> RedactedWidgetProjection {
    guard
      let data = try? Data(contentsOf: url),
      let projection = try? JSONDecoder().decode(RedactedWidgetProjection.self, from: data),
      projection.schemaVersion == 1
    else { return .empty }
    return projection
  }

  public func write(_ projection: RedactedWidgetProjection) throws {
    precondition(projection.schemaVersion == 1)
    let data = try JSONEncoder().encode(projection)
    try data.write(to: url, options: .atomic)
  }
}
