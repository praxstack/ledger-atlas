import Foundation

public final class SecurityScopedBookmarkStore {
  public enum Purpose: String, Sendable { case canonicalLedger, importSource }

  public struct ResolvedBookmark: Sendable {
    public let url: URL
    public let isStale: Bool

    public init(url: URL, isStale: Bool) {
      self.url = url
      self.isStale = isStale
    }
  }

  /// What a saved bookmark resolves to.
  ///
  /// A stale bookmark still points at the ledger, but macOS wants it re-created. The store does
  /// not rewrite it here: the caller opens and validates the ledger first, then calls ``save(_:)``
  /// while it holds the security scope, which renews the bookmark (LA-031). A ledger that fails
  /// to open keeps its original bookmark.
  public enum ReopenOutcome: Equatable, Sendable {
    case missing
    case resolved(URL)
    case stale(URL)
    case corrupt
  }

  public static let defaultKey = "LedgerAtlas.selectedLedgerBookmark"

  private let defaults: UserDefaults
  private let keyPrefix: String
  private let makeBookmark: (URL) throws -> Data
  private let resolveBookmark: (Data) throws -> ResolvedBookmark

  public convenience init() {
    self.init(
      defaults: .standard,
      makeBookmark: { url in
        try url.bookmarkData(
          options: .withSecurityScope, includingResourceValuesForKeys: nil,
          relativeTo: nil)
      },
      resolveBookmarkResult: { data in
        var stale = false
        let url = try URL(
          resolvingBookmarkData: data, options: .withSecurityScope,
          relativeTo: nil, bookmarkDataIsStale: &stale)
        return .init(url: url, isStale: stale)
      })
  }

  public convenience init(
    defaults: UserDefaults, key: String = "LedgerAtlas.selectedLedgerBookmark",
    makeBookmark: @escaping (URL) throws -> Data,
    resolveBookmark: @escaping (Data) throws -> URL
  ) {
    self.init(
      defaults: defaults, key: key, makeBookmark: makeBookmark,
      resolveBookmarkResult: { try .init(url: resolveBookmark($0), isStale: false) })
  }

  public init(
    defaults: UserDefaults, key: String = "LedgerAtlas.selectedLedgerBookmark",
    makeBookmark: @escaping (URL) throws -> Data,
    resolveBookmarkResult: @escaping (Data) throws -> ResolvedBookmark
  ) {
    self.defaults = defaults
    keyPrefix = key
    self.makeBookmark = makeBookmark
    resolveBookmark = resolveBookmarkResult
  }

  public func save(_ url: URL) throws { try save(url, for: .canonicalLedger) }

  public func save(_ url: URL, for purpose: Purpose) throws {
    defaults.set(try makeBookmark(url), forKey: key(for: purpose))
  }

  public func reopenURL() -> URL? {
    switch reopen(.canonicalLedger) {
    case .resolved(let url): url
    case .missing, .stale, .corrupt: nil
    }
  }

  public func reopen(_ purpose: Purpose) -> ReopenOutcome {
    let key = key(for: purpose)
    guard let data = defaults.data(forKey: key) else { return .missing }
    guard let resolution = try? resolveBookmark(data) else {
      return .corrupt
    }
    guard resolution.isStale else { return .resolved(resolution.url) }
    return .stale(resolution.url)
  }

  public func clear(_ purpose: Purpose = .canonicalLedger) {
    defaults.removeObject(forKey: key(for: purpose))
  }

  private func key(for purpose: Purpose) -> String {
    "\(keyPrefix).\(purpose.rawValue)"
  }
}
