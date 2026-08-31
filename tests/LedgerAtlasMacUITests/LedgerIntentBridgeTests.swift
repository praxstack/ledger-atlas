import Foundation
import Testing

@testable import LedgerAtlasMacUI

@MainActor
@Test func intentBridgeQueuesOneTypedRequestAndNeverOverwritesIt() throws {
  _ = LedgerIntentBridge.consume()
  let request = LedgerIntentRequest(
    kind: .addExpense, amountLiteral: "12.34", note: "synthetic")
  try LedgerIntentBridge.enqueue(request)
  #expect(throws: LedgerIntentError.alreadyPending) {
    try LedgerIntentBridge.enqueue(.init(kind: .openBudgets))
  }
  #expect(LedgerIntentBridge.consume() == request)
  #expect(LedgerIntentBridge.consume() == nil)
}
