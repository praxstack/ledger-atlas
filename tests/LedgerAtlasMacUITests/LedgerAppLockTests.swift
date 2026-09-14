import Foundation
import LedgerAtlasMacUI
import Testing

@MainActor
@Test func appLockPersistsOnlyADigestAndEscalatesFailedAttempts() throws {
  var storage: [String: Data] = [:]
  let lock = LedgerAppLock(
    reader: { storage[$0] },
    writer: { key, value in
      if let value { storage[key] = value } else { storage.removeValue(forKey: key) }
    })

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
  let first = LedgerAppLock(reader: { storage[$0] }, writer: writer)
  try first.setPasscode("correct")
  first.lock()
  #expect(first.isLocked)

  let reopened = LedgerAppLock(reader: { storage[$0] }, writer: writer)
  #expect(reopened.isLocked)
  #expect(reopened.unlock(with: "correct"))
  #expect(!reopened.isLocked)
  try reopened.removePasscode()
  #expect(!reopened.hasPasscode)
}

@MainActor
@Test func appLockKeepsMissingCorruptAndUnavailableCredentialsLocked() throws {
  var storage: [String: Data] = [:]
  let writer: LedgerAppLock.Writer = { storage[$0] = $1 }
  let original = LedgerAppLock(reader: { storage[$0] }, writer: writer)
  try original.setPasscode("correct")
  for state in [nil, Data("not-json".utf8)] {
    storage["lock-state"] = state
    let restarted = LedgerAppLock(reader: { storage[$0] }, writer: writer)
    #expect(restarted.hasPasscode && restarted.isLocked)
    #expect(!restarted.unlock(with: "wrong"))
    #expect(restarted.isLocked)
  }
  let unavailable = LedgerAppLock(reader: { _ in throw LedgerAppLock.Error.storageFailure }, writer: writer)
  #expect(unavailable.isLocked && unavailable.storageUnavailable)
  #expect(!unavailable.unlock(with: "correct"))
  let absent = LedgerAppLock(reader: { _ in nil }, writer: writer)
  #expect(!absent.hasPasscode && !absent.isLocked)
}

@MainActor
@Test func appLockRequiresAuthenticationBeforeRemovingOrReplacingThePasscode() throws {
  var storage: [String: Data] = [:]
  let writer: LedgerAppLock.Writer = { storage[$0] = $1 }
  let lock = LedgerAppLock(reader: { storage[$0] }, writer: writer)
  try lock.setPasscode("correct")
  lock.lock()
  let before = storage
  #expect(throws: LedgerAppLock.Error.authenticationRequired) { try lock.removePasscode() }
  #expect(throws: LedgerAppLock.Error.authenticationRequired) { try lock.setPasscode("replacement") }
  #expect(storage == before)
  #expect(lock.isLocked)
  #expect(lock.unlock(with: "correct"))
  try lock.setPasscode("replacement")
  lock.lock()
  #expect(!lock.unlock(with: "correct"))
  #expect(lock.unlock(with: "replacement"))
  try lock.removePasscode()
  #expect(!lock.hasPasscode && !lock.isLocked)
  #expect(!LedgerAppLock(reader: { storage[$0] }, writer: writer).isLocked)
}

@MainActor
@Test func appLockPersistsBothLockoutThresholdsAcrossRestart() throws {
  var storage: [String: Data] = [:]
  var now = Date(timeIntervalSince1970: 1_800_000_000)
  let writer: LedgerAppLock.Writer = { storage[$0] = $1 }
  func restart() -> LedgerAppLock {
    LedgerAppLock(reader: { storage[$0] }, writer: writer, now: { now })
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
  func restart() -> LedgerAppLock { LedgerAppLock(reader: { storage[$0] }, writer: writer) }
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
  #expect(throws: LedgerAppLock.Error.storageFailure) { try lock.setPasscode("replacement") }
  #expect(lock.isLocked)
  failure.account = nil
  lock = restart()
  #expect(lock.isLocked && lock.unlock(with: "correct"))
  failure.account = "passcode-digest"
  #expect(throws: LedgerAppLock.Error.storageFailure) { try lock.removePasscode() }
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
  let lock = LedgerAppLock(reader: { storage[$0] }, writer: writer, authenticate: { false })
  try lock.setPasscode("correct")
  lock.lock()
  #expect(await !lock.unlockWithBiometrics())
  #expect(lock.isLocked && lock.unlock(with: "correct"))
  let biometric = LedgerAppLock(reader: { storage[$0] }, writer: writer, authenticate: { true })
  failure.account = "all"
  #expect(await !biometric.unlockWithBiometrics())
  #expect(biometric.isLocked && biometric.storageUnavailable)
}

@MainActor
private final class AppLockTestFailure {
  var account: String?
}
