import Foundation
import LedgerCore
import LedgerStore

/// Coordinates Import Review approval with the session that presents the ledger.
@MainActor
enum LedgerShell {
  static func approve(_ journey: LedgerJourney, into session: LedgerSession) throws {
    try journey.approvePreparedImport()
    guard let url = journey.ledgerURL else { throw LedgerApplication.Error.invalidCommand }
    session.open(url)
  }

  static func beginEditing(_ journey: LedgerJourney) throws {
    guard let url = journey.ledgerURL else { throw LedgerApplication.Error.invalidCommand }
    try journey.beginEditing(url)
  }
}
