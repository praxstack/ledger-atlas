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

  public init(
    id: String = UUID().uuidString, kind: Kind, amountLiteral: String? = nil, note: String? = nil
  ) {
    self.id = id
    self.kind = kind
    self.amountLiteral = amountLiteral
    self.note = note
  }
}

public enum LedgerIntentBridge {
  public static let didEnqueueNotification = Notification.Name(
    "LedgerAtlas.intentBridge.didEnqueue")
  private static let key = "ledger-atlas.pending-intent.v1"
  private static var defaults: UserDefaults? {
    UserDefaults(suiteName: RedactedWidgetProjectionStore.appGroupIdentifier)
  }

  public static func enqueue(_ request: LedgerIntentRequest) throws {
    guard let defaults, let data = try? JSONEncoder().encode(request) else {
      throw LedgerIntentError.unavailable
    }
    guard defaults.data(forKey: key) == nil else { throw LedgerIntentError.alreadyPending }
    defaults.set(data, forKey: key)
    NotificationCenter.default.post(name: didEnqueueNotification, object: nil)
  }

  @MainActor
  public static func consume() -> LedgerIntentRequest? {
    guard let defaults, let data = defaults.data(forKey: key),
      let request = try? JSONDecoder().decode(LedgerIntentRequest.self, from: data)
    else { return nil }
    defaults.removeObject(forKey: key)
    return request
  }
}

public enum LedgerIntentError: Error, Equatable, Sendable {
  case unavailable
  case alreadyPending
}
