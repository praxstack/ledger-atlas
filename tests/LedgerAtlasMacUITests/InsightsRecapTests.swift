import Foundation
import LedgerCore
import Testing

@testable import LedgerAtlasMacUI

// #239 Month and Year in Review: the words around the figures. Synthetic values only.

private let shown = LedgerDisplayFormatter(locale: Locale(identifier: "en_IN"))
private let hidden = LedgerDisplayFormatter(locale: Locale(identifier: "en_IN"), hidesAmounts: true)

private func decimal(_ literal: String) throws -> ExactDecimal { try ExactDecimal(literal) }

@MainActor
@Test func aRecapIsNamedForItsMonthOrYear() {
  let formatter = LedgerDisplayFormatter(locale: Locale(identifier: "en_US"))
  #expect(InsightsRecapView.title(.month(2026, 10), formatter: formatter) == "October 2026 in review")
  #expect(InsightsRecapView.title(.year(2025), formatter: formatter) == "2025 in review")
  #expect(InsightsRecapView.name(LedgerRecapPeriod.month(2026, 1).previous, formatter: formatter) == "December 2025")
}

@MainActor
@Test func aChangeSaysWhichWayAndByHowMuch() throws {
  #expect(
    InsightsRecapView.change(
      try decimal("1500"), from: try decimal("1000"), unit: "INR", before: "September 2026",
      formatter: shown) == "Up ₹500.00 on September 2026")
  #expect(
    InsightsRecapView.change(
      try decimal("800"), from: try decimal("1000"), unit: "INR", before: "September 2026",
      formatter: shown) == "Down ₹200.00 on September 2026")
  #expect(
    InsightsRecapView.change(
      try decimal("1000"), from: try decimal("1000.00"), unit: "INR", before: "2024",
      formatter: shown) == "Same as 2024")
}

@MainActor
@Test func hiddenAmountsHideTheSizeAndDirectionOfAChange() throws {
  let up = InsightsRecapView.change(
    try decimal("1500"), from: try decimal("1000"), unit: "INR", before: "September 2026",
    formatter: hidden)
  let down = InsightsRecapView.change(
    try decimal("1"), from: try decimal("90000"), unit: "INR", before: "September 2026",
    formatter: hidden)
  #expect(up == down)
  let hasDigit = up.contains { $0.isNumber }
  #expect(!hasDigit)
  #expect(!up.contains("Up") && !up.contains("Down"))
}

@MainActor
@Test func theBestAndHardestMonthsAreNamed() throws {
  let best = LedgerPeriodRecap.MonthFigures(
    month: 2, income: try decimal("1000"), expense: try decimal("100"), net: try decimal("900"))
  let worst = LedgerPeriodRecap.MonthFigures(
    month: 7, income: try decimal("0"), expense: try decimal("700"), net: try decimal("-700"))
  let text = InsightsRecapView.bestAndWorst(
    best, worst, unit: "INR", formatter: LedgerDisplayFormatter(locale: Locale(identifier: "en_IN")))
  #expect(text == "Best month: February, net +₹900.00. Hardest month: July, net \u{2212}₹700.00.")
}
