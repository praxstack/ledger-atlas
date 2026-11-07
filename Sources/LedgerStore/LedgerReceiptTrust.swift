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
    // An iCloud Keychain key wins. Only signed builds can make one, and those never write a
    // file or device-only key, so in practice an account has a key in one place only.
    if let value = try read(account: currentAccount, synchronizable: true) { return value }
    // Then the place chosen in Settings, then the other one, so a key is still found while a
    // move between them is unfinished. A move checks a key at its new place before removing
    // the old copy, so both copies are always the same key.
    let directory = try keyDirectory()
    if let value = try readLocal(account: currentAccount, directory: directory) { return value }

    // Migrate keys created before the synchronizable namespace was introduced. The old item is
    // retained until the new item is durably present, so a Keychain failure cannot strand the
    // existing ledger. The new account is distinct, avoiding a duplicate-item race with the old
    // device-only record.
    let legacyAccount = account(for: identity, namespace: legacyNamespace)
    if let legacyValue = try read(account: legacyAccount, synchronizable: nil)
      ?? LedgerReceiptKeyFile.read(account: legacyAccount, in: directory)
    {
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

  /// The device-only key for `account`: from the place chosen in Settings first, then the other.
  private static func readLocal(account: String, directory: URL) throws -> Data? {
    let fromFile = { try LedgerReceiptKeyFile.read(account: account, in: directory) }
    let fromKeychain = { try read(account: account, synchronizable: false) }
    switch LedgerSecretStorage.current {
    case .appFiles: return try fromFile() ?? fromKeychain()
    case .deviceKeychain: return try fromKeychain() ?? fromFile()
    }
  }

  /// Stores a new key in iCloud Keychain when the build may use it. The free ad-hoc signed app
  /// may not (errSecMissingEntitlement). The key then goes where Settings says: a private file
  /// by default, or this Mac's Keychain.
  private static func storeNew(_ value: Data, account: String) throws -> Data {
    let deviceKeychain: ((Data, String) throws -> Data)? =
      LedgerSecretStorage.current == .deviceKeychain
      ? { value, account in try storeLocal(value, account: account) } : nil
    return try storeNew(
      value, account: account, keychain: { value, account in try store(value, account: account) },
      directory: { try keyDirectory() }, deviceKeychain: deviceKeychain)
  }

  /// `storeNew` with its Keychain writes and key folder passed in, so tests can make the Keychain
  /// refuse the key the way the ad-hoc app's Keychain does. `deviceKeychain` is nil when keys
  /// belong in files.
  package static func storeNew(
    _ value: Data, account: String, keychain: (Data, String) throws -> Data,
    directory: () throws -> URL, deviceKeychain: ((Data, String) throws -> Data)? = nil
  ) throws -> Data {
    do {
      return try keychain(value, account)
    } catch LedgerReceiptTrustError.keychain(let status) where status == errSecMissingEntitlement {
      if let deviceKeychain { return try deviceKeychain(value, account) }
      return try LedgerReceiptKeyFile.store(value, account: account, in: directory())
    }
  }

  /// Device-only Keychain items for receipt keys. Replaceable in tests.
  package struct DeviceKeys {
    package var accounts: () throws -> [String]
    package var read: (String) throws -> Data?
    /// Adds the key unless one exists, and returns the key that is kept.
    package var add: (Data, String) throws -> Data
    package var delete: (String) throws -> Void

    package init(
      accounts: @escaping () throws -> [String], read: @escaping (String) throws -> Data?,
      add: @escaping (Data, String) throws -> Data, delete: @escaping (String) throws -> Void
    ) {
      self.accounts = accounts
      self.read = read
      self.add = add
      self.delete = delete
    }

    package static var live: DeviceKeys {
      DeviceKeys(
        accounts: localAccounts, read: { try LedgerReceiptTrust.read(account: $0, synchronizable: false) },
        add: { try storeLocal($0, account: $1) }, delete: deleteLocal)
    }
  }

  /// Moves every device-only receipt key to `destination`. iCloud Keychain keys stay where
  /// they are. Each key is copied and checked before its old copy is removed, so a failure part
  /// way leaves every key readable, and running the move again finishes it. A different key
  /// already at the destination stops the move.
  package static func moveKeys(to destination: LedgerSecretStorage) throws {
    try moveKeys(to: destination, keychain: .live, directory: keyDirectory())
  }

  package static func moveKeys(
    to destination: LedgerSecretStorage, keychain: DeviceKeys, directory: URL
  ) throws {
    switch destination {
    case .deviceKeychain:
      for account in try LedgerReceiptKeyFile.accounts(in: directory) {
        guard let value = try LedgerReceiptKeyFile.read(account: account, in: directory) else {
          continue
        }
        guard try keychain.add(value, account) == value else {
          throw LedgerReceiptTrustError.conflictingKeys
        }
        // The file goes only once the Keychain gives the same key back.
        guard try keychain.read(account) == value else {
          throw LedgerReceiptTrustError.moveNotVerified
        }
        try LedgerReceiptKeyFile.remove(account: account, in: directory)
      }
    case .appFiles:
      for account in try keychain.accounts() {
        guard let value = try keychain.read(account) else { continue }
        guard try LedgerReceiptKeyFile.store(value, account: account, in: directory) == value else {
          throw LedgerReceiptTrustError.conflictingKeys
        }
        try keychain.delete(account)
      }
    }
  }

  // MARK: Recovery key (#182)

  /// The first line of a recovery key file.
  package static let recoveryKeyHeader = "ledger-atlas-recovery-key-v1"

  /// The receipt key of the ledger at `url` as a small text file the person keeps with their
  /// backups, so a backup can be opened on another Mac. Plaintext, like the v1 backup itself.
  /// Nil when the ledger has no imported history (it needs no key) or this Mac has no key.
  package static func recoveryKeyFile(for url: URL) throws -> Data? {
    guard let identity = persistedReceiptIdentity(at: url),
      let key = try self.key(for: url, create: false), key.count == 32
    else { return nil }
    let account = account(for: identity, namespace: currentNamespace)
    let text = [recoveryKeyHeader, account, CanonicalReceiptDigest.hex(key), ""]
      .joined(separator: "\n")
    return Data(text.utf8)
  }

  /// Reads a recovery key file made for the ledger at `url`. Throws `invalidKey` when the file
  /// is malformed or was made for a different ledger.
  package static func recoveryKey(from file: Data, for url: URL) throws -> (
    account: String, key: Data
  ) {
    guard file.count <= 1_024, let text = String(data: file, encoding: .utf8) else {
      throw LedgerReceiptTrustError.invalidKey
    }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard lines.count >= 3, lines[0] == recoveryKeyHeader,
      lines.dropFirst(3).allSatisfy(\.isEmpty),
      let identity = persistedReceiptIdentity(at: url),
      lines[1] == account(for: identity, namespace: currentNamespace),
      let key = hexBytes(lines[2]), key.count == 32
    else { throw LedgerReceiptTrustError.invalidKey }
    return (lines[1], key)
  }

  /// Stores a recovery key where new keys go (iCloud Keychain, a private file or this Mac's
  /// Keychain). The caller checks first that the key opens the ledger. A different key already
  /// on this Mac for the same ledger is never replaced.
  package static func installRecoveryKey(_ key: Data, account: String) throws {
    guard key.count == 32 else { throw LedgerReceiptTrustError.invalidKey }
    guard try storeNew(key, account: account) == key else {
      throw LedgerReceiptTrustError.conflictingKeys
    }
  }

  private static func hexBytes(_ text: String) -> Data? {
    let digits = Array(text.utf8)
    guard digits.count % 2 == 0 else { return nil }
    var bytes = Data(capacity: digits.count / 2)
    var index = 0
    while index < digits.count {
      guard let high = hexValue(digits[index]), let low = hexValue(digits[index + 1]) else {
        return nil
      }
      bytes.append(high << 4 | low)
      index += 2
    }
    return bytes
  }

  private static func hexValue(_ digit: UInt8) -> UInt8? {
    switch digit {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): digit - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): digit - UInt8(ascii: "a") + 10
    default: nil
    }
  }

  private static func account(for identity: String, namespace: String) -> String {
    CanonicalReceiptDigest.sha256(Data("ledger-atlas/receipt-key/\(namespace)\n\(identity)".utf8))
  }

  #if DEBUG
    /// Tests only, never in release builds: removes a ledger's key from this Mac, the way a
    /// new Mac or a wiped container has none.
    package static func removeKeyForTesting(account: String) throws {
      try? LedgerReceiptKeyFile.remove(account: account, in: keyDirectory())
      try? deleteLocal(account)
    }

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

  /// Like `store`, but always device-only. Used when Settings keeps keys in this Mac's
  /// Keychain, and for test keys, which must never reach iCloud Keychain.
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

  /// Accounts of the device-only receipt keys. Listing reads no key, so it never prompts.
  private static func localAccounts() throws -> [String] {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrSynchronizable as String: false,
      kSecReturnAttributes as String: true,
      kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    var items: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &items)
    if status == errSecItemNotFound || status == errSecMissingEntitlement { return [] }
    guard status == errSecSuccess else { throw LedgerReceiptTrustError.keychain(status) }
    let rows = items as? [[String: Any]] ?? []
    return rows.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
  }

  private static func deleteLocal(_ account: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: false,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw LedgerReceiptTrustError.keychain(status)
    }
  }

  private static func persistedReceiptIdentity(at url: URL) -> String? {
    // Read-write but query-only, as `LedgerStore.openReadOnly` and the file stamper do. Closing
    // a read-only description of the ledger made a save on another connection in this process
    // fail to take its write lock on macOS (SQLITE_IOERR_LOCK), and the stamper reads this
    // while saves run. A file the process can only read falls back to read-only. No
    // SQLITE_OPEN_NOFOLLOW: it refuses a symlink anywhere in the path (macOS /var is one), and a
    // missed identity would pick a different key account.
    var database: OpaquePointer?
    var opened = sqlite3_open_v2(
      url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK
    if opened, sqlite3_exec(database, "PRAGMA query_only=1", nil, nil, nil) != SQLITE_OK {
      opened = false
    }
    if !opened {
      sqlite3_close(database)
      database = nil
      opened = sqlite3_open_v2(
        url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
    }
    guard opened, let database else {
      sqlite3_close(database)
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
  /// Moving keys found a different key already at the destination.
  case conflictingKeys
  /// Moving keys couldn't read a key back from its new place, so its old copy was kept.
  case moveNotVerified
  case file(Int32)
}
