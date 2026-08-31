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
  }

  public typealias Reader = @MainActor (String) -> Data?
  public typealias Writer = @MainActor (String, Data?) throws -> Void

  private struct PersistedState: Codable {
    var failedAttempts = 0
    var lockedUntil: Date?
    var locked = false
  }

  private static let digestAccount = "passcode-digest"
  private static let stateAccount = "lock-state"
  private static let service = "com.praxstack.ledgeratlas.app-lock.v1"

  private let read: Reader
  private let write: Writer
  private var digest: Data?
  public private(set) var failedAttempts = 0
  public private(set) var lockedUntil: Date?
  public private(set) var isLocked = false

  public init(
    reader: Reader? = nil,
    writer: Writer? = nil
  ) {
    let reader = reader ?? Self.readKeychain
    let writer = writer ?? Self.writeKeychain
    read = reader
    write = writer
    digest = reader(Self.digestAccount)
    if let data = reader(Self.stateAccount),
      let state = try? JSONDecoder().decode(PersistedState.self, from: data)
    {
      failedAttempts = max(0, state.failedAttempts)
      lockedUntil = state.lockedUntil
      isLocked = digest != nil
    }
  }

  public var hasPasscode: Bool { digest != nil }

  public func setPasscode(_ passcode: String) throws {
    guard Self.validPasscode(passcode) else { throw Error.invalidPasscode }
    do {
      try write(Self.digestAccount, Self.digest(for: passcode))
      digest = Self.digest(for: passcode)
      failedAttempts = 0
      lockedUntil = nil
      isLocked = false
      try persistState()
    } catch {
      throw Error.storageFailure
    }
  }

  public func removePasscode() throws {
    do {
      try write(Self.digestAccount, nil)
      try write(Self.stateAccount, nil)
      digest = nil
      failedAttempts = 0
      lockedUntil = nil
      isLocked = false
    } catch {
      throw Error.storageFailure
    }
  }

  public func lock() {
    guard digest != nil else { return }
    isLocked = true
    try? persistState()
  }

  public func unlock(with passcode: String) -> Bool {
    guard digest != nil, !isLockoutActive else { return false }
    guard Self.digest(for: passcode) == digest else {
      failedAttempts += 1
      if failedAttempts >= 10 {
        lockedUntil = Date().addingTimeInterval(15 * 60)
      } else if failedAttempts >= 5 {
        lockedUntil = Date().addingTimeInterval(60)
      }
      try? persistState()
      return false
    }
    markUnlocked()
    return true
  }

  public func unlockWithBiometrics() async -> Bool {
    guard digest != nil, !isLockoutActive else { return false }
    let context = LAContext()
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
      return false
    }
    do {
      try await context.evaluatePolicy(
        .deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock Ledger Atlas")
      markUnlocked()
      return true
    } catch {
      return false
    }
  }

  public var lockoutMessage: String? {
    guard let lockedUntil else { return nil }
    let remaining = max(0, Int(lockedUntil.timeIntervalSinceNow.rounded(.up)))
    guard remaining > 0 else { return nil }
    return "Too many attempts. Try again in \(remaining) seconds."
  }

  private var isLockoutActive: Bool {
    guard let lockedUntil else { return false }
    if lockedUntil <= .now {
      self.lockedUntil = nil
      try? persistState()
      return false
    }
    return true
  }

  private func markUnlocked() {
    isLocked = false
    failedAttempts = 0
    lockedUntil = nil
    try? persistState()
  }

  private func persistState() throws {
    let state = PersistedState(
      failedAttempts: failedAttempts, lockedUntil: lockedUntil, locked: isLocked)
    try write(Self.stateAccount, JSONEncoder().encode(state))
  }

  private static func validPasscode(_ passcode: String) -> Bool {
    let count = passcode.unicodeScalars.count
    return (4...128).contains(count) && passcode.unicodeScalars.allSatisfy(\.isASCII)
  }

  private static func digest(for passcode: String) -> Data {
    Data(SHA256.hash(data: Data(passcode.utf8)))
  }

  private static func readKeychain(_ account: String) -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
    return item as? Data
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
