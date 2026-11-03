import Charts
import LedgerCore
import LedgerStore
import SwiftUI

/// The first screen once a ledger is open: net worth and how it moved, this month's money in
/// and out, where it went, budgets, and the latest entries. Each chart has a spoken summary,
/// and every figure also appears as text.
struct OverviewSurface: View {
  let snapshot: LedgerStore.LedgerReadSnapshot?
  let settings: LedgerProductSettings
  let show: (AppDestination) -> Void

  @State private var model: OverviewModel?
  @Environment(\.ledgerFormatter) private var formatter

  var body: some View {
    ScrollView {
      if let model {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: LedgerTheme.Space.l) {
            leftColumn(model).frame(minWidth: 440)
            rightColumn(model).frame(width: 330)
          }
          VStack(spacing: LedgerTheme.Space.l) {
            leftColumn(model)
            rightColumn(model)
          }
        }
        .padding(LedgerTheme.Space.xxl)
      } else if snapshot != nil {
        ProgressView("Adding up your ledger…")
          .frame(maxWidth: .infinity)
          .padding(LedgerTheme.Space.xxxl)
      }
    }
    .ledgerCanvas()
    .navigationTitle("Overview")
    .navigationSubtitle(model.map { formatter.monthTitle($0.month.period.start) } ?? "")
    .task(id: snapshotKey) {
      guard let snapshot else {
        model = nil
        return
      }
      let today = LedgerPeriodRule.today(in: settings.timeZone)
      let rule = settings.periodRule
      let built = await Task.detached(priority: .userInitiated) {
        try? OverviewModel(snapshot: snapshot, today: today, rule: rule)
      }.value
      guard !Task.isCancelled else { return }
      model = built
    }
  }

  /// Changes whenever an edit lands (every edit adds a revision) or settings move the period.
  private var snapshotKey: Int {
    var hasher = Hasher()
    hasher.combine(snapshot?.transactions.count)
    hasher.combine(snapshot?.revisionHistory.count)
    hasher.combine(snapshot?.accounts.count)
    hasher.combine(snapshot?.budgets.count)
    hasher.combine(settings.periodRule)
    hasher.combine(settings.timeZone.identifier)
    return hasher.finalize()
  }

  // MARK: Columns

  private func leftColumn(_ model: OverviewModel) -> some View {
    VStack(spacing: LedgerTheme.Space.l) {
      NetWorthCard(model: model)
      RecentCard(lines: model.recent) { show(.ledger) }
    }
  }

  private func rightColumn(_ model: OverviewModel) -> some View {
    VStack(spacing: LedgerTheme.Space.l) {
      CashFlowCard(model: model)
      SpendingCard(model: model) { show(.insights) }
      if !model.budgets.isEmpty {
        BudgetsCard(lines: Array(model.budgets.prefix(5))) { show(.budgets) }
      }
    }
  }
}

// MARK: - Net worth

private struct NetWorthCard: View {
  let model: OverviewModel
  @Environment(\.ledgerFormatter) private var formatter

  var body: some View {
    VStack(alignment: .leading, spacing: LedgerTheme.Space.l) {
      VStack(alignment: .leading, spacing: LedgerTheme.Space.xs) {
        Text("Net worth")
          .font(LedgerTheme.Typeface.captionEmphasis)
          .foregroundStyle(LedgerTheme.inkSecondary)
          .accessibilityAddTraits(.isHeader)
        HStack(alignment: .firstTextBaseline, spacing: LedgerTheme.Space.m) {
          MoneyText(model.netWorth, size: .hero, negativeIsAlert: true)
          if let change = model.monthChange, change.amount.isPositive || change.amount.isNegative {
            HStack(spacing: LedgerTheme.Space.xxs) {
              Image(systemName: change.amount.isNegative ? "arrow.down.right" : "arrow.up.right")
                .accessibilityHidden(true)
              MoneyText(change, size: .small, sign: .always, tone: .automatic, negativeIsAlert: true)
              Text("this month").foregroundStyle(LedgerTheme.inkTertiary)
            }
            .font(LedgerTheme.Typeface.secondary)
          }
        }
      }
      NetWorthChart(points: model.history, unitCode: model.unitCode)
        .frame(height: 170)
      Divider().overlay(LedgerTheme.hairlineSoft)
      HStack(spacing: 0) {
        figure("Money in", model.month.statistics.income, sign: .always, positive: true)
        Divider().frame(height: 36)
        figure("Spending", model.month.statistics.expense, sign: .never, positive: false)
        Divider().frame(height: 36)
        figure("Saved", model.month.statistics.net, sign: .always, positive: false)
      }
    }
    .ledgerCard()
  }

  private func figure(
    _ label: String, _ value: ExactDecimal, sign: LedgerDisplayFormatter.SignStyle, positive: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: LedgerTheme.Space.xxs) {
      Text(label).font(LedgerTheme.Typeface.caption).foregroundStyle(LedgerTheme.inkTertiary)
      if let amount = try? CurrencyAmount(unitCode: model.unitCode, amount: value) {
        MoneyText(amount, size: .figure, sign: sign, tone: positive ? .automatic : .neutral)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, LedgerTheme.Space.m)
    .accessibilityElement(children: .combine)
  }
}

private struct NetWorthChart: View {
  let points: [OverviewModel.NetWorthPoint]
  let unitCode: String
  @Environment(\.ledgerFormatter) private var formatter

  var body: some View {
    Chart(points) { point in
      AreaMark(
        x: .value("Month", formatter.shortMonth(point.month)),
        y: .value("Net worth", OverviewModel.double(point.value))
      )
      .foregroundStyle(
        LinearGradient(colors: [LedgerTheme.accentSoft, .clear], startPoint: .top, endPoint: .bottom))
      .interpolationMethod(.monotone)
      LineMark(
        x: .value("Month", formatter.shortMonth(point.month)),
        y: .value("Net worth", OverviewModel.double(point.value))
      )
      .foregroundStyle(LedgerTheme.accent)
      .lineStyle(StrokeStyle(lineWidth: 1.75, lineCap: .round))
      .interpolationMethod(.monotone)
      if point.id == points.last?.id {
        PointMark(
          x: .value("Month", formatter.shortMonth(point.month)),
          y: .value("Net worth", OverviewModel.double(point.value))
        )
        .foregroundStyle(LedgerTheme.accent)
        .symbolSize(40)
      }
    }
    .chartYAxis {
      AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
        AxisGridLine().foregroundStyle(LedgerTheme.hairlineSoft)
        AxisValueLabel {
          if let number = value.as(Double.self) {
            Text(formatter.compactAxis(number, unitCode: unitCode))
              .font(LedgerTheme.Typeface.caption)
              .foregroundStyle(LedgerTheme.inkTertiary)
          }
        }
      }
    }
    .chartXAxis {
      AxisMarks { _ in
        AxisValueLabel().font(LedgerTheme.Typeface.caption).foregroundStyle(LedgerTheme.inkTertiary)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Net worth over the last \(points.count) months")
    .accessibilityValue(summary)
  }

  private var summary: String {
    guard let first = points.first, let last = points.last,
      let start = try? CurrencyAmount(unitCode: unitCode, amount: first.value),
      let end = try? CurrencyAmount(unitCode: unitCode, amount: last.value)
    else { return "No data" }
    return
      "From \(formatter.parts(start).text) in \(formatter.shortMonth(first.month)) to \(formatter.parts(end).text) in \(formatter.shortMonth(last.month))"
  }
}

// MARK: - Cash flow

private struct CashFlowCard: View {
  let model: OverviewModel
  @Environment(\.ledgerFormatter) private var formatter

  private struct Bar: Identifiable {
    let month: String
    let series: String
    let value: Double
    let isCurrent: Bool
    var id: String { month + series }
  }

  private var bars: [Bar] {
    let last = model.month.trend.last?.id
    return model.month.trend.flatMap { point in
      [
        Bar(
          month: formatter.shortMonth(point.period.start), series: "Money in",
          value: OverviewModel.double(point.income), isCurrent: point.id == last),
        Bar(
          month: formatter.shortMonth(point.period.start), series: "Spending",
          value: OverviewModel.double(point.expense), isCurrent: point.id == last),
      ]
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: LedgerTheme.Space.m) {
      LedgerCardHeader("Cash flow") { Text("6 months") }
      HStack(spacing: LedgerTheme.Space.l) {
        key("Money in", LedgerTheme.positive)
        key("Spending", LedgerTheme.ink)
      }
      Chart(bars) { bar in
        BarMark(
          x: .value("Month", bar.month), y: .value("Amount", bar.value), width: .ratio(0.7)
        )
        .position(by: .value("Series", bar.series))
        .foregroundStyle(color(bar))
        .cornerRadius(2.5)
      }
      .chartLegend(.hidden)
      .chartYAxis(.hidden)
      .chartXAxis {
        AxisMarks { _ in
          AxisValueLabel().font(LedgerTheme.Typeface.caption).foregroundStyle(LedgerTheme.inkTertiary)
        }
      }
      .frame(height: 120)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Cash flow, last six months")
      .accessibilityValue(summary)
    }
    .ledgerCard()
  }

  private func color(_ bar: Bar) -> Color {
    switch (bar.series == "Money in", bar.isCurrent) {
    case (true, true): LedgerTheme.positive
    case (true, false): LedgerTheme.positiveSoft
    case (false, true): LedgerTheme.ink
    case (false, false): LedgerTheme.inkSoft
    }
  }

  private func key(_ title: String, _ color: Color) -> some View {
    HStack(spacing: LedgerTheme.Space.xs) {
      LedgerColorKey(color)
      Text(title).font(LedgerTheme.Typeface.caption).foregroundStyle(LedgerTheme.inkSecondary)
    }
  }

  private var summary: String {
    model.month.trend.compactMap { point -> String? in
      guard let income = try? CurrencyAmount(unitCode: model.unitCode, amount: point.income),
        let expense = try? CurrencyAmount(unitCode: model.unitCode, amount: point.expense)
      else { return nil }
      return
        "\(formatter.shortMonth(point.period.start)): in \(formatter.parts(income).text), spent \(formatter.parts(expense).text)"
    }.joined(separator: ". ")
  }
}

// MARK: - Spending

private struct SpendingCard: View {
  let model: OverviewModel
  let showAll: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: LedgerTheme.Space.m) {
      LedgerCardHeader("Spending by category") {
        Button("Insights", action: showAll).buttonStyle(.link)
          .accessibilityHint("Shows every category on the Insights screen.")
      }
      if model.spending.isEmpty {
        Text("No spending this month.")
          .font(LedgerTheme.Typeface.secondary)
          .foregroundStyle(LedgerTheme.inkTertiary)
      }
      ForEach(model.spending) { line in
        VStack(alignment: .leading, spacing: LedgerTheme.Space.xs) {
          HStack(spacing: LedgerTheme.Space.s) {
            LedgerColorKey(LedgerTheme.paletteColor(for: line.name))
            Text(line.name).font(LedgerTheme.Typeface.body).foregroundStyle(LedgerTheme.ink).lineLimit(1)
            Spacer(minLength: LedgerTheme.Space.s)
            if let amount = try? CurrencyAmount(unitCode: model.unitCode, amount: line.amount) {
              MoneyText(amount, size: .small, sign: .never, tone: .neutral)
            }
            Text(line.share.formatted(.percent.precision(.fractionLength(0))))
              .font(LedgerTheme.Typeface.caption)
              .monospacedDigit()
              .foregroundStyle(LedgerTheme.inkTertiary)
              .frame(minWidth: 36, alignment: .trailing)
          }
          LedgerProgressTrack(
            fraction: line.share, tint: LedgerTheme.paletteColor(for: line.name), height: 4)
        }
        .accessibilityElement(children: .combine)
      }
    }
    .ledgerCard()
  }
}

// MARK: - Budgets

private struct BudgetsCard: View {
  let lines: [OverviewModel.BudgetLine]
  let showAll: () -> Void
  @Environment(\.ledgerFormatter) private var formatter

  var body: some View {
    VStack(alignment: .leading, spacing: LedgerTheme.Space.m) {
      LedgerCardHeader("Budgets") {
        Button("All budgets", action: showAll).buttonStyle(.link)
          .accessibilityHint("Shows the Budgets screen.")
      }
      ForEach(lines) { line in
        VStack(alignment: .leading, spacing: LedgerTheme.Space.xs) {
          HStack(alignment: .firstTextBaseline) {
            Text(line.name).font(LedgerTheme.Typeface.body).foregroundStyle(LedgerTheme.ink).lineLimit(1)
            Spacer(minLength: LedgerTheme.Space.s)
            Text(status(line))
              .font(LedgerTheme.Typeface.caption)
              .foregroundStyle(line.isOver ? LedgerTheme.negative : LedgerTheme.inkTertiary)
          }
          LedgerProgressTrack(fraction: line.fraction, tint: LedgerTheme.ink, height: 6)
        }
        .accessibilityElement(children: .combine)
      }
    }
    .ledgerCard()
  }

  private func status(_ line: OverviewModel.BudgetLine) -> String {
    let spent = formatter.parts(line.spent, sign: .never).text
    let available = formatter.parts(line.available, sign: .never).text
    if line.isOver {
      return "\(spent) of \(available), over by \(formatter.parts(line.remaining, sign: .never).text)"
    }
    return "\(spent) of \(available)"
  }
}

// MARK: - Recent

private struct RecentCard: View {
  let lines: [OverviewModel.RecentLine]
  let showAll: () -> Void
  @Environment(\.ledgerFormatter) private var formatter

  var body: some View {
    VStack(alignment: .leading, spacing: LedgerTheme.Space.s) {
      LedgerCardHeader("Recent transactions") {
        Button("All transactions", action: showAll).buttonStyle(.link)
          .accessibilityHint("Shows the Transactions screen.")
      }
      if lines.isEmpty {
        Text("No transactions yet.")
          .font(LedgerTheme.Typeface.secondary)
          .foregroundStyle(LedgerTheme.inkTertiary)
      }
      ForEach(lines) { line in
        HStack(spacing: LedgerTheme.Space.m) {
          LedgerIconTile(
            .initials(Self.initials(line.title)), swatch: LedgerTheme.swatch(for: line.title))
          VStack(alignment: .leading, spacing: LedgerTheme.Space.xxs) {
            Text(line.title).font(LedgerTheme.Typeface.body).foregroundStyle(LedgerTheme.ink).lineLimit(1)
            Text(line.detail).font(LedgerTheme.Typeface.caption).foregroundStyle(LedgerTheme.inkTertiary)
              .lineLimit(1)
          }
          Spacer(minLength: LedgerTheme.Space.s)
          VStack(alignment: .trailing, spacing: LedgerTheme.Space.xxs) {
            MoneyText(line.amount, size: .row, sign: line.sign)
            Text(formatter.date(line.day, style: .medium))
              .font(LedgerTheme.Typeface.caption)
              .foregroundStyle(LedgerTheme.inkTertiary)
          }
        }
        .frame(minHeight: LedgerTheme.Metrics.tableRow)
        .accessibilityElement(children: .combine)
        if line.id != lines.last?.id { Divider().overlay(LedgerTheme.hairlineSoft) }
      }
    }
    .ledgerCard()
  }

  static func initials(_ title: String) -> String {
    let words = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2)
    let letters = words.compactMap(\.first).map { String($0).uppercased() }.joined()
    return letters.isEmpty ? "·" : letters
  }
}
