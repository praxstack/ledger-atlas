import Foundation
import LedgerCore

/// #169: what to pre-fill in the income or expense form when the memo typed matches the memo of
/// an earlier entry. Only a suggestion: the form shows where it came from and nothing is saved
/// until the person saves.
public struct LedgerEntrySuggestion: Equatable, Sendable {
  /// The account and category of the matching entry, each only while it can still be chosen.
  public let accountID: String?
  public let categoryID: String?
  /// The local day of the entry the suggestion comes from, for "from 12 Oct".
  public let fromDay: SourceLocalDate
  public let sourceTransactionID: String

  public init(
    accountID: String?, categoryID: String?, fromDay: SourceLocalDate, sourceTransactionID: String
  ) {
    self.accountID = accountID
    self.categoryID = categoryID
    self.fromDay = fromDay
    self.sourceTransactionID = sourceTransactionID
  }

  /// A memo compared without case and with runs of whitespace treated as one space, so
  /// "  Chai  at office" matches "chai at Office".
  public static func normalizedMemo(_ memo: String) -> String {
    memo.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
  }

  /// The most recent live entry of `kind` whose memo matches `memo`, from the open ledger.
  /// Uses the same matcher the Search screen runs (kind, live entries only), then compares the
  /// whole memo. Nil when nothing matches, the memo is blank, or the match left nothing that
  /// can still be chosen (its account and category are both closed or hidden).
  public static func suggestion(
    forMemo memo: String, kind: LedgerTransactionKind, accounts: [LedgerAccount],
    categories: [LedgerCategory], transactions: [LedgerTransactionSnapshot]
  ) -> LedgerEntrySuggestion? {
    let wanted = normalizedMemo(memo)
    guard !wanted.isEmpty, kind == .income || kind == .expense else { return nil }
    var query = LedgerSearchQuery()
    query.kind = kind
    query.lifecycle = .active
    let accountsByID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var best: LedgerTransactionSnapshot?
    for candidate in transactions {
      // Cheap checks first: most entries have no note or a different one.
      guard let note = candidate.currentRevision.draft.note, note.count >= wanted.count,
        normalizedMemo(note) == wanted,
        LedgerApplication.matches(candidate, accounts: accountsByID, query: query)
      else { continue }
      if let current = best, !isMoreRecent(candidate, than: current) { continue }
      best = candidate
    }
    guard let best else { return nil }
    let draft = best.currentRevision.draft
    let accountID = draft.effects.first.map(\.accountID).flatMap { id in
      accountsByID[id].map { $0.lifecycle == .active } == true ? id : nil
    }
    let categoryID = draft.categoryID.flatMap { id in
      categories.contains {
        $0.id == id && $0.lifecycle == .active && !$0.hidden && $0.kind.accepts(kind)
      } ? id : nil
    }
    guard accountID != nil || categoryID != nil else { return nil }
    return LedgerEntrySuggestion(
      accountID: accountID, categoryID: categoryID, fromDay: draft.occurredAt.localDateTime.date,
      sourceTransactionID: best.id)
  }

  private static func isMoreRecent(
    _ candidate: LedgerTransactionSnapshot, than current: LedgerTransactionSnapshot
  ) -> Bool {
    let a = candidate.currentRevision, b = current.currentRevision
    if a.draft.occurredAt.instant != b.draft.occurredAt.instant {
      return a.draft.occurredAt.instant > b.draft.occurredAt.instant
    }
    if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
    return candidate.id > current.id
  }
}
