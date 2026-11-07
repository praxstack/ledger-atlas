import Foundation

public struct LedgerIntentRequest: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case addExpense
    case addIncome
    case addTransfer
    case createBackup
    case openBudgets
  }

  public let id: String
  public let kind: Kind
  public let amountLiteral: String?
  public let note: String?
  /// When the request was queued. Requests from builds without it count as expired.
  public let createdAtMilliseconds: Int64
  /// The entry form opens with Upcoming beside it (#171): the daily reminder asks for this.
  public let showsUpcoming: Bool

  public init(
    id: String = UUID().uuidString, kind: Kind, amountLiteral: String? = nil, note: String? = nil,
    createdAtMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
    showsUpcoming: Bool = false
  ) {
    self.id = id
    self.kind = kind
    self.amountLiteral = amountLiteral
    self.note = note
    self.createdAtMilliseconds = createdAtMilliseconds
    self.showsUpcoming = showsUpcoming
  }

  private enum CodingKeys: String, CodingKey {
    case id, kind, amountLiteral, note, createdAtMilliseconds, showsUpcoming
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    kind = try values.decode(Kind.self, forKey: .kind)
    amountLiteral = try values.decodeIfPresent(String.self, forKey: .amountLiteral)
    note = try values.decodeIfPresent(String.self, forKey: .note)
    createdAtMilliseconds =
      try values.decodeIfPresent(Int64.self, forKey: .createdAtMilliseconds) ?? 0
    showsUpcoming = try values.decodeIfPresent(Bool.self, forKey: .showsUpcoming) ?? false
  }

  /// A request older than this is dropped instead of acted on, so a request the app never got
  /// to (locked, quit, no ledger) can't jam the queue or surprise the person later.
  public static let lifetimeMilliseconds: Int64 = 10 * 60 * 1000

  public func isExpired(atMilliseconds now: Int64) -> Bool {
    now - createdAtMilliseconds > Self.lifetimeMilliseconds || createdAtMilliseconds > now + 60_000
  }
}

public enum LedgerIntentBridge {
  public static let didEnqueueNotification = Notification.Name(
    "LedgerAtlas.intentBridge.didEnqueue")
  package static let key = "ledger-atlas.pending-intent.v1"
  private static var defaults: UserDefaults? {
    UserDefaults(suiteName: RedactedWidgetProjectionStore.appGroupIdentifier)
  }

  package static func nowMilliseconds() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

  /// Queues one request. A queued request that is still fresh is never overwritten; one that
  /// is expired or unreadable is replaced.
  public static func enqueue(_ request: LedgerIntentRequest) throws {
    try enqueue(request, in: defaults, now: nowMilliseconds())
    NotificationCenter.default.post(name: didEnqueueNotification, object: nil)
  }

  package static func enqueue(
    _ request: LedgerIntentRequest, in defaults: UserDefaults?, now: Int64
  ) throws {
    guard let defaults, let data = try? JSONEncoder().encode(request) else {
      throw LedgerIntentError.unavailable
    }
    if let existing = defaults.data(forKey: key) {
      if let queued = try? JSONDecoder().decode(LedgerIntentRequest.self, from: existing),
        !queued.isExpired(atMilliseconds: now)
      {
        throw LedgerIntentError.alreadyPending
      }
      defaults.removeObject(forKey: key)
    }
    defaults.set(data, forKey: key)
  }

  /// Takes the queued request. Unreadable or expired requests are cleared and never returned.
  @MainActor
  public static func consume() -> LedgerIntentRequest? {
    consume(from: defaults, now: nowMilliseconds())
  }

  package static func consume(from defaults: UserDefaults?, now: Int64) -> LedgerIntentRequest? {
    guard let defaults, let data = defaults.data(forKey: key) else { return nil }
    defaults.removeObject(forKey: key)
    guard let request = try? JSONDecoder().decode(LedgerIntentRequest.self, from: data),
      !request.isExpired(atMilliseconds: now)
    else { return nil }
    return request
  }
}

public enum LedgerIntentError: Error, Equatable, Sendable {
  case unavailable
  case alreadyPending
}
