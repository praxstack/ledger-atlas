import LedgerCore
import SwiftUI

/// What is due soon (#171): rule dates and installment payments for the next days, grouped by
/// day, overdue days first and in red, with a total. Read-only: it never marks anything paid or
/// creates entries. Shown beside the rules on Recurrence and beside the entry form when the
/// daily reminder opens it.
struct UpcomingPanel: View {
  @Environment(\.ledgerFormatter) private var formatter
  let upcoming: LedgerUpcoming
  let accounts: [LedgerAccount]
  let categories: [LedgerCategory]

  static let emptyText = "Nothing is due in the next 30 days."

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: LedgerTheme.Space.l) {
        LedgerCardHeader("Upcoming") { Text("Next \(upcoming.daysAhead) days") }
        if upcoming.isEmpty {
          Text(
            upcoming.daysAhead == LedgerUpcoming.defaultDays
              ? Self.emptyText : "Nothing is due in the next \(upcoming.daysAhead) days."
          )
          .font(LedgerTheme.Typeface.secondary)
          .foregroundStyle(LedgerTheme.inkSecondary)
        } else {
          ForEach(upcoming.days) { day in
            dayGroup(day)
          }
          Divider()
          totalLine
        }
        if upcoming.olderOverdueCount > 0 {
          Text(olderText)
            .font(LedgerTheme.Typeface.caption)
            .foregroundStyle(LedgerTheme.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(LedgerTheme.Space.l)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityIdentifier("upcoming-panel")
  }

  private func dayGroup(_ day: LedgerUpcoming.Day) -> some View {
    let overdue = day.date < upcoming.today
    return VStack(alignment: .leading, spacing: LedgerTheme.Space.s) {
      Text(title(for: day.date, overdue: overdue))
        .font(LedgerTheme.Typeface.captionEmphasis)
        .foregroundStyle(overdue ? LedgerTheme.negative : LedgerTheme.inkSecondary)
        .accessibilityAddTraits(.isHeader)
      ForEach(day.items) { item in
        row(item)
      }
    }
  }

  private func row(_ item: LedgerUpcoming.Item) -> some View {
    let account = accounts.first { $0.id == item.accountID }?.name
    let category = categories.first { $0.id == item.categoryID }?.name
    let source: String =
      switch item.source {
      case .recurrence: "Recurring"
      case .installment: "Installment"
      }
    return HStack(alignment: .firstTextBaseline, spacing: LedgerTheme.Space.s) {
      VStack(alignment: .leading, spacing: LedgerTheme.Space.xxs) {
        Text(category ?? item.kind.rawValue.capitalized)
          .font(LedgerTheme.Typeface.bodyEmphasis)
          .foregroundStyle(LedgerTheme.ink)
        Text([source, account].compactMap { $0 }.joined(separator: " · "))
          .font(LedgerTheme.Typeface.caption)
          .foregroundStyle(LedgerTheme.inkTertiary)
      }
      Spacer(minLength: LedgerTheme.Space.s)
      MoneyText(item.amount, size: .row, sign: item.kind == .income ? .always : .never)
    }
    .accessibilityElement(children: .combine)
  }

  private var totalLine: some View {
    let described = LedgerBrowseList.describe(upcoming.totals, formatter: formatter, omittingZero: true)
    return HStack(alignment: .firstTextBaseline) {
      Text("Total").font(LedgerTheme.Typeface.captionEmphasis).foregroundStyle(LedgerTheme.inkSecondary)
      Spacer(minLength: LedgerTheme.Space.s)
      Text(described.isEmpty ? "—" : described)
        .font(LedgerTheme.Typeface.secondary)
        .foregroundStyle(LedgerTheme.ink)
        .multilineTextAlignment(.trailing)
    }
    .accessibilityElement(children: .combine)
  }

  /// "Overdue · 3 Nov 2026", "Today · 7 Nov 2026" or the date alone.
  private func title(for date: SourceLocalDate, overdue: Bool) -> String {
    let text = formatter.date(date)
    if overdue { return "Overdue · \(text)" }
    if date == upcoming.today { return "Today · \(text)" }
    return text
  }

  private var olderText: String {
    let count = upcoming.olderOverdueCount
    return count == 1 ? "1 older date is not listed." : "\(count) older dates are not listed."
  }
}
