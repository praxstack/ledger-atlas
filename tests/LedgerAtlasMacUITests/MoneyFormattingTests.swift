import Foundation
import LedgerCore
import Testing

@testable import LedgerAtlasMacUI

@Test func moneyPartsSplitSymbolWholeAndFraction() {
  let parts = MoneyParts(formatted: "₹4,83,676.30", decimalSeparator: ".", sign: .minus)
  #expect(parts.leading == "₹")
  #expect(parts.whole == "4,83,676")
  #expect(parts.fraction == ".30")
  #expect(parts.trailing == "")
  #expect(parts.text == "\u{2212}₹4,83,676.30")

  let euro = MoneyParts(formatted: "1.234,50 €", decimalSeparator: ",", sign: .plus)
  #expect(euro.whole == "1.234")
  #expect(euro.fraction == ",50")
  #expect(euro.trailing == " €")
  #expect(euro.text == "+1.234,50 €")

  let yen = MoneyParts(formatted: "¥120,000", decimalSeparator: ".", sign: .none)
  #expect(yen.whole == "120,000")
  #expect(yen.fraction == "")
}

@Test func rupeesUseIndianGroupingInAnyLocale() throws {
  let netWorth = try CurrencyAmount(unitCode: "INR", amount: ExactDecimal("483676.3"))
  for locale in ["en_US", "en_GB", "en_IN"] {
    let parts = LedgerDisplayFormatter(locale: Locale(identifier: locale)).parts(netWorth)
    #expect(parts.text == "₹4,83,676.30", "locale \(locale)")
  }
  // Other currencies keep the chosen locale's grouping.
  let dollars = try CurrencyAmount(unitCode: "USD", amount: ExactDecimal("483676.3"))
  #expect(LedgerDisplayFormatter(locale: Locale(identifier: "en_US")).parts(dollars).text == "$483,676.30")
}

@Test func signStylesUseTheTrueMinusSign() throws {
  let formatter = LedgerDisplayFormatter(locale: Locale(identifier: "en_IN"))
  let spend = try CurrencyAmount(unitCode: "INR", amount: ExactDecimal("-486.5"))
  let income = try CurrencyAmount(unitCode: "INR", amount: ExactDecimal("78000"))
  let zero = try CurrencyAmount(unitCode: "INR", amount: ExactDecimal("0"))
  #expect(formatter.parts(spend).text == "\u{2212}₹486.50")
  #expect(formatter.parts(spend, sign: .always).text == "\u{2212}₹486.50")
  #expect(formatter.parts(spend, sign: .never).text == "₹486.50")
  #expect(formatter.parts(income, sign: .always).text == "+₹78,000.00")
  #expect(formatter.parts(income).text == "₹78,000.00")
  #expect(formatter.parts(zero, sign: .always).text == "₹0.00")
  // Extra canonical precision still shows.
  let precise = try CurrencyAmount(unitCode: "INR", amount: ExactDecimal("-10.125"))
  #expect(formatter.parts(precise, sign: .always).fraction == ".125")
}

@Test func paletteColoursAreStablePerName() {
  #expect(LedgerTheme.stableHash("Groceries") == LedgerTheme.stableHash("Groceries"))
  #expect(LedgerTheme.stableHash("Groceries") != LedgerTheme.stableHash("Transport"))
}

@Test func defaultAmountColoursKeepSpendingInInk() {
  #expect(LedgerProductSettings().amountColors == .incomeGreen)
  #expect(!LedgerProductSettings.AmountColors.incomeGreen.tintsSpending)
  #expect(LedgerProductSettings.AmountColors.incomeGreenExpenseRed.tintsSpending)
}

@Test func chartAxesUseLakhAndCroreForRupees() {
  let formatter = LedgerDisplayFormatter(locale: Locale(identifier: "en_US"))
  #expect(formatter.compactAxis(450_000, unitCode: "INR") == "₹4.5L")
  #expect(formatter.compactAxis(12_000_000, unitCode: "INR") == "₹1.2Cr")
  #expect(formatter.compactAxis(2_000_000, unitCode: "INR") == "₹20L")
  #expect(formatter.compactAxis(-150_000, unitCode: "INR") == "\u{2212}₹1.5L")
  #expect(formatter.compactAxis(450_000, unitCode: "USD") == "$450K")
  #expect(formatter.compactAxis(1_000_000, unitCode: "USD") == "$1M")
  #expect(formatter.compactAxis(0, unitCode: "USD") == "$0")
}

@Test func monthLabelsFollowTheLocale() throws {
  let formatter = LedgerDisplayFormatter(locale: Locale(identifier: "en_US"))
  let november = try SourceLocalDate(year: 2026, month: 11, day: 1)
  #expect(formatter.shortMonth(november) == "Nov")
  #expect(formatter.monthTitle(november) == "November 2026")
}

@Test func accountColoursNeverRepeatAndSkipTheRose() {
  let names = ["Cash", "Everyday Bank", "Rewards Card", "Emergency Fund", "Index Fund", "Travel Wallet"]
  let indices = LedgerTheme.accountPaletteIndices(for: names)
  #expect(Set(indices.values).count == names.count, "two accounts share a colour: \(indices)")
  #expect(!indices.values.contains(LedgerTheme.roseIndex))
  // The skipped slot is the rose, so reordering the palette can't silently move it.
  #expect(LedgerTheme.paletteHex[LedgerTheme.roseIndex].light == 0xB5666A)
  // Same accounts in another order: same colours, so the sidebar and Accounts screen agree.
  #expect(LedgerTheme.accountPaletteIndices(for: names.reversed()) == indices)
}

@Test func categorySymbolsMatchWholeWords() {
  #expect(LedgerCategorySymbol.name(for: "Food & Dining", kind: .expense) == "fork.knife")
  #expect(LedgerCategorySymbol.name(for: "Groceries", kind: .expense) == "cart.fill")
  #expect(LedgerCategorySymbol.name(for: "Transport", kind: .expense) == "car.fill")
  #expect(LedgerCategorySymbol.name(for: "Salary", kind: .income) == "banknote.fill")
  // "card" is not "car"; an unknown name falls back to the kind.
  #expect(LedgerCategorySymbol.name(for: "Card", kind: .expense) == "arrow.up.right")
  #expect(LedgerCategorySymbol.name(for: nil, kind: .transfer) == "arrow.left.arrow.right")
  // Common Money Manager names whose words could pick the wrong rule.
  #expect(LedgerCategorySymbol.name(for: "Personal Loan", kind: .expense) == "creditcard.fill")
  #expect(LedgerCategorySymbol.name(for: "Credit Card Bill", kind: .expense) == "creditcard.fill")
  #expect(LedgerCategorySymbol.name(for: "Electricity Bill", kind: .expense) == "bolt.fill")
}
