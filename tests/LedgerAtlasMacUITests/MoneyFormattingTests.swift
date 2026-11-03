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
