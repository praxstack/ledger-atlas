import CryptoKit
import Foundation

public enum LedgerDomainError: Error, Equatable, Sendable {
  case invalidIdentifier
  case invalidText
  case invalidReference
  case invalidRevision
  case invalidLink
  case invalidEffects
}

public enum LedgerLifecycleState: String, CaseIterable, Sendable {
  case active
  case tombstoned
}

public enum LedgerCategoryKind: String, CaseIterable, Sendable {
  case income
  case expense
  case neutral

  public func accepts(_ transactionKind: LedgerTransactionKind) -> Bool {
    switch (self, transactionKind) {
    case (.income, .income), (.expense, .expense), (.neutral, .adjustment): true
    default: false
    }
  }
}

public enum LedgerTransactionKind: String, CaseIterable, Sendable {
  case income
  case expense
  case transfer
  case adjustment
}

public enum LedgerEffectDirection: String, CaseIterable, Sendable {
  case increase
  case decrease
}

public enum LedgerTransactionLinkKind: String, CaseIterable, Sendable {
  case split
  case recurring
  case installment
  case related
}

public struct LedgerOrigin: Equatable, Hashable, Sendable {
  public let id: String
  public let label: String
  public let provenanceID: String?

  public init(id: String, label: String, provenanceID: String? = nil) throws {
    guard CanonicalIdentifier.isValid(id), LedgerValidation.text(label, maximum: 256),
      provenanceID.map(CanonicalIdentifier.isValid) != false
    else { throw LedgerDomainError.invalidText }
    self.id = id
    self.label = label
    self.provenanceID = provenanceID
  }

  public static let importedLabel = "imported"
  public static let macNativeLabel = "mac-native"

  public static func imported() throws -> LedgerOrigin {
    try LedgerOrigin(id: String(repeating: "e", count: 64), label: importedLabel)
  }

  public static func macNative() throws -> LedgerOrigin {
    try LedgerOrigin(id: String(repeating: "a", count: 64), label: macNativeLabel)
  }
}

public struct LedgerSourceLiteral: Equatable, Hashable, Sendable {
  public let field: String
  public let literal: String
  public let provenanceID: String?

  public init(field: String, literal: String, provenanceID: String? = nil) throws {
    guard LedgerValidation.text(field, maximum: 256),
      LedgerValidation.text(literal, maximum: 16_384),
      provenanceID.map(CanonicalIdentifier.isValid) != false
    else { throw LedgerDomainError.invalidText }
    self.field = field
    self.literal = literal
    self.provenanceID = provenanceID
  }
}

public struct LedgerAccount: Equatable, Sendable {
  public let id: String
  public let name: String
  public let currencyUnit: String
  public let origin: LedgerOrigin
  public let lifecycle: LedgerLifecycleState

  public init(
    id: String, name: String, currencyUnit: String, origin: LedgerOrigin,
    lifecycle: LedgerLifecycleState = .active
  ) throws {
    guard CanonicalIdentifier.isValid(id), LedgerValidation.text(name, maximum: 256),
      (try? CurrencyAmount(unitCode: currencyUnit, amount: ExactDecimal("0"))) != nil
    else { throw LedgerDomainError.invalidReference }
    self.id = id
    self.name = name
    self.currencyUnit = currencyUnit
    self.origin = origin
    self.lifecycle = lifecycle
  }
}

public struct LedgerCategory: Equatable, Sendable {
  public let id: String
  public let name: String
  public let kind: LedgerCategoryKind
  public let origin: LedgerOrigin
  public let lifecycle: LedgerLifecycleState

  public init(
    id: String, name: String, kind: LedgerCategoryKind, origin: LedgerOrigin,
    lifecycle: LedgerLifecycleState = .active
  ) throws {
    guard CanonicalIdentifier.isValid(id), LedgerValidation.text(name, maximum: 256) else {
      throw LedgerDomainError.invalidReference
    }
    self.id = id
    self.name = name
    self.kind = kind
    self.origin = origin
    self.lifecycle = lifecycle
  }
}

public struct LedgerTransactionEffect: Equatable, Sendable {
  public let accountID: String
  public let direction: LedgerEffectDirection
  public let amount: CurrencyAmount

  public init(accountID: String, direction: LedgerEffectDirection, amount: CurrencyAmount) throws {
    let zero = try ExactDecimal("0")
    guard CanonicalIdentifier.isValid(accountID), amount.amount > zero else {
      throw LedgerDomainError.invalidEffects
    }
    self.accountID = accountID
    self.direction = direction
    self.amount = amount
  }
}

public struct LedgerTransactionDraft: Equatable, Sendable {
  public let effects: [LedgerTransactionEffect]
  public let categoryID: String?
  public let kind: LedgerTransactionKind
  public let occurredAt: SourceTemporal
  public let note: String?
  public let roundingPolicy: RoundingPolicy?
  public let sourceLiterals: [LedgerSourceLiteral]
  public let origin: LedgerOrigin

  public init(
    effects: [LedgerTransactionEffect], categoryID: String?, kind: LedgerTransactionKind,
    occurredAt: SourceTemporal, note: String? = nil, roundingPolicy: RoundingPolicy? = nil,
    sourceLiterals: [LedgerSourceLiteral] = [], origin: LedgerOrigin
  ) throws {
    guard categoryID.map(CanonicalIdentifier.isValid) != false,
      note.map({ LedgerValidation.text($0, maximum: 4_096) }) != false,
      sourceLiterals.count <= 1_024,
      Set(sourceLiterals.map { "\($0.field)\u{0}\($0.provenanceID ?? "")" }).count
        == sourceLiterals.count
    else { throw LedgerDomainError.invalidReference }
    guard effects.count <= 64, !effects.isEmpty,
      Set(effects.map(\.accountID)).count == effects.count,
      Self.hasValidEffects(effects, kind: kind, categoryID: categoryID)
    else { throw LedgerDomainError.invalidEffects }
    self.effects = effects.sorted { $0.accountID < $1.accountID }
    self.categoryID = categoryID
    self.kind = kind
    self.occurredAt = occurredAt
    self.note = note
    self.roundingPolicy = roundingPolicy
    self.sourceLiterals = sourceLiterals.sorted { lhs, rhs in
      (lhs.field, lhs.provenanceID ?? "") < (rhs.field, rhs.provenanceID ?? "")
    }
    self.origin = origin
  }

  private static func hasValidEffects(
    _ effects: [LedgerTransactionEffect], kind: LedgerTransactionKind, categoryID: String?
  ) -> Bool {
    switch kind {
    case .income:
      return effects.count == 1 && effects[0].direction == .increase
    case .expense:
      return effects.count == 1 && effects[0].direction == .decrease
    case .adjustment:
      return effects.count == 1
    case .transfer:
      return effects.count == 2 && categoryID == nil
        && Set(effects.map(\.direction)) == [.increase, .decrease]
    }
  }
}

public struct LedgerTransactionRevision: Equatable, Sendable {
  public let id: String
  public let transactionID: String
  public let revision: Int
  public let predecessorID: String?
  public let draft: LedgerTransactionDraft
  public let lifecycle: LedgerLifecycleState
  public let createdAt: UTCInstant

  public init(
    id: String, transactionID: String, revision: Int, predecessorID: String?,
    draft: LedgerTransactionDraft, lifecycle: LedgerLifecycleState = .active, createdAt: UTCInstant
  ) throws {
    guard id == (try? StableLedgerID.revision(transactionID: transactionID, revision: revision)),
      CanonicalIdentifier.isValid(transactionID), revision > 0,
      predecessorID.map(CanonicalIdentifier.isValid) != false,
      (revision == 1) == (predecessorID == nil),
      revision == 1
        || predecessorID
          == (try? StableLedgerID.revision(
            transactionID: transactionID, revision: revision - 1))
    else { throw LedgerDomainError.invalidRevision }
    self.id = id
    self.transactionID = transactionID
    self.revision = revision
    self.predecessorID = predecessorID
    self.draft = draft
    self.lifecycle = lifecycle
    self.createdAt = createdAt
  }
}

public struct LedgerTransactionLink: Equatable, Sendable {
  public let id: String
  public let fromTransactionID: String
  public let toTransactionID: String
  public let kind: LedgerTransactionLinkKind

  public init(
    id: String, fromTransactionID: String, toTransactionID: String, kind: LedgerTransactionLinkKind
  ) throws {
    guard
      id
        == (try? StableLedgerID.link(
          fromTransactionID: fromTransactionID, toTransactionID: toTransactionID, kind: kind)),
      CanonicalIdentifier.isValid(fromTransactionID),
      CanonicalIdentifier.isValid(toTransactionID), fromTransactionID != toTransactionID
    else { throw LedgerDomainError.invalidLink }
    self.id = id
    self.fromTransactionID = fromTransactionID
    self.toTransactionID = toTransactionID
    self.kind = kind
  }
}

public struct LedgerTransactionSnapshot: Equatable, Sendable {
  public let id: String
  public let currentRevision: LedgerTransactionRevision
  public let links: [LedgerTransactionLink]

  public init(
    id: String, currentRevision: LedgerTransactionRevision, links: [LedgerTransactionLink] = []
  ) throws {
    guard CanonicalIdentifier.isValid(id), id == currentRevision.transactionID,
      links.allSatisfy({ $0.fromTransactionID == id || $0.toTransactionID == id }),
      Set(links.map(\.id)).count == links.count,
      Set(links.map { "\($0.fromTransactionID)\u{0}\($0.toTransactionID)\u{0}\($0.kind.rawValue)" })
        .count == links.count
    else { throw LedgerDomainError.invalidReference }
    self.id = id
    self.currentRevision = currentRevision
    self.links = links.sorted { $0.id < $1.id }
  }
}

public enum StableLedgerID {
  public static func account(origin: LedgerOrigin, localKey: String) throws -> String {
    guard CanonicalIdentifier.isValid(localKey) else { throw LedgerDomainError.invalidIdentifier }
    return digest(["ledger-atlas:v1:account", origin.id, localKey])
  }

  public static func category(origin: LedgerOrigin, localKey: String) throws -> String {
    guard CanonicalIdentifier.isValid(localKey) else { throw LedgerDomainError.invalidIdentifier }
    return digest(["ledger-atlas:v1:category", origin.id, localKey])
  }

  public static func transaction(origin: LedgerOrigin, localKey: String) throws -> String {
    guard CanonicalIdentifier.isValid(localKey) else { throw LedgerDomainError.invalidIdentifier }
    return digest(["ledger-atlas:v1:transaction", origin.id, localKey])
  }

  public static func revision(transactionID: String, revision: Int) throws -> String {
    guard CanonicalIdentifier.isValid(transactionID), revision > 0 else {
      throw LedgerDomainError.invalidRevision
    }
    return digest(["ledger-atlas:v1:revision", transactionID, String(revision)])
  }

  public static func link(
    fromTransactionID: String, toTransactionID: String, kind: LedgerTransactionLinkKind
  ) throws -> String {
    guard CanonicalIdentifier.isValid(fromTransactionID),
      CanonicalIdentifier.isValid(toTransactionID), fromTransactionID != toTransactionID
    else { throw LedgerDomainError.invalidLink }
    return digest(["ledger-atlas:v1:link", fromTransactionID, toTransactionID, kind.rawValue])
  }

  public static func recurrenceRule(origin: LedgerOrigin, localKey: String) throws -> String {
    guard CanonicalIdentifier.isValid(localKey) else { throw LedgerDomainError.invalidIdentifier }
    return digest(["ledger-atlas:v1:recurrence-rule", origin.id, localKey])
  }

  public static func budget(origin: LedgerOrigin, localKey: String) throws -> String {
    guard CanonicalIdentifier.isValid(localKey) else { throw LedgerDomainError.invalidIdentifier }
    return digest(["ledger-atlas:v1:budget", origin.id, localKey])
  }

  public static func installmentPlan(origin: LedgerOrigin, localKey: String) throws -> String {
    guard CanonicalIdentifier.isValid(localKey) else { throw LedgerDomainError.invalidIdentifier }
    return digest(["ledger-atlas:v1:installment-plan", origin.id, localKey])
  }

  private static func digest(_ components: [String]) -> String {
    var hasher = SHA256()
    for component in components {
      var length = UInt64(component.utf8.count).bigEndian
      withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
      hasher.update(data: Data(component.utf8))
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

private enum LedgerValidation {
  static func text(_ value: String, maximum: Int) -> Bool {
    !value.isEmpty && value.utf8.count <= maximum && !value.contains("\u{0}")
  }
}
