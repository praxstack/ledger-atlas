import Foundation
import LedgerStore
import Observation

private final class SecurityScopeLease: @unchecked Sendable {
  private let lock = NSLock()
  private let url: URL
  private let stop: (URL) -> Void
  private var owners = 2

  init(url: URL, stop: @escaping (URL) -> Void) {
    self.url = url
    self.stop = stop
  }

  func release() {
    let shouldStop = lock.withLock {
      owners -= 1
      return owners == 0
    }
    if shouldStop { stop(url) }
  }
}

private final class SecurityScopeLeaseRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var leases: [Int: SecurityScopeLease] = [:]

  func insert(_ lease: SecurityScopeLease, for generation: Int) {
    lock.withLock { leases[generation] = lease }
  }

  func lease(for generation: Int) -> SecurityScopeLease? {
    lock.withLock { leases[generation] }
  }

  func release(for generation: Int) {
    lock.withLock { leases.removeValue(forKey: generation) }?.release()
  }

  func releaseAll() {
    let released = lock.withLock { () -> [SecurityScopeLease] in
      defer { leases.removeAll() }
      return Array(leases.values)
    }
    released.forEach { $0.release() }
  }
}

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
  private let startScope: (URL) -> Bool
  private let stopScope: (URL) -> Void
  private let scopedLeases = SecurityScopeLeaseRegistry()
  private var loadingGenerations: Set<Int> = []
  private var loads: [Int: Task<Void, Never>] = [:]

  package init(
    testingLoader: (@Sendable (URL) -> Presentation?)? = nil,
    testingScopeStarter: ((URL) -> Bool)? = nil,
    testingScopeStopper: ((URL) -> Void)? = nil
  ) {
    load =
      testingLoader ?? { url in
        guard let store = try? LedgerStore.openReadOnly(at: url) else { return nil }
        return try? Presentation(snapshot: store.readSnapshot())
      }
    startScope = testingScopeStarter ?? { $0.startAccessingSecurityScopedResource() }
    stopScope = testingScopeStopper ?? { $0.stopAccessingSecurityScopedResource() }
  }

  package var screen: Screen {
    switch state {
    case .noLedger: .noLedger
    case .loading: .loading
    case .loaded: .loaded
    case .unavailable: .unavailable
    }
  }

  @discardableResult
  package func open(_ url: URL, requiresSecurityScope: Bool = false) -> Bool {
    close()
    openGeneration &+= 1
    let generation = openGeneration
    state = .loading
    if requiresSecurityScope {
      guard startScope(url) else {
        state = .unavailable
        return false
      }
      scopedLeases.insert(SecurityScopeLease(url: url, stop: stopScope), for: generation)
    }
    let load = load
    let lease = scopedLeases.lease(for: generation)
    loadingGenerations.insert(generation)
    loads[generation] = Task.detached { [weak self, lease] in
      defer { lease?.release() }
      let presentation = load(url)
      await MainActor.run {
        self?.finishLoad(generation: generation, presentation: presentation)
      }
    }
    return true
  }

  package func close() {
    openGeneration &+= 1
    loads.values.forEach { $0.cancel() }
    releaseAllScopes()
    state = .noLedger
  }

  private func finishLoad(generation: Int, presentation: Presentation?) {
    loadingGenerations.remove(generation)
    loads[generation] = nil
    guard generation == openGeneration else {
      releaseScope(for: generation)
      return
    }
    state = presentation.map(State.loaded) ?? .unavailable
    if presentation == nil { releaseScope(for: generation) }
  }

  deinit {
    scopedLeases.releaseAll()
  }

  private func releaseAllScopes() {
    scopedLeases.releaseAll()
  }

  private func releaseScope(for generation: Int) {
    scopedLeases.release(for: generation)
  }
}
