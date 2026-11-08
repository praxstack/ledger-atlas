import Foundation
import LedgerCore
import Testing

@testable import LedgerAtlasMacUI

// #237 Running total of the selected entries. Synthetic figures only.

private func total(_ unit: String, in income: String?, out expense: String?) throws
  -> LedgerBrowseTotal
{
  LedgerBrowseTotal(
    unitCode: unit, income: try income.map { try ExactDecimal($0) },
    expense: try expense.map { try ExactDecimal($0) })
}

private let shown = LedgerDisplayFormatter(locale: Locale(identifier: "en_IN"))
private let hidden = LedgerDisplayFormatter(locale: Locale(identifier: "en_IN"), hidesAmounts: true)

@Test func aSelectionOfSpendingShowsOnlyItsSpending() throws {
  let summary = LedgerBrowseList.selectionSummary(
    [try total("INR", in: "0", out: "1429")], formatter: shown)
  #expect(summary == "Spending ₹1,429.00")
}

@Test func aMixedSelectionShowsInOutAndASignedNet() throws {
  let summary = LedgerBrowseList.selectionSummary(
    [try total("INR", in: "40000", out: "6210")], formatter: shown)
  #expect(summary == "In ₹40,000.00 · Out ₹6,210.00 · Net +₹33,790.00")
  let overspent = LedgerBrowseList.selectionSummary(
    [try total("INR", in: "100", out: "250")], formatter: shown)
  #expect(overspent == "In ₹100.00 · Out ₹250.00 · Net \u{2212}₹150.00")
}

@Test func eachCurrencyIsTotalledOnItsOwn() throws {
  let summary = LedgerBrowseList.selectionSummary(
    [try total("EUR", in: "0", out: "5"), try total("INR", in: "500", out: "0")],
    formatter: LedgerDisplayFormatter(locale: Locale(identifier: "en_IN")))
  let parts = try #require(summary).components(separatedBy: "; ")
  #expect(parts.count == 2)
  #expect(parts[0].hasPrefix("Spending "))
  #expect(parts[0].contains("5.00"))
  #expect(parts[1] == "Money in ₹500.00")
}

@Test func aSelectionOfOnlyTransfersShowsNoTotal() throws {
  #expect(LedgerBrowseList.selectionSummary([], formatter: shown) == nil)
  #expect(
    LedgerBrowseList.selectionSummary([try total("INR", in: "0", out: "0")], formatter: shown)
      == nil)
}

@Test func aTotalPastTheExactLimitSaysSoRatherThanShowAWrongNumber() throws {
  let summary = LedgerBrowseList.selectionSummary(
    [try total("INR", in: nil, out: "5")], formatter: shown)
  #expect(summary == "INR total unavailable")
}

@Test func hiddenAmountsMaskTheSelectionTotal() throws {
  let big = LedgerBrowseList.selectionSummary(
    [try total("INR", in: "40000", out: "6210")], formatter: hidden)
  let small = LedgerBrowseList.selectionSummary(
    [try total("INR", in: "1", out: "2")], formatter: hidden)
  let text = try #require(big)
  let hasDigit = text.contains { $0.isNumber }
  #expect(!hasDigit)
  #expect(text.contains(LedgerDisplayFormatter.hiddenAmountMask))
  // Size and direction say nothing: a lakh and a rupee read the same.
  #expect(big == small)
}
