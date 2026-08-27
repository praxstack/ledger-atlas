import Foundation

public final class SecurityScopedBookmarkStore {
  public static let defaultKey = "LedgerAtlas.selectedLedgerBookmark"

  private let defaults: UserDefaults
  private let key: String
  private let makeBookmark: (URL) throws -> Data
  private let resolveBookmark: (Data) throws -> URL

  public convenience init() {
    self.init(
      defaults: .standard,
      makeBookmark: { url in
        try url.bookmarkData(
          options: .withSecurityScope, includingResourceValuesForKeys: nil,
          relativeTo: nil)
      },
      resolveBookmark: { data in
        var stale = false
        return try URL(
          resolvingBookmarkData: data, options: .withSecurityScope,
          relativeTo: nil, bookmarkDataIsStale: &stale)
      })
  }

  public init(
    defaults: UserDefaults, key: String = "LedgerAtlas.selectedLedgerBookmark",
    makeBookmark: @escaping (URL) throws -> Data,
    resolveBookmark: @escaping (Data) throws -> URL
  ) {
    self.defaults = defaults
    self.key = key
    self.makeBookmark = makeBookmark
    self.resolveBookmark = resolveBookmark
  }

  public func save(_ url: URL) throws {
    defaults.set(try makeBookmark(url), forKey: key)
  }

  public func reopenURL() -> URL? {
    guard let data = defaults.data(forKey: key) else { return nil }
    return try? resolveBookmark(data)
  }

  public func clear() {
    defaults.removeObject(forKey: key)
  }
}
