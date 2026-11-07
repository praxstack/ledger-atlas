import LedgerCore
internal import MMImport
import SwiftUI

/// #172: the balance-match receipt. Every imported account's balance in Ledger Atlas beside the
/// figure Money Manager shows for it, as of the backup's newest entry. Shown right after an
/// import commits and again from Import Review; it never changes when the ledger is edited.
struct ImportBalanceReceiptView: View {
  @Environment(\.ledgerFormatter) private var formatter
  let receipt: ImportBalanceReceipt
  let saveAsPDF: () -> Void
  /// Shown only right after an import, to move on to the ledger.
  var continueTitle: String?
  var continueAction: () -> Void = {}

  var body: some View {
    VStack(alignment: .leading, spacing: LedgerTheme.Space.l) {
      VStack(alignment: .leading, spacing: LedgerTheme.Space.xs) {
        LedgerCardHeader("Balances after import") {
          if let asOf { Text("As of \(asOf)") }
        }
        Text(headline)
          .font(LedgerTheme.Typeface.screenTitle)
          .foregroundStyle(LedgerTheme.ink)
      }
      .accessibilityElement(children: .combine)

      HStack(spacing: LedgerTheme.Space.s) {
        LedgerChip("\(receipt.equalCount) match", systemImage: "checkmark.circle")
        if receipt.differingCount > 0 {
          LedgerChip("\(receipt.differingCount) differ", systemImage: "exclamationmark.triangle")
        }
        if receipt.missingFromLedgerCount > 0 {
          LedgerChip("\(receipt.missingFromLedgerCount) not in this ledger", systemImage: "xmark.circle")
        }
        if receipt.notStoredCount > 0 {
          LedgerChip("\(receipt.notStoredCount) without a figure", systemImage: "questionmark.circle")
        }
      }
      .accessibilityElement(children: .combine)

      VStack(alignment: .leading, spacing: 0) {
        columnHeader
        Divider()
        ForEach(Array(receipt.rows.enumerated()), id: \.element.id) { offset, row in
          rowView(row)
          if offset < receipt.rows.count - 1 { Divider() }
        }
      }

      Text(receipt.sourceRule)
        .font(LedgerTheme.Typeface.caption)
        .foregroundStyle(LedgerTheme.inkTertiary)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: LedgerTheme.Space.s) {
        Button("Save as PDF…", action: saveAsPDF)
          .buttonStyle(LedgerSecondaryButtonStyle())
          .accessibilityLabel("Save the balance receipt as PDF")
        if let continueTitle {
          Button(continueTitle, action: continueAction)
            .buttonStyle(LedgerPrimaryButtonStyle())
            .accessibilityLabel(continueTitle)
        }
      }
      if formatter.hidesAmounts {
        Text(LedgerProductSettings.hideAmountsExportNotice)
          .font(LedgerTheme.Typeface.caption)
          .foregroundStyle(LedgerTheme.inkSecondary)
      }
    }
    .ledgerCard()
  }

  private var headline: String {
    if receipt.missingFromLedgerCount > 0 {
      return receipt.missingFromLedgerCount == 1
        ? "1 Money Manager account is not in this ledger"
        : "\(receipt.missingFromLedgerCount) Money Manager accounts are not in this ledger"
    }
    if receipt.differingCount > 0 {
      return receipt.differingCount == 1
        ? "1 balance differs from Money Manager"
        : "\(receipt.differingCount) balances differ from Money Manager"
    }
    if receipt.rows.isEmpty { return "The backup has no accounts to compare" }
    return receipt.notStoredCount == 0
      ? "Every balance matches Money Manager"
      : "Every balance with a Money Manager figure matches"
  }

  private var asOf: String? {
    guard let day = receipt.throughDay else { return nil }
    let parts = day.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3,
      let date = try? SourceLocalDate(year: parts[0], month: parts[1], day: parts[2])
    else { return day }
    return formatter.date(date)
  }

  private var columnHeader: some View {
    HStack(alignment: .firstTextBaseline, spacing: LedgerTheme.Space.m) {
      Text("Account").frame(maxWidth: .infinity, alignment: .leading)
      Text("Ledger Atlas").frame(minWidth: Self.figureWidth, alignment: .trailing)
      Text("Money Manager").frame(minWidth: Self.figureWidth, alignment: .trailing)
      Text("Result").frame(minWidth: Self.resultWidth, alignment: .leading)
    }
    .font(LedgerTheme.Typeface.captionEmphasis)
    .foregroundStyle(LedgerTheme.inkTertiary)
    .padding(.vertical, LedgerTheme.Space.s)
    .accessibilityHidden(true)
  }

  private static let figureWidth: CGFloat = 130
  private static let resultWidth: CGFloat = 170

  private func rowView(_ row: ImportBalanceReceipt.Row) -> some View {
    VStack(alignment: .leading, spacing: LedgerTheme.Space.xs) {
      HStack(alignment: .firstTextBaseline, spacing: LedgerTheme.Space.m) {
        VStack(alignment: .leading, spacing: LedgerTheme.Space.xs) {
          Text(row.name).font(LedgerTheme.Typeface.bodyEmphasis).foregroundStyle(LedgerTheme.ink)
          if !row.sourceMarks.isEmpty {
            Text(row.sourceMarks.joined(separator: " · ").capitalizedFirst)
              .font(LedgerTheme.Typeface.caption)
              .foregroundStyle(LedgerTheme.inkTertiary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Group {
          if let ledger = row.ledgerBalance {
            figure(ledger, unit: row.currencyUnit)
          } else {
            Text("Not in this ledger")
              .font(LedgerTheme.Typeface.secondary)
              .foregroundStyle(LedgerTheme.inkTertiary)
          }
        }
        .frame(minWidth: Self.figureWidth, alignment: .trailing)
        Group {
          if let source = row.sourceBalance {
            figure(source, unit: row.sourceUnit)
          } else {
            Text("Not stored in the backup")
              .font(LedgerTheme.Typeface.secondary)
              .foregroundStyle(LedgerTheme.inkTertiary)
          }
        }
        .frame(minWidth: Self.figureWidth, alignment: .trailing)
        outcome(row)
          .frame(minWidth: Self.resultWidth, alignment: .leading)
      }
      if let note = note(for: row) {
        Text(note)
          .font(LedgerTheme.Typeface.caption)
          .foregroundStyle(LedgerTheme.inkSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.vertical, LedgerTheme.Space.s)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spoken(row))
  }

  @ViewBuilder
  private func figure(_ literal: String, unit: String) -> some View {
    if let amount = Self.amount(literal, unit: unit) {
      MoneyText(amount, size: .row, tone: .neutral)
    } else {
      Text("\(literal) \(unit)").font(LedgerTheme.Typeface.bodyEmphasis)
    }
  }

  @ViewBuilder
  private func outcome(_ row: ImportBalanceReceipt.Row) -> some View {
    switch row.outcome {
    case .equal:
      Label("Matches", systemImage: "checkmark.circle.fill")
        .font(LedgerTheme.Typeface.captionEmphasis)
        .foregroundStyle(LedgerTheme.positive)
    case .differs:
      Label(differenceText(row) ?? "Differs", systemImage: "exclamationmark.triangle.fill")
        .font(LedgerTheme.Typeface.captionEmphasis)
        .foregroundStyle(LedgerTheme.negative)
    case .notStored:
      Label("No figure", systemImage: "questionmark.circle")
        .font(LedgerTheme.Typeface.captionEmphasis)
        .foregroundStyle(LedgerTheme.inkTertiary)
    case .notInLedger:
      Label("Missing here", systemImage: "xmark.circle.fill")
        .font(LedgerTheme.Typeface.captionEmphasis)
        .foregroundStyle(LedgerTheme.negative)
    case .differentCurrency:
      Label("Different currency", systemImage: "exclamationmark.triangle.fill")
        .font(LedgerTheme.Typeface.captionEmphasis)
        .foregroundStyle(LedgerTheme.negative)
    }
  }

  /// "₹5.00 higher here", from Ledger Atlas's side. With amounts hidden the figure shows as
  /// bullets and VoiceOver hears only the direction.
  private func differenceText(_ row: ImportBalanceReceipt.Row, spoken: Bool = false) -> String? {
    guard case .differs(let literal) = row.outcome else { return nil }
    let negative = literal.hasPrefix("-")
    let magnitude = negative ? String(literal.dropFirst()) : literal
    let direction = negative ? "lower here" : "higher here"
    if spoken, formatter.hidesAmounts { return direction }
    guard let amount = Self.amount(magnitude, unit: row.currencyUnit) else {
      return "Differs by \(formatter.figure(literal)) \(row.currencyUnit)"
    }
    return "\(formatter.parts(amount).text) \(direction)"
  }

  private func note(for row: ImportBalanceReceipt.Row) -> String? {
    var notes: [String] = []
    if row.outcome == .notInLedger {
      notes.append("Money Manager lists this account, but the import did not create it here.")
    }
    if let reason = row.sourceUnavailableReason {
      notes.append("Money Manager's figure can't be worked out: \(reason).")
    }
    if row.outcome == .differentCurrency {
      notes.append(
        "Money Manager keeps this account in \(row.sourceUnit) and this ledger in \(row.currencyUnit), so the figures can't be compared.")
    }
    if row.debitCardEntryCount > 0 {
      let entries = row.debitCardEntryCount == 1 ? "1 entry" : "\(row.debitCardEntryCount) entries"
      notes.append("Money Manager counts \(entries) made with a linked debit card in this account.")
    }
    if row.notImportedEntryCount > 0 {
      let entries = row.notImportedEntryCount == 1 ? "1 entry" : "\(row.notImportedEntryCount) entries"
      notes.append(
        "Money Manager also counts \(entries) that the import kept as preserved source instead of moving money here.")
    }
    return notes.isEmpty ? nil : notes.joined(separator: " ")
  }

  private func spoken(_ row: ImportBalanceReceipt.Row) -> String {
    var parts = [row.name]
    parts += row.sourceMarks
    parts.append(
      row.ledgerBalance.map { "Ledger Atlas \(spokenAmount($0, unit: row.currencyUnit))" }
        ?? "not in this ledger")
    parts.append(
      row.sourceBalance.map { "Money Manager \(spokenAmount($0, unit: row.sourceUnit))" }
        ?? "Money Manager figure not stored in the backup")
    switch row.outcome {
    case .equal: parts.append("matches")
    case .differs: parts.append("differs, \(differenceText(row, spoken: true) ?? "")")
    case .notStored: parts.append("no figure to compare")
    case .notInLedger: parts.append("missing from this ledger")
    case .differentCurrency: parts.append("differs, in a different currency")
    }
    if let note = note(for: row) { parts.append(note) }
    return parts.joined(separator: ", ")
  }

  private func spokenAmount(_ literal: String, unit: String) -> String {
    if formatter.hidesAmounts { return LedgerDisplayFormatter.hiddenAmountLabel }
    return Self.amount(literal, unit: unit).map { formatter.parts($0).text } ?? "\(literal) \(unit)"
  }

  private static func amount(_ literal: String, unit: String) -> CurrencyAmount? {
    guard let decimal = try? ExactDecimal(literal) else { return nil }
    return try? CurrencyAmount(unitCode: unit, amount: decimal)
  }
}

extension String {
  fileprivate var capitalizedFirst: String {
    guard let first else { return self }
    return first.uppercased() + dropFirst()
  }
}
