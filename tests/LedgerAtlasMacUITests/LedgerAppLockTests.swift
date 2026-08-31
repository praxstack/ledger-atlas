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
