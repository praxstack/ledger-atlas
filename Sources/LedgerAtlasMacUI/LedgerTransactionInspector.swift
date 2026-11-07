import LedgerCore
import SwiftUI

/// Details of the selected transaction, beside the list: the amount, what and where, when,
/// notes and tags, and where the entry came from.
struct LedgerTransactionInspector: View {
  let entry: LedgerBrowseEntry?
  let accountNames: [String: String]
  let categoryNames: [String: String]
  let tagNames: [String: String]
  @Environment(\.ledgerFormatter) private var formatter

  var body: some View {
    ScrollView {
      if let entry {
        details(entry)
          .padding(LedgerTheme.Space.xl)
      } else {
        VStack(spacing: LedgerTheme.Space.s) {
          Image(systemName: "sidebar.trailing")
            .font(LedgerTheme.Typeface.figure)
            .foregroundStyle(LedgerTheme.inkTertiary)
            .accessibilityHidden(true)
          Text("Select a transaction to see its details.")
            .font(LedgerTheme.Typeface.secondary)
            .foregroundStyle(LedgerTheme.inkTertiary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, LedgerTheme.Space.xxxl * 2)
        .padding(.horizontal, LedgerTheme.Space.xl)
      }
    }
    .background(LedgerTheme.recessed)
  }

  private func details(_ entry: LedgerBrowseEntry) -> some View {
    let signed = LedgerBrowseList.signedAmount(entry)
    let category = entry.categoryID.flatMap { categoryNames[$0] }
    let accounts = entry.accountIDs.compactMap { accountNames[$0] }
    let tags = entry.tagIDs.compactMap { tagNames[$0] }.sorted {
      $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }
    return VStack(alignment: .leading, spacing: LedgerTheme.Space.l) {
      VStack(alignment: .leading, spacing: LedgerTheme.Space.xs) {
        Text(entry.kind.rawValue.capitalized)
          .font(LedgerTheme.Typeface.captionEmphasis)
          .textCase(.uppercase)
          .kerning(0.6)
          .foregroundStyle(LedgerTheme.inkTertiary)
        MoneyText(signed.amount, size: .large, sign: signed.sign)
        Text(category ?? entry.kind.rawValue.capitalized)
          .font(LedgerTheme.Typeface.cardTitle)
          .foregroundStyle(LedgerTheme.ink)
          .strikethrough(entry.lifecycle == .tombstoned)
        if entry.lifecycle == .tombstoned {
          Label("Closed. Kept in history, left out of totals.", systemImage: "xmark.circle")
            .font(LedgerTheme.Typeface.caption)
            .foregroundStyle(LedgerTheme.negative)
        }
      }
      .accessibilityElement(children: .combine)

      VStack(spacing: 0) {
        row("Date", formatter.date(entry.occurredAt.date, style: .full))
        Divider().overlay(LedgerTheme.hairlineSoft)
        row(
          "Time", String(format: "%02d:%02d", entry.occurredAt.hour, entry.occurredAt.minute))
        Divider().overlay(LedgerTheme.hairlineSoft)
        row(accounts.count > 1 ? "Accounts" : "Account", accounts.joined(separator: " → "))
        if let category {
          Divider().overlay(LedgerTheme.hairlineSoft)
          row("Category", category)
        }
        if !tags.isEmpty {
          Divider().overlay(LedgerTheme.hairlineSoft)
          row("Tags", tags.map { "#\($0)" }.joined(separator: " "))
        }
        if let conversion = entry.conversion {
          Divider().overlay(LedgerTheme.hairlineSoft)
          row("Conversion", conversion)
        }
      }
      .ledgerGroupBox()

      if let note = entry.note, !note.isEmpty {
        VStack(alignment: .leading, spacing: LedgerTheme.Space.xs) {
          Text("Note").font(LedgerTheme.Typeface.captionEmphasis).foregroundStyle(LedgerTheme.inkSecondary)
          Text(note)
            .font(LedgerTheme.Typeface.body)
            .foregroundStyle(LedgerTheme.ink)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
      }

      Label(provenance(entry), systemImage: entry.revision > 1 ? "pencil" : "checkmark.seal")
        .font(LedgerTheme.Typeface.caption)
        .foregroundStyle(LedgerTheme.inkSecondary)
        .padding(LedgerTheme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LedgerTheme.accentSoft, in: .rect(cornerRadius: LedgerTheme.Radius.group))
    }
  }

  private func row(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: LedgerTheme.Space.m) {
      Text(label)
        .font(LedgerTheme.Typeface.caption)
        .foregroundStyle(LedgerTheme.inkTertiary)
        .frame(width: 76, alignment: .leading)
      Text(value.isEmpty ? "None" : value)
        .font(LedgerTheme.Typeface.secondary)
        .foregroundStyle(LedgerTheme.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
    .padding(.horizontal, LedgerTheme.Space.m)
    .padding(.vertical, LedgerTheme.Space.s)
    .accessibilityElement(children: .combine)
  }

  private func provenance(_ entry: LedgerBrowseEntry) -> String {
    entry.revision > 1
      ? "Edited. This is revision \(entry.revision); earlier versions stay in the history."
      : "Unchanged since it was recorded or imported."
  }
}
