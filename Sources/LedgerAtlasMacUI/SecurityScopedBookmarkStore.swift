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

  public enum ReopenOutcome: Equatable, Sendable {
    case missing
    case resolved(URL)
    case renewed(URL)
    case stale(URL)
    case denied(URL)
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
      },
      scopeStarter: { $0.startAccessingSecurityScopedResource() },
      scopeStopper: { $0.stopAccessingSecurityScopedResource() })
  }

  public convenience init(
    defaults: UserDefaults, key: String = "LedgerAtlas.selectedLedgerBookmark",
    makeBookmark: @escaping (URL) throws -> Data,
    resolveBookmark: @escaping (Data) throws -> URL
  ) {
    self.init(
      defaults: defaults, key: key, makeBookmark: makeBookmark,
      resolveBookmarkResult: { try .init(url: resolveBookmark($0), isStale: false) },
      scopeStarter: { $0.startAccessingSecurityScopedResource() },
      scopeStopper: { $0.stopAccessingSecurityScopedResource() })
  }

  public init(
    defaults: UserDefaults, key: String = "LedgerAtlas.selectedLedgerBookmark",
    makeBookmark: @escaping (URL) throws -> Data,
    resolveBookmarkResult: @escaping (Data) throws -> ResolvedBookmark,
    scopeStarter: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
    scopeStopper: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
  ) {
    self.defaults = defaults
    keyPrefix = key
    self.makeBookmark = makeBookmark
    resolveBookmark = resolveBookmarkResult
    _ = scopeStarter
    _ = scopeStopper
  }

  public func save(_ url: URL) throws { try save(url, for: .canonicalLedger) }

  public func save(_ url: URL, for purpose: Purpose) throws {
    defaults.set(try makeBookmark(url), forKey: key(for: purpose))
  }

  public func reopenURL() -> URL? {
    switch reopen(.canonicalLedger) {
    case .resolved(let url), .renewed(let url): url
    case .missing, .stale, .denied, .corrupt: nil
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
