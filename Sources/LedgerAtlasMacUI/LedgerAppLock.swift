import CryptoKit
import Foundation
import LocalAuthentication
import Observation
import Security

@MainActor
@Observable
public final class LedgerAppLock {
  public enum Error: Swift.Error, Equatable, Sendable {
    case invalidPasscode
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

  private static let digestAccount = "passcode-digest"
  private static let stateAccount = "lock-state"
  private static let service = "com.praxstack.ledgeratlas.app-lock.v1"

  private let now: @MainActor () -> Date
  private let authenticate: @MainActor () async -> Bool
  private let write: Writer
  private var digest: Data?
  public private(set) var failedAttempts = 0
  public private(set) var lockedUntil: Date?
  public private(set) var isLocked = false
  public private(set) var storageUnavailable = false

  public init(
    reader: Reader? = nil,
    writer: Writer? = nil,
    now: @escaping @MainActor () -> Date = { .now },
    authenticate: (@MainActor () async -> Bool)? = nil
  ) {
    let reader = reader ?? Self.readKeychain
    write = writer ?? Self.writeKeychain
    self.now = now
    self.authenticate = authenticate ?? Self.authenticateWithBiometrics
    do {
      digest = try reader(Self.digestAccount)
      isLocked = digest != nil
      if let digest, digest.count != 32 { throw Error.storageFailure }
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

  public func setPasscode(_ passcode: String) throws {
    guard !isLocked else { throw Error.authenticationRequired }
    guard Self.validPasscode(passcode) else { throw Error.invalidPasscode }
    let newDigest = Self.digest(for: passcode)
    do {
      // Publish the credential last: an interrupted change retains the old passcode.
      try write(Self.stateAccount, JSONEncoder().encode(PersistedState()))
      try write(Self.digestAccount, newDigest)
      digest = newDigest
      apply(PersistedState())
    } catch {
      isLocked = true
      storageUnavailable = true
      throw Error.storageFailure
    }
  }

  public func removePasscode() throws {
    guard !isLocked else { throw Error.authenticationRequired }
    do {
      // If deletion stops halfway, the retained digest still locks on restart.
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

  public func lock() {
    guard digest != nil else { return }
    isLocked = true
    guard !storageUnavailable else { return }
    _ = save(PersistedState(
      failedAttempts: failedAttempts, lockedUntil: lockedUntil, locked: true))
  }

  public func unlock(with passcode: String) -> Bool {
    guard digest != nil, !storageUnavailable, !isLockoutActive else { return false }
    guard Self.digest(for: passcode) == digest else {
      failedAttempts = min(10, failedAttempts + 1)
      if failedAttempts >= 10 {
        lockedUntil = now().addingTimeInterval(15 * 60)
      } else if failedAttempts >= 5 {
        lockedUntil = now().addingTimeInterval(60)
      }
      isLocked = true
      _ = save(PersistedState(
        failedAttempts: failedAttempts, lockedUntil: lockedUntil, locked: true))
      return false
    }
    return save(PersistedState())
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

  private static func digest(for passcode: String) -> Data {
    Data(SHA256.hash(data: Data(passcode.utf8)))
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
