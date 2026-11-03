import CSQLite
import CryptoKit
import Foundation
import LedgerCore
import Security

/// Holds the receipt authentication key outside the SQLite graph. The database stores only a
/// keyed digest, so replacing the SQLite graph cannot replace the trust root. New keys are stored
/// in synchronizable iCloud Keychain storage when the user has enabled it, allowing an authenticated
/// backup to recover on another Mac without trusting a key supplied by the SQLite file.
package enum LedgerReceiptTrust {
  package static let algorithm = "hmac-sha256"

  package static func key(
    for url: URL, create: Bool, stableIdentity: String? = nil
  ) throws -> Data? {
    let identity = persistedReceiptIdentity(at: url) ?? stableIdentity ?? "empty-ledger"
    let currentAccount = account(for: identity, namespace: currentNamespace)
    if let value = try read(account: currentAccount, synchronizable: true) { return value }
    if let fileValue = try LedgerReceiptKeyFile.read(
      account: currentAccount, in: keyDirectory())
    {
      return fileValue
    }
    if let localValue = try read(account: currentAccount, synchronizable: false) {
      // A current local-only key can only be accepted by the unsigned package-test fallback. A
      // signed production build must never publish a backup whose trust root cannot migrate.
      #if DEBUG
        return localValue
      #else
        throw LedgerReceiptTrustError.nonSynchronizableKey
      #endif
    }

    // Migrate keys created before the synchronizable namespace was introduced. The old item is
    // retained until the new item is durably present, so a Keychain failure cannot strand the
    // existing ledger. The new account is distinct, avoiding a duplicate-item race with the old
    // device-only record.
    let legacyAccount = account(for: identity, namespace: legacyNamespace)
    if let legacyValue = try read(account: legacyAccount, synchronizable: nil) {
      do { return try storeNew(legacyValue, account: currentAccount) } catch {
        #if DEBUG
          return legacyValue
        #else
          throw error
        #endif
      }
    }
    guard create else { return nil }

    var value = Data(count: 32)
    let randomStatus = value.withUnsafeMutableBytes {
      SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
    }
    guard randomStatus == errSecSuccess else {
      throw LedgerReceiptTrustError.keychain(randomStatus)
    }
    return try storeNew(value, account: currentAccount)
  }

  /// Where keys go when the Keychain can't hold them. Replaceable for tests only.
  nonisolated(unsafe) package static var keyDirectory: () throws -> URL =
    LedgerReceiptKeyFile.defaultDirectory

  /// Stores a new key in iCloud Keychain when the build may use it. The free ad-hoc signed app
  /// may not (errSecMissingEntitlement), so the key goes to a private file instead.
  private static func storeNew(_ value: Data, account: String) throws -> Data {
    do {
      return try store(value, account: account)
    } catch LedgerReceiptTrustError.keychain(let status) where status == errSecMissingEntitlement {
      return try LedgerReceiptKeyFile.store(value, account: account, in: keyDirectory())
    }
  }

  private static func account(for identity: String, namespace: String) -> String {
    CanonicalReceiptDigest.sha256(Data("ledger-atlas/receipt-key/\(namespace)\n\(identity)".utf8))
  }

  #if DEBUG
    /// Tests only, never in release builds: stores a known key for a receipt identity, so a
    /// committed package fixture signed with that key can be restored. Returns false when a
    /// different key already exists for the identity; nothing is replaced.
    package static func installKeyForTesting(_ key: Data, identity: String) throws -> Bool {
      try storeLocal(key, account: account(for: identity, namespace: currentNamespace)) == key
    }
  #endif

  private static func read(account: String, synchronizable: Bool?) throws -> Data? {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    if let synchronizable {
      query[kSecAttrSynchronizable as String] = synchronizable
    } else {
      // Any finds both a legacy device-only item and its migrated iCloud-Keychain counterpart.
      query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
    }
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    // A build without the Keychain entitlement can hold no item there, so there is none to read.
    if status == errSecItemNotFound || status == errSecMissingEntitlement { return nil }
    guard status == errSecSuccess else { throw LedgerReceiptTrustError.keychain(status) }
    guard let value = item as? Data, value.count == 32 else {
      throw LedgerReceiptTrustError.invalidKey
    }
    return value
  }

  private static func store(_ value: Data, account: String) throws -> Data {
    guard value.count == 32 else { throw LedgerReceiptTrustError.invalidKey }
    var attributes: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
      kSecAttrSynchronizable as String: true,
      kSecValueData as String: value,
    ]
    var addStatus = SecItemAdd(attributes as CFDictionary, nil)
    // SwiftPM's unsigned test bundles do not have the iCloud Keychain entitlement. Keep the
    // local path usable only in DEBUG tests; a signed production build fails closed instead of
    // publishing a backup with a non-portable trust root.
    #if DEBUG
      if addStatus == errSecMissingEntitlement {
        attributes.removeValue(forKey: kSecAttrSynchronizable as String)
        addStatus = SecItemAdd(attributes as CFDictionary, nil)
      }
    #endif
    if addStatus == errSecSuccess { return value }
    guard addStatus == errSecDuplicateItem else {
      throw LedgerReceiptTrustError.keychain(addStatus)
    }
    guard let existing = try read(account: account, synchronizable: nil) else {
      throw LedgerReceiptTrustError.keychain(errSecItemNotFound)
    }
    return existing
  }

  #if DEBUG
    /// Like `store`, but always device-only: a test key must never reach iCloud Keychain.
    private static func storeLocal(_ value: Data, account: String) throws -> Data {
      guard value.count == 32 else { throw LedgerReceiptTrustError.invalidKey }
      let attributes: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        kSecAttrSynchronizable as String: false,
        kSecValueData as String: value,
      ]
      let status = SecItemAdd(attributes as CFDictionary, nil)
      if status == errSecSuccess { return value }
      guard status == errSecDuplicateItem else { throw LedgerReceiptTrustError.keychain(status) }
      guard let existing = try read(account: account, synchronizable: nil) else {
        throw LedgerReceiptTrustError.keychain(errSecItemNotFound)
      }
      return existing
    }
  #endif

  private static func persistedReceiptIdentity(at url: URL) -> String? {
    var database: OpaquePointer?
    guard
      sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let database
    else {
      if let database { sqlite3_close(database) }
      return nil
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "SELECT idempotency_key FROM import_receipt ORDER BY rowid LIMIT 1",
        -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      return nil
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
      let value = sqlite3_column_text(statement, 0)
    else {
      return nil
    }
    let identity = String(cString: value)
    return CanonicalIdentifier.isValid(identity) ? identity : nil
  }

  package static func signature(key: Data, receiptID: String, integrityHash: String) -> String {
    let message = Data(
      ["ledger-atlas/receipt-trust/v2", receiptID, integrityHash].joined(separator: "\n").utf8)
    guard key.count == 32 else { return "" }
    let signature = HMAC<SHA256>.authenticationCode(
      for: message, using: SymmetricKey(data: key))
    return hex(Array(signature))
  }

  package static func verifies(
    key: Data, signature: String, receiptID: String, integrityHash: String
  ) -> Bool {
    guard key.count == 32, signature.count == 64 else { return false }
    return signature
      == self.signature(
        key: key, receiptID: receiptID, integrityHash: integrityHash)
  }

  private static func hex(_ bytes: some Collection<UInt8>) -> String {
    CanonicalReceiptDigest.hex(bytes)
  }

  private static let service = "com.praxstack.ledger-atlas.receipt-integrity.v1"
  private static let currentNamespace = "v3"
  private static let legacyNamespace = "v2"
}

package enum LedgerReceiptTrustError: Error, Equatable, Sendable {
  case keychain(OSStatus)
  case invalidKey
  case nonSynchronizableKey
  case file(Int32)
}
