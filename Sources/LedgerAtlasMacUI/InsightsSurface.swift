import Charts
import LedgerCore
import LedgerStore
import SwiftUI

/// Statistics for one month or year: totals, the category roll-up, a trend, and the
/// all-time table. Every chart has a table next to it with the same numbers, so nothing is
/// shown only as a picture.
struct InsightsSurface: View {
  let rows: [LedgerJourney.SurfaceRow]
  let table: String
  let emptyMessage: String
  var snapshot: LedgerStore.LedgerReadSnapshot? = nil
  var settings = LedgerProductSettings()
  let open: () -> Void
  let exportPDF: () -> Void
  /// Saves a PDF of the shown period. The flag hides category names.
  var exportPeriodPDF: ((InsightsReport, String, Bool) -> Void)? = nil

  @State private var kind: InsightsPeriodKind = .month
  @State private var anchor: SourceLocalDate?
  @State private var unitCode: String?
  @State private var drillDown: LedgerCategoryStatistic?
  @State private var hideNamesInPDF = false
  /// Built off the main thread whenever the period, currency or ledger changes; the
  /// sections, the drill-down and the PDF all read this one value.
  @State private var report: InsightsReport?

  private var formatter: LedgerDisplayFormatter { LedgerDisplayFormatter(settings: settings) }

  private var day: SourceLocalDate {
    if let anchor { return anchor }
    let today = LedgerPeriodRule.today(in: settings.timeZone)
    guard let snapshot else { return today }
    return InsightsReport.openingDay(in: snapshot, today: today, kind, rule: settings.periodRule)
  }

  /// What the report depends on. The ledger part is cheap: an edit or deletion adds a
  /// revision, and account and category changes are hashed field by field.
  private var reportKey: InsightsReportKey {
    var ledger = Hasher()
    if let snapshot {
      ledger.combine(snapshot.transactions.count)
      ledger.combine(snapshot.revisionHistory.count)
      for account in snapshot.accounts {
        ledger.combine(account.id)
        ledger.combine(account.currencyUnit)
        ledger.combine(account.countsInTotals)
        ledger.combine(account.variant.rawValue)
      }
      for category in snapshot.categories {
        ledger.combine(category.id)
        ledger.combine(category.name)
        ledger.combine(category.parentID)
        ledger.combine(category.displayOrder)
      }
    }
    return InsightsReportKey(
      kind: kind, day: day, unitCode: unitCode, rule: settings.periodRule,
      hasLedger: snapshot != nil, ledger: ledger.finalize())
  }

  var body: some View {
    if rows.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        Text("Insights").font(.largeTitle.bold())
        Text(emptyMessage).foregroundStyle(.secondary)
        Button("Open…", action: open)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(32)
    } else {
      List {
        if let report {
          periodSections(report)
        }
        Section("Accessible table") {
          Text(table)
            .font(.body.monospaced())
            .textSelection(.enabled)
            .accessibilityLabel(table)
            .accessibilityAddTraits(.isStaticText)
        }
        Section("Status") {
          ForEach(rows) { row in
            HStack {
              Text(row.title)
              Spacer()
              Text(row.detail)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(row.title), \(row.detail)")
          }
        }
        Section("Export") {
          Button("Export PDF statement", action: exportPDF)
            .accessibilityLabel("Export PDF statement")
        }
      }
      .navigationTitle("Insights")
      .task(id: reportKey) {
        guard let snapshot else {
          report = nil
          return
        }
        let key = reportKey
        let built = await Task.detached(priority: .userInitiated) {
          try? InsightsReport(
            snapshot: snapshot, kind: key.kind, containing: key.day, unitCode: key.unitCode,
            rule: key.rule)
        }.value
        // A newer key started its own task; this result is for an older one.
        guard !Task.isCancelled else { return }
        report = built
      }
      .sheet(item: $drillDown) { category in
        if let report, let snapshot {
          InsightsDrillDown(
            category: category, report: report, snapshot: snapshot, formatter: formatter
          ) { drillDown = nil }
        }
      }
    }
  }

  @ViewBuilder
  private func periodSections(_ report: InsightsReport) -> some View {
    let title = report.title(formatter)
    let s = report.statistics
    Section {
      HStack(spacing: 12) {
        Picker("Period", selection: $kind) {
          ForEach(InsightsPeriodKind.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 180)
        .accessibilityLabel("Period length")
        Button {
          move(-1)
        } label: {
          Image(systemName: "chevron.left")
        }
        .accessibilityLabel("Previous \(kind.title.lowercased())")
        Text(title).font(.headline).frame(minWidth: 140)
        Button {
          move(1)
        } label: {
          Image(systemName: "chevron.right")
        }
        .accessibilityLabel("Next \(kind.title.lowercased())")
        if report.units.count > 1 {
          Picker("Currency", selection: Binding(
            get: { report.unitCode }, set: { unitCode = $0 })
          ) {
            ForEach(report.units, id: \.self) { Text($0).tag($0) }
          }
          .frame(maxWidth: 140)
        }
        Spacer()
      }
      HStack(spacing: 12) {
        tile("Income", s.income, report.unitCode)
        tile("Expense", s.expense, report.unitCode)
        tile("Net", s.net, report.unitCode)
        if let balance = s.closingBalance {
          tile("Balance at end", balance.net, report.unitCode)
        }
      }
      Text(
        "\(s.incomeCount) income and \(s.expenseCount) expense entries. Transfers (\(s.transferCount)) and adjustments (\(s.adjustmentCount)) move money between accounts and are not counted as income or expense."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    } header: {
      Text("Period")
    }

    categorySection("Expense by category", s.expenseCategories, report: report)
    categorySection("Income by category", s.incomeCategories, report: report)

    Section("Trend") {
      Chart {
        ForEach(report.trend) { point in
          BarMark(
            x: .value("Period", label(point.period.start, report.kind)),
            y: .value("Amount", Self.double(point.income)))
          .foregroundStyle(by: .value("Kind", "Income"))
          .position(by: .value("Kind", "Income"))
          BarMark(
            x: .value("Period", label(point.period.start, report.kind)),
            y: .value("Amount", Self.double(point.expense)))
          .foregroundStyle(by: .value("Kind", "Expense"))
          .position(by: .value("Kind", "Expense"))
        }
      }
      .chartForegroundStyleScale(["Income": Color.green, "Expense": Color.orange])
      .frame(height: 180)
      // The chart is one spoken element; the grid below it holds the same numbers as text.
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Trend chart, \(report.trend.count) \(report.kind == .year ? "years" : "months")")
      .accessibilityValue(trendSummary(report))
      Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 4) {
        GridRow {
          Text("Period").gridColumnAlignment(.leading)
          Text("Income")
          Text("Expense")
          Text("Net")
        }
        .font(.caption.bold())
        ForEach(report.trend) { point in
          GridRow {
            Text(label(point.period.start, report.kind)).gridColumnAlignment(.leading)
            Text(money(point.income, report.unitCode))
            Text(money(point.expense, report.unitCode))
            Text(money(point.net, report.unitCode))
          }
          .accessibilityElement(children: .combine)
        }
      }
      .font(.body.monospacedDigit())
    }

    Section("Statement for \(title)") {
      Toggle("Hide category names in the PDF", isOn: $hideNamesInPDF)
      Button("Export PDF for \(title)") {
        exportPeriodPDF?(report, title, hideNamesInPDF)
      }
      .disabled(exportPeriodPDF == nil)
      Text("Snapshot \(s.snapshotDigest.prefix(16)). The screen and the PDF show the same snapshot.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
  }

  @ViewBuilder
  private func categorySection(
    _ title: String, _ rows: [LedgerCategoryStatistic], report: InsightsReport
  ) -> some View {
    if !rows.isEmpty {
      Section(title) {
        // The eight largest top-level lines; every line is listed in the rows below.
        let top = rows.filter { $0.depth == 0 }.sorted { $0.totalAmount > $1.totalAmount }
        Chart(top.prefix(8)) { row in
          BarMark(
            x: .value("Amount", Self.double(row.totalAmount)),
            y: .value("Category", row.name))
        }
        .frame(height: CGFloat(min(top.count, 8)) * 28 + 20)
        // The chart is one spoken element; every line is listed as a row below it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) chart")
        .accessibilityValue(
          top.prefix(8).map { "\($0.name) \(money($0.totalAmount, report.unitCode))" }
            .joined(separator: ", "))
        ForEach(rows) { row in
          Button {
            drillDown = row
          } label: {
            HStack {
              Text(row.name)
                .padding(.leading, CGFloat(row.depth) * 16)
              Spacer()
              Text("\(row.totalCount)").foregroundStyle(.secondary)
              Text(money(row.totalAmount, report.unitCode))
                .font(.body.monospacedDigit())
                .frame(minWidth: 120, alignment: .trailing)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(
            "\(row.name), \(money(row.totalAmount, report.unitCode)), \(row.totalCount) entries"
          )
          .accessibilityHint("Shows the entries behind this amount.")
        }
      }
    }
  }

  private func tile(_ title: String, _ value: ExactDecimal, _ unit: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(money(value, unit)).font(.title3.monospacedDigit().bold())
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    .accessibilityElement(children: .combine)
  }

  private func trendSummary(_ report: InsightsReport) -> String {
    report.trend.map {
      "\(label($0.period.start, report.kind)): income \(money($0.income, report.unitCode)), expense \(money($0.expense, report.unitCode))"
    }.joined(separator: ". ")
  }

  private func money(_ value: ExactDecimal, _ unit: String) -> String {
    (try? CurrencyAmount(unitCode: unit, amount: value)).map(formatter.amount)
      ?? "\(value.rawLiteral) \(unit)"
  }

  private func label(_ start: SourceLocalDate, _ kind: InsightsPeriodKind) -> String {
    kind == .year
      ? String(start.year) : String(format: "%04d-%02d", start.year, start.month)
  }

  private func move(_ offset: Int) {
    anchor = try? InsightsReport.date(day, movedBy: offset, kind, rule: settings.periodRule)
  }

  /// For drawing bars only. Every number shown as text uses the exact decimal.
  static func double(_ value: ExactDecimal) -> Double { Double(value.rawLiteral) ?? 0 }
}

/// The entries behind one category figure: the same transactions the total was added from.
struct InsightsDrillDown: View {
  let category: LedgerCategoryStatistic
  let report: InsightsReport
  let snapshot: LedgerStore.LedgerReadSnapshot
  let formatter: LedgerDisplayFormatter
  let close: () -> Void

  var body: some View {
    let ids = Set(
      report.statistics.transactionIDs(inCategory: category.id, includingSubcategories: true))
    let names = Dictionary(
      snapshot.categories.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    let entries = snapshot.transactions.filter { ids.contains($0.id) }.sorted {
      ($0.currentRevision.draft.occurredAt.localDateTime, $0.id)
        > ($1.currentRevision.draft.occurredAt.localDateTime, $1.id)
    }
    VStack(alignment: .leading, spacing: 12) {
      Text(category.name).font(.title2.bold())
      Text("\(entries.count) entries in \(report.title(formatter))")
        .foregroundStyle(.secondary)
      List(entries, id: \.id) { entry in
        let draft = entry.currentRevision.draft
        let amount = draft.effects.first { $0.amount.unitCode == report.unitCode }?.amount
        HStack {
          VStack(alignment: .leading) {
            Text(formatter.date(draft.occurredAt.localDateTime.date))
            Text(draft.note ?? draft.categoryID.flatMap { names[$0] } ?? draft.kind.rawValue)
              .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          if let amount { Text(formatter.amount(amount)).font(.body.monospacedDigit()) }
        }
        .accessibilityElement(children: .combine)
      }
      .frame(minWidth: 420, minHeight: 320)
      HStack {
        Spacer()
        Button("Done", action: close).keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
  }
}

struct InsightsReportKey: Hashable, Sendable {
  let kind: InsightsPeriodKind
  let day: SourceLocalDate
  let unitCode: String?
  let rule: LedgerPeriodRule
  let hasLedger: Bool
  let ledger: Int
}
