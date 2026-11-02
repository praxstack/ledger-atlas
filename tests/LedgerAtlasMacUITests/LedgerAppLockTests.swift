import Foundation
import Testing

@testable import LedgerAtlasMacUI

/// Low work factor keeps the suite fast; production uses `defaultKDFIterations`.
private let testIterations: UInt32 = 1_000

@MainActor
@Test func appLockPersistsOnlyADigestAndEscalatesFailedAttempts() throws {
  var storage: [String: Data] = [:]
  let lock = LedgerAppLock(
    reader: { storage[$0] },
    writer: { key, value in
      if let value { storage[key] = value } else { storage.removeValue(forKey: key) }
    }, kdfIterations: testIterations)

  try lock.setPasscode("1234")
  #expect(storage.values.allSatisfy { $0 != Data("1234".utf8) })
  for _ in 0..<5 { #expect(!lock.unlock(with: "wrong")) }
  #expect(lock.failedAttempts == 5)
  #expect(lock.lockoutMessage != nil)
  #expect(!lock.unlock(with: "1234"))
}

@MainActor
@Test func appLockLocksAndUnlocksWithTheStoredPasscode() throws {
  var storage: [String: Data] = [:]
  let writer: LedgerAppLock.Writer = { key, value in
    if let value { storage[key] = value } else { storage.removeValue(forKey: key) }
  }
  let first = LedgerAppLock(reader: { storage[$0] }, writer: writer, kdfIterations: testIterations)
  try first.setPasscode("correct")
  first.lock()
  #expect(first.isLocked)

  let reopened = LedgerAppLock(reader: { storage[$0] }, writer: writer, kdfIterations: testIterations)
  #expect(reopened.isLocked)
  #expect(reopened.unlock(with: "correct"))
  #expect(!reopened.isLocked)
  try reopened.removePasscode(current: "correct")
  #expect(!reopened.hasPasscode)
}

@MainActor
@Test func appLockKeepsMissingCorruptAndUnavailableCredentialsLocked() throws {
  var storage: [String: Data] = [:]
  let writer: LedgerAppLock.Writer = { storage[$0] = $1 }
  let original = LedgerAppLock(reader: { storage[$0] }, writer: writer, kdfIterations: testIterations)
  try original.setPasscode("correct")
  for state in [nil, Data("not-json".utf8)] {
    storage["lock-state"] = state
    let restarted = LedgerAppLock(reader: { storage[$0] }, writer: writer, kdfIterations: testIterations)
    #expect(restarted.hasPasscode && restarted.isLocked)
    #expect(!restarted.unlock(with: "wrong"))
    #expect(restarted.isLocked)
  }
  let unavailable = LedgerAppLock(reader: { _ in throw LedgerAppLock.Error.storageFailure }, writer: writer, kdfIterations: testIterations)
  #expect(unavailable.isLocked && unavailable.storageUnavailable)
  #expect(!unavailable.unlock(with: "correct"))
  let absent = LedgerAppLock(reader: { _ in nil }, writer: writer, kdfIterations: testIterations)
  #expect(!absent.hasPasscode && !absent.isLocked)
}

@MainActor
@Test func appLockRequiresAuthenticationBeforeRemovingOrReplacingThePasscode() throws {
  var storage: [String: Data] = [:]
  let writer: LedgerAppLock.Writer = { storage[$0] = $1 }
  let lock = LedgerAppLock(reader: { storage[$0] }, writer: writer, kdfIterations: testIterations)
  try lock.setPasscode("correct")
  lock.lock()
  let before = storage
  #expect(throws: LedgerAppLock.Error.authenticationRequired) { try lock.removePasscode(current: "correct") }
  #expect(throws: LedgerAppLock.Error.authenticationRequired) {
    try lock.changePasscode(current: "correct", to: "replacement")
  }
  #expect(storage == before)
  #expect(lock.isLocked)
  #expect(lock.unlock(with: "correct"))
  #expect(throws: LedgerAppLock.Error.authenticationRequired) { try lock.setPasscode("replacement") }
  try lock.changePasscode(current: "correct", to: "replacement")
  lock.lock()
  #expect(!lock.unlock(with: "correct"))
  #expect(lock.unlock(with: "replacement"))
  try lock.removePasscode(current: "replacement")
  #expect(!lock.hasPasscode && !lock.isLocked)
  #expect(!LedgerAppLock(reader: { storage[$0] }, writer: writer, kdfIterations: testIterations).isLocked)
}

@MainActor
@Test func appLockPersistsBothLockoutThresholdsAcrossRestart() throws {
  var storage: [String: Data] = [:]
  var now = Date(timeIntervalSince1970: 1_800_000_000)
  let writer: LedgerAppLock.Writer = { storage[$0] = $1 }
  func restart() -> LedgerAppLock {
    LedgerAppLock(reader: { storage[$0] }, writer: writer, now: { now }, kdfIterations: testIterations)
  }
  var lock = restart()
  try lock.setPasscode("correct")
  lock.lock()
  for _ in 0..<5 { #expect(!lock.unlock(with: "wrong")) }
  lock = restart()
  #expect(lock.failedAttempts == 5)
  #expect(lock.lockedUntil == now.addingTimeInterval(60))
  #expect(!lock.unlock(with: "correct"))
  for _ in 5..<10 {
    now = now.addingTimeInterval(61)
    #expect(!lock.unlock(with: "wrong"))
    lock = restart()
  }
  #expect(lock.failedAttempts == 10)
  #expect(lock.lockedUntil == now.addingTimeInterval(900))
  now = now.addingTimeInterval(899)
  #expect(!lock.unlock(with: "correct"))
  now = now.addingTimeInterval(1)
  #expect(lock.unlock(with: "correct"))
  #expect(lock.failedAttempts == 0 && lock.lockedUntil == nil)
}

@MainActor
@Test func appLockKeepsPersistenceFailuresLockedAndCredentialChangesRecoverable() throws {
  var storage: [String: Data] = [:]
  let failure = AppLockTestFailure()
  let writer: LedgerAppLock.Writer = { key, value in
    if key == failure.account { throw LedgerAppLock.Error.storageFailure }
    storage[key] = value
  }
  func restart() -> LedgerAppLock { LedgerAppLock(reader: { storage[$0] }, writer: writer, kdfIterations: testIterations) }
  var lock = restart()
  try lock.setPasscode("correct")
  lock.lock()
  failure.account = "lock-state"
  #expect(!lock.unlock(with: "correct"))
  #expect(lock.isLocked && lock.storageUnavailable)
  failure.account = nil
  lock = restart()
  #expect(lock.unlock(with: "correct"))
  failure.account = "passcode-digest"
  #expect(throws: LedgerAppLock.Error.storageFailure) {
    try lock.changePasscode(current: "correct", to: "replacement")
  }
  #expect(lock.isLocked)
  failure.account = nil
  lock = restart()
  #expect(lock.isLocked && lock.unlock(with: "correct"))
  failure.account = "passcode-digest"
  #expect(throws: LedgerAppLock.Error.storageFailure) { try lock.removePasscode(current: "correct") }
  failure.account = nil
  lock = restart()
  #expect(lock.hasPasscode && lock.isLocked)
  #expect(lock.unlock(with: "correct"))
}

@MainActor
@Test func appLockBiometricFailureReturnsToPasscodeAndCannotBypassStorageFailure() async throws {
  var storage: [String: Data] = [:]
  let failure = AppLockTestFailure()
  let writer: LedgerAppLock.Writer = { key, value in
    if failure.account != nil { throw LedgerAppLock.Error.storageFailure }
    storage[key] = value
  }
  let lock = LedgerAppLock(reader: { storage[$0] }, writer: writer, authenticate: { false }, kdfIterations: testIterations)
  try lock.setPasscode("correct")
  lock.lock()
  #expect(await !lock.unlockWithBiometrics())
  #expect(lock.isLocked && lock.unlock(with: "correct"))
  let biometric = LedgerAppLock(reader: { storage[$0] }, writer: writer, authenticate: { true }, kdfIterations: testIterations)
  failure.account = "all"
  #expect(await !biometric.unlockWithBiometrics())
  #expect(biometric.isLocked && biometric.storageUnavailable)
}

@Test func passcodeKDFMatchesPBKDF2HMACSHA256Vectors() {
  // RFC 6070-style vectors for PBKDF2-HMAC-SHA256 (dkLen 32).
  let salt = Data("salt".utf8)
  #expect(
    hex(PasscodeCredential.deriveKey(passcode: "password", salt: salt, iterations: 1))
      == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
  #expect(
    hex(PasscodeCredential.deriveKey(passcode: "password", salt: salt, iterations: 4096))
      == "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
  #expect(LedgerAppLock.defaultKDFIterations >= 600_000)
}

@MainActor
@Test func appLockStoresASaltedSlowCredentialInsteadOfAPlainDigest() throws {
  var first: [String: Data] = [:]
  var second: [String: Data] = [:]
  let a = LedgerAppLock(reader: { first[$0] }, writer: { first[$0] = $1 }, kdfIterations: testIterations)
  let b = LedgerAppLock(reader: { second[$0] }, writer: { second[$0] = $1 }, kdfIterations: testIterations)
  try a.setPasscode("1234")
  try b.setPasscode("1234")
  let stored = try #require(first["passcode-digest"])
  #expect(stored.count == 56)
  #expect(stored.prefix(4) == Data("LAK2".utf8))
  #expect(stored != PasscodeCredential.legacyDigest("1234"))
  #expect(stored.range(of: PasscodeCredential.legacyDigest("1234")) == nil)
  // Same passcode, different installs: the salt makes the stored values differ.
  #expect(stored != second["passcode-digest"])
  let credential = try #require(PasscodeCredential(storage: stored))
  #expect(credential.iterations == testIterations && credential.salt.count == 16)
  #expect(credential.matches("1234") && !credential.matches("1235"))
}

@MainActor
@Test func appLockUnlocksALegacyDigestAndUpgradesItToTheSaltedFormat() throws {
  var storage: [String: Data] = ["passcode-digest": PasscodeCredential.legacyDigest("correct")]
  let writer: LedgerAppLock.Writer = { storage[$0] = $1 }
  func restart() -> LedgerAppLock {
    LedgerAppLock(reader: { storage[$0] }, writer: writer, kdfIterations: testIterations)
  }
  let lock = restart()
  #expect(lock.hasPasscode && lock.isLocked && !lock.storageUnavailable)
  #expect(!lock.unlock(with: "wrong"))
  #expect(storage["passcode-digest"]?.count == 32)
  #expect(lock.unlock(with: "correct"))
  let upgraded = try #require(storage["passcode-digest"])
  #expect(upgraded.count == 56 && upgraded.prefix(4) == Data("LAK2".utf8))
  // A restart always starts locked; the upgraded credential still opens it.
  let reopened = restart()
  #expect(reopened.isLocked && !reopened.storageUnavailable)
  #expect(!reopened.unlock(with: "wrong"))
  #expect(reopened.unlock(with: "correct"))
}

@MainActor
@Test func appLockTreatsMalformedCredentialsAsUnavailableStorage() {
  var zeroIterations = Data("LAK2".utf8)
  zeroIterations.append(contentsOf: [0, 0, 0, 0])
  zeroIterations.append(Data(repeating: 1, count: 48))
  var wrongMagic = Data("XXXX".utf8)
  wrongMagic.append(contentsOf: [0, 0, 3, 232])
  wrongMagic.append(Data(repeating: 1, count: 48))
  for credential in [Data(repeating: 7, count: 31), zeroIterations, wrongMagic] {
    let storage = ["passcode-digest": credential]
    let lock = LedgerAppLock(reader: { storage[$0] }, writer: { _, _ in }, kdfIterations: testIterations)
    #expect(lock.isLocked && lock.storageUnavailable)
    #expect(!lock.unlock(with: "correct"))
  }
}

@MainActor
@Test func appLockChangeAndRemoveNeedTheCurrentPasscodeAndShareTheLockout() throws {
  var storage: [String: Data] = [:]
  var now = Date(timeIntervalSince1970: 1_800_000_000)
  let lock = LedgerAppLock(
    reader: { storage[$0] }, writer: { storage[$0] = $1 }, now: { now }, kdfIterations: testIterations)
  try lock.setPasscode("correct")
  let original = storage["passcode-digest"]
  #expect(throws: LedgerAppLock.Error.incorrectPasscode) { try lock.removePasscode(current: "wrong") }
  #expect(throws: LedgerAppLock.Error.incorrectPasscode) {
    try lock.changePasscode(current: "wrong", to: "replacement")
  }
  #expect(throws: LedgerAppLock.Error.invalidPasscode) { try lock.changePasscode(current: "correct", to: "abc") }
  #expect(storage["passcode-digest"] == original)
  #expect(lock.failedAttempts == 2 && !lock.isLocked)
  for _ in 0..<3 {
    #expect(throws: LedgerAppLock.Error.incorrectPasscode) { try lock.removePasscode(current: "wrong") }
  }
  #expect(lock.failedAttempts == 5 && lock.lockoutMessage != nil)
  // During lockout even the right passcode is refused, so settings cannot be used to guess.
  #expect(throws: LedgerAppLock.Error.authenticationRequired) { try lock.removePasscode(current: "correct") }
  now = now.addingTimeInterval(61)
  try lock.changePasscode(current: "correct", to: "replacement")
  #expect(lock.failedAttempts == 0)
  try lock.removePasscode(current: "replacement")
  #expect(!lock.hasPasscode && storage["passcode-digest"] == nil)
}

private func hex(_ data: Data) -> String {
  data.map { String(format: "%02x", $0) }.joined()
}

@MainActor
private final class AppLockTestFailure {
  var account: String?
}
