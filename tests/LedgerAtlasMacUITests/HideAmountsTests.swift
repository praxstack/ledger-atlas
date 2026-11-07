import Foundation
import LedgerCore
import Testing

@testable import LedgerAtlasMacUI

// #173 Hide amounts. Synthetic data only: the screens show the made-up demo ledger.

private func rupees(_ literal: String) throws -> CurrencyAmount {
  try CurrencyAmount(unitCode: "INR", amount: ExactDecimal(literal))
}

/// Swift Testing's #expect can't take `contains(where:)` with a key path: it reads as throwing.
private func hasDigit(_ text: String) -> Bool { text.contains(where: \.isNumber) }

@Test func hiddenFiguresShowOneFixedMaskWhateverTheirSizeOrSign() throws {
  let shown = LedgerDisplayFormatter(locale: Locale(identifier: "en_IN"))
  let hidden = LedgerDisplayFormatter(locale: Locale(identifier: "en_IN"), hidesAmounts: true)
  let amount = try rupees("-483676.30")

  let visible = shown.parts(amount, sign: .always)
  let parts = hidden.parts(amount, sign: .always)
  #expect(!hasDigit(parts.text))
  #expect(parts.sign == .none)
  // A fixed mask: lakhs and single rupees look the same, so the width says nothing.
  #expect(parts.whole == LedgerDisplayFormatter.hiddenAmountMask)
  #expect(parts.fraction.isEmpty)
  #expect(parts.leading == visible.leading)
  let small = try rupees("5")
  #expect(parts == hidden.parts(small, sign: .always))
  #expect(hidden.amount(amount) == hidden.amount(small))
  #expect(hidden.plain(amount) == hidden.plain(small))
  #expect(hidden.figure("Balance ₹12 of ₹3,000") == "Balance ₹••••• of ₹•••••")

  #expect(!hasDigit(hidden.amount(amount)))
  #expect(!hasDigit(hidden.plain(amount)))
  #expect(hidden.plain(amount).hasSuffix(" INR"))
  #expect(!hasDigit(hidden.compactAxis(450_000, unitCode: "INR")))
  #expect(hidden.compactAxis(450_000, unitCode: "INR") == hidden.compactAxis(1, unitCode: "INR"))
  #expect(hidden.currencySymbol(for: "INR") == "₹")
  // Text that is not a figure passes through only when amounts are shown.
  #expect(shown.figure("12 accounts") == "12 accounts")
}

@Test func hideAmountsIsSavedAndOffByDefault() throws {
  #expect(LedgerProductSettings().hidesAmounts == false)
  let on = LedgerProductSettings(hidesAmounts: true)
  let decoded = try JSONDecoder().decode(
    LedgerProductSettings.self, from: JSONEncoder().encode(on))
  #expect(decoded.hidesAmounts)
  // Settings saved before #173 have no such field and keep amounts shown.
  let older = try JSONDecoder().decode(LedgerProductSettings.self, from: Data(#"{"amountColors":"monochrome"}"#.utf8))
  #expect(!older.hidesAmounts)
  #expect(LedgerDisplayFormatter(settings: on).hidesAmounts)
}

@MainActor
private func spokenFigures(on destination: AppDestination, hidesAmounts: Bool) async throws
  -> [String]
{
  // A money figure as any screen might spell it: a currency symbol before a digit, a grouped
  // number with paise or cents, or a literal with its currency code.
  let moneyPattern = try Regex(
    #"[₹$€£]\s?\d|\d[\d,]*\.\d{2}(?!\d)|\d+(\.\d+)?\s(INR|USD|EUR|GBP)\b"#)
  let settings = LedgerProductSettings(startScreen: destination, hidesAmounts: hidesAmounts)
  let mounted = try await MountedRoot(showing: destination, settings: settings)
  defer { mounted.close() }
  #expect(!mounted.readTimedOut, "the Accessibility read timed out")
  #expect(!mounted.showsNoLedgerPrompt, "\(destination) still shows the open-a-ledger prompt")
  return mounted.accessibilityElements()
    .flatMap { [$0.label, $0.title, $0.value, $0.placeholder, $0.linkedTitle] }
    .filter { $0.contains(moneyPattern) }
}

/// The acceptance check: with Hide amounts on, nothing on any screen, read the way VoiceOver
/// reads it, spells out an amount.
@MainActor
@Test(arguments: LedgerDemoTour.destinations)
func hideAmountsLeavesNoFigureOnAnyScreen(_ destination: AppDestination) async throws {
  let leaks = try await spokenFigures(on: destination, hidesAmounts: true)
  #expect(leaks.isEmpty, "\(destination.rawValue) still shows amounts: \(leaks)")
}

/// The check above only means something if the pattern finds the demo ledger's amounts when
/// they are shown.
@MainActor
@Test func theFigurePatternFindsAmountsWhenTheyAreShown() async throws {
  let figures = try await spokenFigures(on: .overview, hidesAmounts: false)
  #expect(!figures.isEmpty, "the pattern found no amount on the overview with amounts shown")
}
