import Foundation
import LedgerCore
import LedgerStore

/// Coordinates Import Review approval with the session that presents the ledger.
@MainActor
enum LedgerShell {
  static func approve(_ journey: LedgerJourney, into session: LedgerSession) throws {
    try journey.approvePreparedImport()
    guard let url = journey.ledgerURL, let snapshot = journey.snapshot else {
      throw LedgerApplication.Error.invalidCommand
    }
    // Present the snapshot the journey just read instead of loading the ledger again in the
    // background. A second load could hold a read lock while the first save runs (#143).
    session.openValidated(url, snapshot: snapshot)
  }

  static func beginEditing(_ journey: LedgerJourney) throws {
    guard let url = journey.ledgerURL else { throw LedgerApplication.Error.invalidCommand }
    try journey.beginEditing(url)
  }
}
