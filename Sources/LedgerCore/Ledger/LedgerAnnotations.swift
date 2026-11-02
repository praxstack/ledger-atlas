import Foundation

/// Tags, transaction templates and standalone memos: the canonical homes for content that
/// labels or repeats transactions without being money movement itself.
///
/// These are value types only. Storage, uniqueness across a ledger and lifecycle commands live
/// in the store; the rules here are the ones every caller must agree on.
public enum LedgerAnnotationError: Error, Equatable, Sendable {
  case invalidIdentifier
  case invalidName
  case invalidBody
  case invalidTemplate
  case duplicateActiveTagName
  case tombstoned
}

public struct LedgerTag: Equatable, Sendable {
  public static let maximumNameBytes = 64

  public let id: String
  public let name: String
  public let origin: LedgerOrigin
  public let lifecycle: LedgerLifecycleState

  public init(
    id: String, name: String, origin: LedgerOrigin, lifecycle: LedgerLifecycleState = .active
  ) throws {
    guard CanonicalIdentifier.isValid(id) else { throw LedgerAnnotationError.invalidIdentifier }
    guard Self.isValidName(name) else { throw LedgerAnnotationError.invalidName }
    self.id = id
    self.name = name
    self.origin = origin
    self.lifecycle = lifecycle
  }

  /// The comparison key for "same name". Two active tags may not share it.
  ///
  /// Canonical composition first, so "é" typed two ways is one name; then a locale-independent
  /// case fold, so the answer never depends on the Mac's language setting.
  public var nameKey: String { Self.nameKey(name) }

  public static func nameKey(_ name: String) -> String {
    name.precomposedStringWithCanonicalMapping.lowercased()
  }

  /// A name is nonempty, bounded, free of control characters, and has no outer whitespace, so
  /// "food" and "food " cannot become two tags that look identical in a list.
  public static func isValidName(_ name: String) -> Bool {
    LedgerValidation.text(name, maximum: maximumNameBytes)
      && name == name.trimmingCharacters(in: .whitespacesAndNewlines)
      && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
  }

  /// Fails when two active tags share a name key. Tombstoned tags never block a name, so a
  /// retired name can be reused.
  public static func validateActiveNamesAreUnique(_ tags: [LedgerTag]) throws {
    var seen = Set<String>()
    for tag in tags where tag.lifecycle == .active {
      guard seen.insert(tag.nameKey).inserted else {
        throw LedgerAnnotationError.duplicateActiveTagName
      }
    }
  }
}

/// The tag identifiers attached to one transaction revision or template.
///
/// Links point at identifiers, never at names, so renaming a tag changes no stored history.
/// The set is kept sorted so equal sets compare and serialize identically.
public struct LedgerTagLinks: Equatable, Hashable, Sendable {
  public static let maximumCount = 64

  public let tagIDs: [String]

  public init(_ tagIDs: [String] = []) throws {
    guard tagIDs.count <= Self.maximumCount, tagIDs.allSatisfy(CanonicalIdentifier.isValid),
      Set(tagIDs).count == tagIDs.count
    else { throw LedgerAnnotationError.invalidIdentifier }
    self.tagIDs = tagIDs.sorted()
  }

  public var isEmpty: Bool { tagIDs.isEmpty }

  /// A correction keeps the labels of the revision it replaces unless the caller says otherwise.
  public func carriedForward(replacing replacement: LedgerTagLinks?) -> LedgerTagLinks {
    replacement ?? self
  }

  /// New links may only point at active tags. Links that already exist on history stay valid
  /// after their tag is tombstoned, which is why this check runs only on new links.
  public func validateNewLinks(
    previous: LedgerTagLinks = .empty, tags: [String: LedgerTag]
  ) throws {
    let previousIDs = Set(previous.tagIDs)
    for id in tagIDs where !previousIDs.contains(id) {
      guard let tag = tags[id] else { throw LedgerAnnotationError.invalidIdentifier }
      guard tag.lifecycle == .active else { throw LedgerAnnotationError.tombstoned }
    }
  }

  public static let empty = LedgerTagLinks(validatedSorted: [])

  private init(validatedSorted tagIDs: [String]) { self.tagIDs = tagIDs }
}

/// A saved transaction shape that a person turns into a new draft on purpose.
///
/// Instantiation copies values into an ordinary ``LedgerTransactionDraft``; nothing is created
/// implicitly, and editing a template never touches transactions made from it earlier.
public struct LedgerTransactionTemplate: Equatable, Sendable {
  public static let maximumNameBytes = 256

  public let id: String
  public let name: String
  public let kind: LedgerTransactionKind
  public let categoryID: String?
  /// Exact decimal text with an explicit currency unit. Never binary floating point.
  public let amount: CurrencyAmount
  public let note: String?
  /// For income and expense: the single account. For transfers: the account money leaves.
  public let accountID: String
  /// For transfers only: the account money arrives in.
  public let counterAccountID: String?
  public let tags: LedgerTagLinks
  public let origin: LedgerOrigin
  public let lifecycle: LedgerLifecycleState

  public init(
    id: String, name: String, kind: LedgerTransactionKind, categoryID: String?,
    amount: CurrencyAmount, note: String? = nil, accountID: String,
    counterAccountID: String? = nil, tags: LedgerTagLinks = .empty, origin: LedgerOrigin,
    lifecycle: LedgerLifecycleState = .active
  ) throws {
    guard CanonicalIdentifier.isValid(id), CanonicalIdentifier.isValid(accountID),
      categoryID.map(CanonicalIdentifier.isValid) != false,
      counterAccountID.map(CanonicalIdentifier.isValid) != false
    else { throw LedgerAnnotationError.invalidIdentifier }
    guard LedgerValidation.text(name, maximum: Self.maximumNameBytes) else {
      throw LedgerAnnotationError.invalidName
    }
    guard note.map({ LedgerValidation.text($0, maximum: 4_096) }) != false,
      amount.amount > (try ExactDecimal("0")),
      Self.hasValidShape(
        kind: kind, categoryID: categoryID, accountID: accountID,
        counterAccountID: counterAccountID)
    else { throw LedgerAnnotationError.invalidTemplate }
    self.id = id
    self.name = name
    self.kind = kind
    self.categoryID = categoryID
    self.amount = amount
    self.note = note
    self.accountID = accountID
    self.counterAccountID = counterAccountID
    self.tags = tags
    self.origin = origin
    self.lifecycle = lifecycle
  }

  /// Captures a recorded transaction as a template. The transaction itself is not changed.
  public init(
    capturing draft: LedgerTransactionDraft, tags: LedgerTagLinks, id: String, name: String,
    origin: LedgerOrigin
  ) throws {
    let shape = try Self.shape(of: draft)
    try self.init(
      id: id, name: name, kind: draft.kind, categoryID: draft.categoryID, amount: shape.amount,
      note: draft.note, accountID: shape.accountID, counterAccountID: shape.counterAccountID,
      tags: tags, origin: origin)
  }

  /// Builds an editable draft. The caller shows it to the person and commits it only through
  /// the standard create-transaction command.
  public func instantiate(occurredAt: SourceTemporal, origin: LedgerOrigin) throws
    -> LedgerTransactionDraft
  {
    guard lifecycle == .active else { throw LedgerAnnotationError.tombstoned }
    let effects: [LedgerTransactionEffect]
    switch kind {
    case .income:
      effects = [try .init(accountID: accountID, direction: .increase, amount: amount)]
    case .expense:
      effects = [try .init(accountID: accountID, direction: .decrease, amount: amount)]
    case .transfer:
      guard let counterAccountID else { throw LedgerAnnotationError.invalidTemplate }
      effects = [
        try .init(accountID: accountID, direction: .decrease, amount: amount),
        try .init(accountID: counterAccountID, direction: .increase, amount: amount),
      ]
    case .adjustment:
      throw LedgerAnnotationError.invalidTemplate
    }
    return try LedgerTransactionDraft(
      effects: effects, categoryID: categoryID, kind: kind, occurredAt: occurredAt, note: note,
      origin: origin)
  }

  public func renamed(_ name: String) throws -> LedgerTransactionTemplate {
    try edited(name: name)
  }

  public func tombstoned() throws -> LedgerTransactionTemplate {
    try edited(lifecycle: .tombstoned)
  }

  /// Returns a copy with the given fields replaced. Earlier transactions are unaffected because
  /// they were copied out of the template, not linked to it.
  public func edited(
    name: String? = nil, categoryID: String?? = nil, amount: CurrencyAmount? = nil,
    note: String?? = nil, tags: LedgerTagLinks? = nil, lifecycle: LedgerLifecycleState? = nil
  ) throws -> LedgerTransactionTemplate {
    guard self.lifecycle == .active else { throw LedgerAnnotationError.tombstoned }
    return try LedgerTransactionTemplate(
      id: id, name: name ?? self.name, kind: kind, categoryID: categoryID ?? self.categoryID,
      amount: amount ?? self.amount, note: note ?? self.note, accountID: accountID,
      counterAccountID: counterAccountID, tags: tags ?? self.tags, origin: origin,
      lifecycle: lifecycle ?? self.lifecycle)
  }

  private static func hasValidShape(
    kind: LedgerTransactionKind, categoryID: String?, accountID: String,
    counterAccountID: String?
  ) -> Bool {
    switch kind {
    case .income, .expense: counterAccountID == nil
    case .transfer:
      categoryID == nil && counterAccountID != nil && counterAccountID != accountID
    case .adjustment: false
    }
  }

  private static func shape(of draft: LedgerTransactionDraft) throws -> (
    amount: CurrencyAmount, accountID: String, counterAccountID: String?
  ) {
    switch draft.kind {
    case .income, .expense:
      guard let effect = draft.effects.first, draft.effects.count == 1 else {
        throw LedgerAnnotationError.invalidTemplate
      }
      return (effect.amount, effect.accountID, nil)
    case .transfer:
      guard let from = draft.effects.first(where: { $0.direction == .decrease }),
        let to = draft.effects.first(where: { $0.direction == .increase }),
        from.amount == to.amount
      else { throw LedgerAnnotationError.invalidTemplate }
      return (from.amount, from.accountID, to.accountID)
    case .adjustment:
      throw LedgerAnnotationError.invalidTemplate
    }
  }
}

/// A note that belongs to a day, not to a transaction. Notes on a transaction stay on the
/// revision's own note field; the two never share an identity.
public struct LedgerMemo: Equatable, Sendable {
  public static let maximumBodyBytes = 16_384

  public let id: String
  public let body: String
  public let date: SourceLocalDate
  public let origin: LedgerOrigin
  public let lifecycle: LedgerLifecycleState

  public init(
    id: String, body: String, date: SourceLocalDate, origin: LedgerOrigin,
    lifecycle: LedgerLifecycleState = .active
  ) throws {
    guard CanonicalIdentifier.isValid(id) else { throw LedgerAnnotationError.invalidIdentifier }
    guard LedgerValidation.text(body, maximum: Self.maximumBodyBytes),
      !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw LedgerAnnotationError.invalidBody }
    self.id = id
    self.body = body
    self.date = date
    self.origin = origin
    self.lifecycle = lifecycle
  }

  public func edited(body: String? = nil, date: SourceLocalDate? = nil) throws -> LedgerMemo {
    guard lifecycle == .active else { throw LedgerAnnotationError.tombstoned }
    return try LedgerMemo(
      id: id, body: body ?? self.body, date: date ?? self.date, origin: origin)
  }

  public func tombstoned() throws -> LedgerMemo {
    guard lifecycle == .active else { throw LedgerAnnotationError.tombstoned }
    return try LedgerMemo(id: id, body: body, date: date, origin: origin, lifecycle: .tombstoned)
  }
}

extension LedgerTag {
  public func renamed(_ name: String) throws -> LedgerTag {
    guard lifecycle == .active else { throw LedgerAnnotationError.tombstoned }
    return try LedgerTag(id: id, name: name, origin: origin)
  }

  public func tombstoned() throws -> LedgerTag {
    guard lifecycle == .active else { throw LedgerAnnotationError.tombstoned }
    return try LedgerTag(id: id, name: name, origin: origin, lifecycle: .tombstoned)
  }
}
