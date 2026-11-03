import Foundation

/// Where Ledger Atlas keeps its secrets: receipt trust keys and the app-lock passcode.
///
/// The free app is ad-hoc signed, so every update has a new signature. A Keychain item made by
/// one build makes macOS ask for the Mac password when the next build reads it. Private files
/// in the app's own storage never ask, so they are the default. Settings can switch to this
/// Mac's Keychain for people who prefer it and accept the prompt.
package enum LedgerSecretStorage: String, CaseIterable, Sendable {
  /// Owner-only files in the app's storage (`Application Support/Ledger Atlas`).
  case appFiles
  /// This Mac's login Keychain, never synced.
  case deviceKeychain

  private static let defaultsKey = "ledger-atlas.secret-storage.v1"

  /// The defaults that hold the choice. Replaceable for tests only.
  nonisolated(unsafe) package static var defaults: UserDefaults = .standard

  /// The chosen place. Nothing chosen means `appFiles`.
  package static var current: LedgerSecretStorage {
    defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .appFiles
  }

  /// Records the choice. Call it only after the secrets have moved there.
  package static func record(_ choice: LedgerSecretStorage) {
    defaults.set(choice.rawValue, forKey: defaultsKey)
  }
}
