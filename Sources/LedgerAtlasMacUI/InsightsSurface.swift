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
  /// Statistics, or Review: the recaps of finished months and years (#239).
  @State private var section: InsightsSection = .statistics

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
      LedgerEmptyState(
        "Insights", systemImage: "chart.bar.xaxis", message: emptyMessage
      ) {
        Button("Open…", action: open).buttonStyle(LedgerPrimaryButtonStyle())
      }
      .ledgerCanvas()
      .navigationTitle("Insights")
    } else {
      Group {
        if section == .review, let snapshot {
          InsightsRecapView(snapshot: snapshot, settings: settings)
        } else {
          statistics
        }
      }
      .navigationTitle("Insights")
      .toolbar {
        ToolbarItem(placement: .principal) {
          Picker("Insights view", selection: $section) {
            ForEach(InsightsSection.allCases) { Text($0.title).tag($0) }
          }
          .pickerStyle(.segmented)
          .help("Statistics for any period, or a recap of a finished month or year")
        }
      }
    }
  }

  private var statistics: some View {
    LedgerCardColumn(maxWidth: 820) {
      if let report {
        periodCard(report)
        categoryCard("Expense by category", report.statistics.expenseCategories, report: report)
        categoryCard("Income by category", report.statistics.incomeCategories, report: report)
        trendCard(report)
        statementCard(report)
      }
      accessibleTableCard
      statusCard
      exportCard
    }
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

  // MARK: Period

  private func periodCard(_ report: InsightsReport) -> some View {
    let title = report.title(formatter)
    let s = report.statistics
    return VStack(alignment: .leading, spacing: LedgerTheme.Space.l) {
      HStack(spacing: LedgerTheme.Space.m) {
        Text("Period")
          .font(LedgerTheme.Typeface.cardTitle)
          .foregroundStyle(LedgerTheme.ink)
          .accessibilityAddTraits(.isHeader)
        Picker("Period", selection: $kind) {
          ForEach(InsightsPeriodKind.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 160)
        .accessibilityLabel("Period length")
        Spacer(minLength: LedgerTheme.Space.s)
        if report.units.count > 1 {
          Picker(
            "Currency",
            selection: Binding(get: { report.unitCode }, set: { unitCode = $0 })
          ) {
            ForEach(report.units, id: \.self) { Text($0).tag($0) }
          }
          .pickerStyle(.menu)
          .fixedSize()
          .accessibilityLabel("Currency")
        }
        HStack(spacing: LedgerTheme.Space.xxs) {
          Button {
            move(-1)
          } label: {
            Image(systemName: "chevron.left").frame(width: 22, height: 22)
          }
          .accessibilityLabel("Previous \(kind.title.lowercased())")
          Text(title)
            .font(LedgerTheme.Typeface.bodyEmphasis)
            .foregroundStyle(LedgerTheme.ink)
            .monospacedDigit()
            .frame(minWidth: 120)
          Button {
            move(1)
          } label: {
            Image(systemName: "chevron.right").frame(width: 22, height: 22)
          }
          .accessibilityLabel("Next \(kind.title.lowercased())")
        }
        .buttonStyle(LedgerSecondaryButtonStyle())
      }
      HStack(alignment: .top, spacing: LedgerTheme.Space.xxl) {
        figure("Income", s.income, report.unitCode)
        figure("Expense", s.expense, report.unitCode)
        figure("Net", s.net, report.unitCode, negativeIsAlert: true)
        if let balance = s.closingBalance {
          figure("Balance at end", balance.net, report.unitCode, negativeIsAlert: true)
        }
        Spacer(minLength: 0)
      }
      Text(
        "\(s.incomeCount) income and \(s.expenseCount) expense entries. Transfers (\(s.transferCount)) and adjustments (\(s.adjustmentCount)) move money between accounts and are not counted as income or expense."
      )
      .font(LedgerTheme.Typeface.caption)
      .foregroundStyle(LedgerTheme.inkTertiary)
      // About 70 characters a line; the full card width ran to 115.
      .frame(maxWidth: 560, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
    }
    .ledgerCard()
  }

  @ViewBuilder
  private func figure(
    _ title: String, _ value: ExactDecimal, _ unit: String, negativeIsAlert: Bool = false
  ) -> some View {
    if let amount = try? CurrencyAmount(unitCode: unit, amount: value) {
      LedgerFigure(title, amount: amount, size: .figure, negativeIsAlert: negativeIsAlert)
    } else {
      VStack(alignment: .leading, spacing: LedgerTheme.Space.xxs) {
        Text(title).font(LedgerTheme.Typeface.caption).foregroundStyle(LedgerTheme.inkTertiary)
        Text(money(value, unit)).font(LedgerTheme.Typeface.figure).foregroundStyle(LedgerTheme.ink)
      }
      .accessibilityElement(children: .combine)
    }
  }

  // MARK: Categories

  @ViewBuilder
  private func categoryCard(
    _ title: String, _ rows: [LedgerCategoryStatistic], report: InsightsReport
  ) -> some View {
    if !rows.isEmpty {
      let top = rows.filter { $0.depth == 0 }
      let largest = top.map(\.totalAmount).max().map(Self.double) ?? 0
      VStack(alignment: .leading, spacing: LedgerTheme.Space.m) {
        LedgerCardHeader(title) { Text("\(top.count) categories") }
        VStack(alignment: .leading, spacing: 0) {
          ForEach(rows) { row in
            Button {
              drillDown = row
            } label: {
              categoryRow(row, in: rows, report: report, largest: largest)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
              "\(row.name), \(money(row.totalAmount, report.unitCode)), \(row.totalCount) entries"
            )
            .accessibilityHint("Shows the entries behind this amount.")
            if row.id != rows.last?.id { LedgerRowDivider() }
          }
        }
      }
      .ledgerCard()
    }
  }

  private func categoryRow(
    _ row: LedgerCategoryStatistic, in rows: [LedgerCategoryStatistic], report: InsightsReport,
    largest: Double
  ) -> some View {
    let topLevel = row.depth == 0
    // A subcategory takes its parent's colour so the bars and the rows read as one family.
    let key = topLevel ? row.name : (rows.first { $0.id == row.parentID }?.name ?? row.name)
    let tint = LedgerTheme.paletteColor(for: key)
    let share = largest > 0 ? Self.double(row.totalAmount) / largest : 0
    return VStack(alignment: .leading, spacing: LedgerTheme.Space.xs) {
      HStack(spacing: LedgerTheme.Space.s) {
        if topLevel {
          LedgerColorKey(tint)
        } else {
          Image(systemName: "arrow.turn.down.right")
            .font(LedgerTheme.Typeface.caption)
            .foregroundStyle(LedgerTheme.inkTertiary)
            .accessibilityHidden(true)
        }
        Text(row.name)
          .font(topLevel ? LedgerTheme.Typeface.bodyEmphasis : LedgerTheme.Typeface.body)
          .foregroundStyle(topLevel ? LedgerTheme.ink : LedgerTheme.inkSecondary)
          .lineLimit(1)
        Spacer(minLength: LedgerTheme.Space.s)
        Text("\(row.totalCount)")
          .font(LedgerTheme.Typeface.caption)
          .monospacedDigit()
          .foregroundStyle(LedgerTheme.inkTertiary)
          .frame(minWidth: 28, alignment: .trailing)
        if let amount = try? CurrencyAmount(unitCode: report.unitCode, amount: row.totalAmount) {
          MoneyText(amount, size: .row, sign: .never, tone: topLevel ? .neutral : .secondary)
            .frame(minWidth: 120, alignment: .trailing)
        } else {
          Text(money(row.totalAmount, report.unitCode))
            .font(LedgerTheme.Typeface.bodyEmphasis)
            .monospacedDigit()
            .foregroundStyle(LedgerTheme.ink)
            .frame(minWidth: 120, alignment: .trailing)
        }
      }
      if topLevel {
        LedgerProgressTrack(fraction: share, tint: tint, height: 4)
      }
    }
    .padding(.leading, CGFloat(row.depth) * LedgerTheme.Space.l)
    .padding(.vertical, LedgerTheme.Space.s)
    .contentShape(.rect)
  }

  // MARK: Trend

  private func trendCard(_ report: InsightsReport) -> some View {
    VStack(alignment: .leading, spacing: LedgerTheme.Space.m) {
      LedgerCardHeader("Trend") { Text("\(report.trend.count) \(report.kind == .year ? "years" : "months")") }
      HStack(spacing: LedgerTheme.Space.l) {
        legend("Income", LedgerTheme.positive)
        legend("Expense", LedgerTheme.ink)
      }
      Chart {
        ForEach(report.trend) { point in
          BarMark(
            x: .value("Period", label(point.period.start, report.kind)),
            y: .value("Amount", Self.double(point.income)), width: .ratio(0.7))
          .foregroundStyle(by: .value("Kind", "Income"))
          .position(by: .value("Kind", "Income"))
          .cornerRadius(2.5)
          BarMark(
            x: .value("Period", label(point.period.start, report.kind)),
            y: .value("Amount", Self.double(point.expense)), width: .ratio(0.7))
          .foregroundStyle(by: .value("Kind", "Expense"))
          .position(by: .value("Kind", "Expense"))
          .cornerRadius(2.5)
        }
      }
      .chartForegroundStyleScale(["Income": LedgerTheme.positive, "Expense": LedgerTheme.ink])
      .chartLegend(.hidden)
      .chartXAxis {
        AxisMarks { _ in
          AxisValueLabel().font(LedgerTheme.Typeface.caption).foregroundStyle(LedgerTheme.inkTertiary)
        }
      }
      .chartYAxis {
        AxisMarks(position: .leading) { value in
          AxisGridLine().foregroundStyle(LedgerTheme.hairlineSoft)
          AxisValueLabel {
            if let number = value.as(Double.self) {
              Text(formatter.compactAxis(number, unitCode: report.unitCode))
                .font(LedgerTheme.Typeface.caption)
                .foregroundStyle(LedgerTheme.inkTertiary)
            }
          }
        }
      }
      .frame(height: 180)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Trend chart, income and expense by \(report.kind == .year ? "year" : "month")")
      .accessibilityValue(trendSummary(report))
      Grid(alignment: .trailing, horizontalSpacing: LedgerTheme.Space.l, verticalSpacing: LedgerTheme.Space.s) {
        GridRow {
          Text("Period").gridColumnAlignment(.leading)
          Text("Income")
          Text("Expense")
          Text("Net")
        }
        .font(LedgerTheme.Typeface.captionEmphasis)
        .foregroundStyle(LedgerTheme.inkTertiary)
        ForEach(report.trend) { point in
          GridRow {
            Text(label(point.period.start, report.kind))
              .font(LedgerTheme.Typeface.secondary)
              .foregroundStyle(LedgerTheme.inkSecondary)
              .gridColumnAlignment(.leading)
            trendFigure(point.income, report.unitCode)
            trendFigure(point.expense, report.unitCode)
            trendFigure(point.net, report.unitCode, negativeIsAlert: true)
          }
          .accessibilityElement(children: .combine)
        }
      }
    }
    .ledgerCard()
  }

  @ViewBuilder
  private func trendFigure(_ value: ExactDecimal, _ unit: String, negativeIsAlert: Bool = false) -> some View {
    if let amount = try? CurrencyAmount(unitCode: unit, amount: value) {
      MoneyText(amount, size: .small, tone: .neutral, negativeIsAlert: negativeIsAlert)
    } else {
      Text(money(value, unit)).font(LedgerTheme.Typeface.secondary).monospacedDigit()
        .foregroundStyle(LedgerTheme.ink)
    }
  }

  private func trendSummary(_ report: InsightsReport) -> String {
    report.trend.map { point in
      "\(label(point.period.start, report.kind)): income \(money(point.income, report.unitCode)), expense \(money(point.expense, report.unitCode))"
    }.joined(separator: ". ")
  }

  private func legend(_ title: String, _ color: Color) -> some View {
    HStack(spacing: LedgerTheme.Space.xs) {
      LedgerColorKey(color)
      Text(title).font(LedgerTheme.Typeface.caption).foregroundStyle(LedgerTheme.inkSecondary)
    }
  }

  // MARK: Statement, table, status, export

  private func statementCard(_ report: InsightsReport) -> some View {
    let title = report.title(formatter)
    return VStack(alignment: .leading, spacing: LedgerTheme.Space.m) {
      LedgerCardHeader("Statement for \(title)")
      Toggle("Hide category names in the PDF", isOn: $hideNamesInPDF)
        .font(LedgerTheme.Typeface.secondary)
        .foregroundStyle(LedgerTheme.ink)
      HStack(spacing: LedgerTheme.Space.s) {
        Button("Export PDF for \(title)") {
          exportPeriodPDF?(report, title, hideNamesInPDF)
        }
        .buttonStyle(LedgerPrimaryButtonStyle())
        .disabled(exportPeriodPDF == nil)
      }
      if formatter.hidesAmounts {
        Text(LedgerProductSettings.hideAmountsExportNotice)
          .font(LedgerTheme.Typeface.caption).foregroundStyle(LedgerTheme.inkSecondary)
      }
      Text("Snapshot \(report.statistics.snapshotDigest.prefix(16)). The screen and the PDF show the same snapshot.")
        .font(LedgerTheme.Typeface.caption)
        .foregroundStyle(LedgerTheme.inkTertiary)
        .textSelection(.enabled)
    }
    .ledgerCard()
  }

  private var accessibleTableCard: some View {
    VStack(alignment: .leading, spacing: LedgerTheme.Space.m) {
      LedgerCardHeader("Accessible table")
      // The table is every figure again as text, so while amounts are hidden it says so
      // instead of showing a wall of masks (#173).
      let shownTable = formatter.hidesAmounts ? LedgerProductSettings.hiddenTableNotice : table
      Text(shownTable)
        .font(LedgerTheme.Typeface.mono)
        .foregroundStyle(LedgerTheme.ink)
        .textSelection(.enabled)
        .accessibilityLabel(shownTable)
        .accessibilityAddTraits(.isStaticText)
    }
    .ledgerCard()
  }

  private var statusCard: some View {
    VStack(alignment: .leading, spacing: LedgerTheme.Space.m) {
      LedgerCardHeader("Status")
      VStack(alignment: .leading, spacing: 0) {
        ForEach(rows) { row in
          LedgerKeyValue(row.title, row.detail)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(row.title), \(row.detail)")
          if row.id != rows.last?.id { LedgerRowDivider() }
        }
      }
      .padding(.horizontal, LedgerTheme.Space.m)
      .ledgerGroupBox()
    }
    .ledgerCard()
  }

  private var exportCard: some View {
    VStack(alignment: .leading, spacing: LedgerTheme.Space.m) {
      LedgerCardHeader("Export")
      Button("Export PDF statement", action: exportPDF)
        .buttonStyle(LedgerSecondaryButtonStyle())
        .accessibilityLabel("Export PDF statement")
      if formatter.hidesAmounts {
        Text(LedgerProductSettings.hideAmountsExportNotice)
          .font(LedgerTheme.Typeface.caption).foregroundStyle(LedgerTheme.inkSecondary)
      }
    }
    .ledgerCard()
  }

  private func money(_ value: ExactDecimal, _ unit: String) -> String {
    (try? CurrencyAmount(unitCode: unit, amount: value)).map(formatter.amount)
      ?? formatter.plain(value, unitCode: unit)
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
    VStack(alignment: .leading, spacing: LedgerTheme.Space.m) {
      HStack(spacing: LedgerTheme.Space.s) {
        LedgerColorKey(LedgerTheme.paletteColor(for: category.name))
        Text(category.name).font(LedgerTheme.Typeface.screenTitle).foregroundStyle(LedgerTheme.ink)
      }
      Text("\(entries.count) entries in \(report.title(formatter))")
        .font(LedgerTheme.Typeface.secondary)
        .foregroundStyle(LedgerTheme.inkSecondary)
      List(entries, id: \.id) { entry in
        let draft = entry.currentRevision.draft
        let amount = draft.effects.first { $0.amount.unitCode == report.unitCode }?.amount
        HStack(spacing: LedgerTheme.Space.m) {
          VStack(alignment: .leading, spacing: LedgerTheme.Space.xxs) {
            Text(formatter.date(draft.occurredAt.localDateTime.date))
              .font(LedgerTheme.Typeface.bodyEmphasis)
              .foregroundStyle(LedgerTheme.ink)
            Text(draft.note ?? draft.categoryID.flatMap { names[$0] } ?? draft.kind.rawValue)
              .font(LedgerTheme.Typeface.caption)
              .foregroundStyle(LedgerTheme.inkTertiary)
              .lineLimit(1)
          }
          Spacer(minLength: LedgerTheme.Space.s)
          if let amount { MoneyText(amount, size: .row, sign: .never, tone: .neutral) }
        }
        .padding(.vertical, LedgerTheme.Space.xs)
        .accessibilityElement(children: .combine)
      }
      .scrollContentBackground(.hidden)
      .frame(minWidth: 440, minHeight: 320)
      .ledgerGroupBox()
      HStack {
        Spacer()
        Button("Done", action: close)
          .buttonStyle(LedgerPrimaryButtonStyle())
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(LedgerTheme.Space.xl)
    .background(LedgerTheme.canvas)
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

/// The two halves of Insights.
enum InsightsSection: String, CaseIterable, Identifiable, Sendable {
  case statistics
  case review

  var id: Self { self }

  var title: String {
    switch self {
    case .statistics: "Statistics"
    case .review: "Review"
    }
  }
}
