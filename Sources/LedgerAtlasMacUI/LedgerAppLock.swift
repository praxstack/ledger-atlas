import CommonCrypto
import Foundation
import LocalAuthentication
import Observation
import Security

@MainActor
@Observable
public final class LedgerAppLock {
  public enum Error: Swift.Error, Equatable, Sendable {
    case invalidPasscode
    case incorrectPasscode
    case storageFailure
    case authenticationRequired
  }

  public typealias Reader = @MainActor (String) throws -> Data?
  public typealias Writer = @MainActor (String, Data?) throws -> Void

  private struct PersistedState: Codable {
    var failedAttempts = 0
    var lockedUntil: Date?
    var locked = false
  }

  /// Default PBKDF2-HMAC-SHA256 work factor (OWASP 2023 guidance for SHA-256).
  nonisolated public static let defaultKDFIterations: UInt32 = 600_000

  // The account name predates the salted format; existing Keychain items keep working.
  private static let digestAccount = "passcode-digest"
  private static let stateAccount = "lock-state"
  private static let service = "com.praxstack.ledgeratlas.app-lock.v1"

  private let now: @MainActor () -> Date
  private let authenticate: @MainActor () async -> Bool
  private let write: Writer
  private let kdfIterations: UInt32
  private var digest: Data?
  public private(set) var failedAttempts = 0
  public private(set) var lockedUntil: Date?
  public private(set) var isLocked = false
  public private(set) var storageUnavailable = false

  public init(
    reader: Reader? = nil,
    writer: Writer? = nil,
    now: @escaping @MainActor () -> Date = { .now },
    authenticate: (@MainActor () async -> Bool)? = nil,
    kdfIterations: UInt32 = LedgerAppLock.defaultKDFIterations
  ) {
    let reader = reader ?? Self.readKeychain
    write = writer ?? Self.writeKeychain
    self.now = now
    self.kdfIterations = max(1, kdfIterations)
    self.authenticate = authenticate ?? Self.authenticateWithBiometrics
    do {
      digest = try reader(Self.digestAccount)
      isLocked = digest != nil
      if let digest, PasscodeCredential(storage: digest) == nil { throw Error.storageFailure }
      if let data = try reader(Self.stateAccount),
        let state = try? JSONDecoder().decode(PersistedState.self, from: data)
      {
        failedAttempts = min(10, max(0, state.failedAttempts))
        lockedUntil = state.lockedUntil
      }
    } catch {
      isLocked = true
      storageUnavailable = true
    }
  }

  public var hasPasscode: Bool { digest != nil }

  /// Sets the first passcode. Replacing or removing one needs the current passcode.
  public func setPasscode(_ passcode: String) throws {
    guard !isLocked else { throw Error.authenticationRequired }
    guard digest == nil else { throw Error.authenticationRequired }
    try storeCredential(for: passcode)
  }

  public func changePasscode(current: String, to replacement: String) throws {
    guard !isLocked else { throw Error.authenticationRequired }
    guard Self.validPasscode(replacement) else { throw Error.invalidPasscode }
    try confirmCurrentPasscode(current)
    try storeCredential(for: replacement)
  }

  public func removePasscode(current: String) throws {
    guard !isLocked else { throw Error.authenticationRequired }
    try confirmCurrentPasscode(current)
    do {
      // If deletion stops halfway, the retained credential still locks on restart.
      try write(Self.stateAccount, nil)
      try write(Self.digestAccount, nil)
      digest = nil
      apply(PersistedState())
    } catch {
      isLocked = true
      storageUnavailable = true
      throw Error.storageFailure
    }
  }

  private func storeCredential(for passcode: String) throws {
    guard Self.validPasscode(passcode) else { throw Error.invalidPasscode }
    let credential = PasscodeCredential.make(passcode: passcode, iterations: kdfIterations)
    do {
      // Publish the credential last: an interrupted change retains the old passcode.
      try write(Self.stateAccount, JSONEncoder().encode(PersistedState()))
      try write(Self.digestAccount, credential.storage)
      digest = credential.storage
      apply(PersistedState())
    } catch {
      isLocked = true
      storageUnavailable = true
      throw Error.storageFailure
    }
  }

  /// Wrong answers count toward the same persistent lockout as the lock screen.
  private func confirmCurrentPasscode(_ passcode: String) throws {
    guard let digest, !storageUnavailable else { throw Error.authenticationRequired }
    guard !isLockoutActive else { throw Error.authenticationRequired }
    guard PasscodeCredential(storage: digest)?.matches(passcode) == true else {
      recordFailure(lockApp: false)
      throw Error.incorrectPasscode
    }
  }

  public func lock() {
    guard digest != nil else { return }
    isLocked = true
    guard !storageUnavailable else { return }
    _ = save(PersistedState(
      failedAttempts: failedAttempts, lockedUntil: lockedUntil, locked: true))
  }

  public func unlock(with passcode: String) -> Bool {
    guard let digest, !storageUnavailable, !isLockoutActive,
      let credential = PasscodeCredential(storage: digest)
    else { return false }
    guard credential.matches(passcode) else {
      recordFailure(lockApp: true)
      return false
    }
    guard save(PersistedState()) else { return false }
    if credential.isLegacy { upgradeLegacyCredential(passcode) }
    return true
  }

  /// Rewrites an unsalted v1 digest as a salted credential after a successful unlock.
  /// A failed rewrite keeps the old credential; it still unlocks next time.
  private func upgradeLegacyCredential(_ passcode: String) {
    let upgraded = PasscodeCredential.make(passcode: passcode, iterations: kdfIterations)
    guard (try? write(Self.digestAccount, upgraded.storage)) != nil else { return }
    digest = upgraded.storage
  }

  private func recordFailure(lockApp: Bool) {
    failedAttempts = min(10, failedAttempts + 1)
    if failedAttempts >= 10 {
      lockedUntil = now().addingTimeInterval(15 * 60)
    } else if failedAttempts >= 5 {
      lockedUntil = now().addingTimeInterval(60)
    }
    if lockApp { isLocked = true }
    _ = save(PersistedState(
      failedAttempts: failedAttempts, lockedUntil: lockedUntil, locked: isLocked))
  }

  public func unlockWithBiometrics() async -> Bool {
    guard digest != nil, !storageUnavailable, !isLockoutActive else { return false }
    guard await authenticate(), digest != nil, !storageUnavailable, !isLockoutActive else { return false }
    return save(PersistedState())
  }

  public var lockoutMessage: String? {
    guard let lockedUntil else { return nil }
    let remaining = max(0, Int(lockedUntil.timeIntervalSince(now()).rounded(.up)))
    guard remaining > 0 else { return nil }
    return "Too many attempts. Try again in \(remaining) seconds."
  }

  private var isLockoutActive: Bool {
    lockedUntil.map { $0 > now() } ?? false
  }

  private func save(_ state: PersistedState) -> Bool {
    do {
      try write(Self.stateAccount, JSONEncoder().encode(state))
      apply(state)
      return true
    } catch {
      isLocked = true
      storageUnavailable = true
      return false
    }
  }

  private func apply(_ state: PersistedState) {
    isLocked = state.locked
    failedAttempts = state.failedAttempts
    lockedUntil = state.lockedUntil
    storageUnavailable = false
  }

  private static func authenticateWithBiometrics() async -> Bool {
    let context = LAContext()
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
      return false
    }
    do {
      try await context.evaluatePolicy(
        .deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock Ledger Atlas")
      return true
    } catch {
      return false
    }
  }

  private static func validPasscode(_ passcode: String) -> Bool {
    let count = passcode.unicodeScalars.count
    return (4...128).contains(count) && passcode.unicodeScalars.allSatisfy(\.isASCII)
  }

  private static func readKeychain(_ account: String) throws -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else { throw Error.storageFailure }
    return data
  }

  private static func writeKeychain(_ account: String, _ data: Data?) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    if let data {
      let attributes: [String: Any] = query.merging([
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      ]) { _, new in new }
      let status = SecItemAdd(attributes as CFDictionary, nil)
      if status == errSecDuplicateItem {
        guard SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess else {
          throw Error.storageFailure
        }
      } else if status != errSecSuccess {
        throw Error.storageFailure
      }
    } else {
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else { throw Error.storageFailure }
    }
  }
}

/// Stored passcode verifier. The lock is a UI gate over the open ledger: it does not
/// encrypt ledger files on disk. The verifier only has to resist offline guessing.
///
/// v2 layout (56 bytes): "LAK2" | iterations (UInt32, big-endian) | salt (16) | PBKDF2-HMAC-SHA256 key (32).
/// v1 layout (32 bytes): unsalted SHA-256, read only so existing installs can unlock and upgrade.
struct PasscodeCredential: Equatable {
  static let magic = Data("LAK2".utf8)
  static let saltLength = 16
  static let keyLength = 32
  static let maximumIterations: UInt32 = 10_000_000

  let iterations: UInt32
  let salt: Data
  let key: Data
  let isLegacy: Bool

  init?(storage: Data) {
    let bytes = Data(storage)
    if bytes.count == Self.keyLength {
      iterations = 0
      salt = Data()
      key = bytes
      isLegacy = true
      return
    }
    guard bytes.count == Self.magic.count + 4 + Self.saltLength + Self.keyLength,
      bytes.prefix(Self.magic.count) == Self.magic
    else { return nil }
    let count = bytes.dropFirst(Self.magic.count).prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    guard (1...Self.maximumIterations).contains(count) else { return nil }
    iterations = count
    salt = Data(bytes.dropFirst(Self.magic.count + 4).prefix(Self.saltLength))
    key = Data(bytes.suffix(Self.keyLength))
    isLegacy = false
  }

  private init(iterations: UInt32, salt: Data, key: Data) {
    self.iterations = iterations
    self.salt = salt
    self.key = key
    isLegacy = false
  }

  static func make(passcode: String, iterations: UInt32) -> PasscodeCredential {
    var generator = SystemRandomNumberGenerator()
    let salt = Data((0..<saltLength).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    return PasscodeCredential(
      iterations: iterations, salt: salt,
      key: deriveKey(passcode: passcode, salt: salt, iterations: iterations))
  }

  var storage: Data {
    if isLegacy { return key }
    var data = Self.magic
    withUnsafeBytes(of: iterations.bigEndian) { data.append(contentsOf: $0) }
    return data + salt + key
  }

  func matches(_ passcode: String) -> Bool {
    let candidate =
      isLegacy
      ? Self.legacyDigest(passcode)
      : Self.deriveKey(passcode: passcode, salt: salt, iterations: iterations)
    return Self.constantTimeEqual(candidate, key)
  }

  static func deriveKey(passcode: String, salt: Data, iterations: UInt32) -> Data {
    let password = Array(passcode.utf8)
    var derived = [UInt8](repeating: 0, count: keyLength)
    let status = password.withUnsafeBufferPointer { passwordBytes in
      salt.withUnsafeBytes { saltBytes in
        CCKeyDerivationPBKDF(
          CCPBKDFAlgorithm(kCCPBKDF2),
          passwordBytes.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
          passwordBytes.count,
          saltBytes.bindMemory(to: UInt8.self).baseAddress, saltBytes.count,
          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
          &derived, derived.count)
      }
    }
    // A KDF failure must never yield a key that matches a stored one.
    guard status == Int32(kCCSuccess) else { return Data() }
    return Data(derived)
  }

  static func legacyDigest(_ passcode: String) -> Data {
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    let bytes = Array(passcode.utf8)
    bytes.withUnsafeBufferPointer { _ = CC_SHA256($0.baseAddress, CC_LONG($0.count), &digest) }
    return Data(digest)
  }

  static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count, !lhs.isEmpty else { return false }
    return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }
}
