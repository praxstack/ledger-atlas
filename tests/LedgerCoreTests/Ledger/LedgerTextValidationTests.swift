import Foundation
import Testing

@testable import LedgerCore

/// With Foundation imported, `contains("\u{0}")` misses a NUL followed by a combining mark
/// (measured on Linux Swift 6.2). Text checks look for the zero byte instead, so it is refused.
@Test func textWithANulJoinedToACombiningMarkIsRefused() {
  let hidden = "Rent\u{0}\u{301}"
  #expect(!LedgerValidation.text(hidden, maximum: 256))
  #expect(!LedgerValidation.text("\u{0}", maximum: 256))
  #expect(LedgerValidation.text("Rent\u{301}", maximum: 256))
  #expect(throws: LedgerDomainError.invalidText) {
    try LedgerOrigin(id: String(repeating: "a", count: 64), label: hidden)
  }
}
