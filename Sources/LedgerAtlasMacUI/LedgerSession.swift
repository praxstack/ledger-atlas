import Foundation
import LedgerStore
import Observation

@MainActor
@Observable
package final class LedgerSession {
  package enum Screen: Equatable { case noLedger, loading, loaded, unavailable }

  package struct Presentation: Sendable {
    struct Account: Identifiable, Sendable {
      let id: String
      let name: String
      let detail: String
    }

    struct Transaction: Identifiable, Sendable {
      let id: String
      let title: String
      let detail: String
    }

    let accounts: [Account]
    let transactions: [Transaction]
    let undisplayedImportedEventCount: Int

    package init(snapshot: LedgerStore.LedgerReadSnapshot) {
      accounts = snapshot.accounts.map {
        .init(
          id: $0.id, name: $0.name,
          detail: "\($0.currencyUnit) · \($0.lifecycle.rawValue.capitalized)")
      }
      transactions = snapshot.transactions.map {
        let date = $0.currentRevision.draft.occurredAt.localDateTime.date
        let effect = $0.currentRevision.draft.effects[0]
        let tombstone = $0.currentRevision.lifecycle == .tombstoned
        return Transaction(
          id: $0.id,
          title: tombstone
            ? "Tombstoned \($0.currentRevision.draft.kind.rawValue.capitalized)"
            : $0.currentRevision.draft.kind.rawValue.capitalized,
          detail:
            "\(String(format: "%04d-%02d-%02d", date.year, date.month, date.day)) · \(effect.amount.amount.rawLiteral) \(effect.amount.unitCode)"
        )
      }
      undisplayedImportedEventCount = snapshot.undisplayedImportedEventCount
    }
  }

  package enum State {
    case noLedger
    case loading
    case loaded(Presentation)
    case unavailable
  }

  package private(set) var state: State = .noLedger
  private var openGeneration = 0
  private let load: @Sendable (URL) -> Presentation?

  package init(testingLoader: (@Sendable (URL) -> Presentation?)? = nil) {
    load =
      testingLoader ?? { url in
        guard let store = try? LedgerStore.openReadOnly(at: url) else { return nil }
        return try? Presentation(snapshot: store.readSnapshot())
      }
  }

  package var screen: Screen {
    switch state {
    case .noLedger: .noLedger
    case .loading: .loading
    case .loaded: .loaded
    case .unavailable: .unavailable
    }
  }

  package func open(_ url: URL) {
    openGeneration &+= 1
    let generation = openGeneration
    state = .loading
    let securityScope = url.startAccessingSecurityScopedResource()
    let load = load
    Task.detached { [weak self] in
      defer {
        if securityScope { url.stopAccessingSecurityScopedResource() }
      }
      let presentation = load(url)
      await MainActor.run {
        guard self?.openGeneration == generation else { return }
        self?.state = presentation.map(State.loaded) ?? .unavailable
      }
    }
  }
}
