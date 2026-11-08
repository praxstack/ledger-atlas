import Charts
import LedgerCore
import LedgerStore
import SwiftUI

/// Insights › Review (#239): Month in Review and Year in Review for any finished period with
/// entries. Read-only; every amount goes through the display formatter, so Hide amounts
/// masks it.
struct InsightsRecapView: View {
  let snapshot: LedgerStore.LedgerReadSnapshot
  var settings = LedgerProductSettings()
  /// Fixed in captures, so the list of finished periods doesn't depend on the day they run.
  var today: SourceLocalDate? = nil

  @Environment(\.ledgerFormatter) private var formatter
  @State private var chosen: LedgerRecapPeriod?
  @State private var recap: LedgerPeriodRecap?

  init(
    snapshot: LedgerStore.LedgerReadSnapshot, settings: LedgerProductSettings = .init(),
    today: SourceLocalDate? = nil, period: LedgerRecapPeriod? = nil
  ) {
    self.snapshot = snapshot
    self.settings = settings
    self.today = today
    _chosen = State(initialValue: period)
  }

  static let emptyTitle = "Nothing to review yet"
  static let emptyText =
    "A recap of each month and year appears here once it has ended and has entries."

  private var periods: [LedgerRecapPeriod] {
    LedgerRecapPeriod.finished(
      in: snapshot.transactions, today: today ?? LedgerPeriodRule.today(in: settings.timeZone))
  }

  private var categoryNames: [String: String] {
    Dictionary(
      snapshot.categories.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
  }

  /// What the recap depends on: the period and the ledger's contents. An edit or a deletion
  /// adds a revision; accounts, categories and budgets are hashed field by field, so a
  /// change that keeps their counts still rebuilds the recap.
  private struct Key: Hashable {
    let period: LedgerRecapPeriod?
    let ledger: Int
  }

  private static func ledgerKey(_ snapshot: LedgerStore.LedgerReadSnapshot) -> Int {
    var hasher = Hasher()
    hasher.combine(snapshot.transactions.count)
    hasher.combine(snapshot.revisionHistory.count)
    for account in snapshot.accounts {
      hasher.combine(account.id)
      hasher.combine(account.currencyUnit)
      hasher.combine(account.countsInTotals)
    }
    for category in snapshot.categories {
      hasher.combine(category.id)
      hasher.combine(category.name)
      hasher.combine(category.parentID)
    }
    for budget in snapshot.budgets {
      hasher.combine(budget.id)
      hasher.combine(budget.categoryID)
      hasher.combine(budget.amount.unitCode)
      hasher.combine(budget.amount.amount.description)
      hasher.combine(budget.period)
      hasher.combine(budget.rollover)
      hasher.combine(budget.start)
      hasher.combine(budget.lifecycle)
    }
    return hasher.finalize()
  }

  var body: some View {
    let periods = periods
    let period = chosen ?? periods.first
    if let period {
      LedgerCardColumn(maxWidth: 820) {
        pickerCard(period, periods)
        if let recap, recap.period == period {
          recapCards(recap)
        }
      }
      .task(id: Key(period: period, ledger: Self.ledgerKey(snapshot))) {
        let snapshot = snapshot
        let built = await Task.detached(priority: .userInitiated) {
          try? LedgerPeriodRecap(
            period: period, accounts: snapshot.accounts, categories: snapshot.categories,
            transactions: snapshot.transactions, budgets: snapshot.budgets)
        }.value
        guard !Task.isCancelled else { return }
        recap = built
      }
    } else {
      LedgerEmptyState(Self.emptyTitle, systemImage: "calendar", message: Self.emptyText) {
        EmptyView()
      }
      .ledgerCanvas()
    }
  }

  // MARK: Cards

  private func pickerCard(_ period: LedgerRecapPeriod, _ periods: [LedgerRecapPeriod])
    -> some View
  {
    HStack(spacing: LedgerTheme.Space.m) {
      Text(Self.title(period, formatter: formatter))
        .font(LedgerTheme.Typeface.screenTitle)
        .foregroundStyle(LedgerTheme.ink)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: LedgerTheme.Space.s)
      Picker(
        "Recap", selection: Binding(get: { period }, set: { chosen = $0 })
      ) {
        ForEach(periods) { option in
          Text(Self.name(option, formatter: formatter)).tag(option)
        }
      }
      .pickerStyle(.menu)
      .fixedSize()
      .accessibilityLabel("Recap period")
      .help("Every finished month and year with entries, newest first")
    }
    .ledgerCard()
  }

  @ViewBuilder private func recapCards(_ recap: LedgerPeriodRecap) -> some View {
    let before = Self.name(recap.period.previous, formatter: formatter)
    ForEach(recap.currencies) { currency in
      figuresCard(currency, before: before, showsUnit: recap.currencies.count > 1)
      if !currency.topCategories.isEmpty {
        categoriesCard(currency, before: before)
      }
      if !currency.biggestExpenses.isEmpty {
        expensesCard(currency)
      }
      if recap.period.kind == .year {
        monthsCard(currency)
      }
    }
    activityCard(recap)
  }

  private func figuresCard(
    _ currency: LedgerPeriodRecap.Currency, before: String, showsUnit: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: LedgerTheme.Space.l) {
      LedgerCardHeader(showsUnit ? "Money in \(currency.unitCode)" : "Money") { EmptyView() }
      HStack(alignment: .top, spacing: LedgerTheme.Space.xxl) {
        figure("Money in", currency.income, currency.previousIncome, currency.unitCode, before)
        figure("Spending", currency.expense, currency.previousExpense, currency.unitCode, before)
        figure(
          "Net", currency.net, currency.previousNet, currency.unitCode, before,
          negativeIsAlert: true)
        Spacer(minLength: 0)
      }
      Text("Transfers and adjustments move money between accounts and are not counted.")
        .font(LedgerTheme.Typeface.caption)
        .foregroundStyle(LedgerTheme.inkTertiary)
    }
    .ledgerCard()
  }

  @ViewBuilder private func figure(
    _ title: String, _ value: ExactDecimal, _ previous: ExactDecimal, _ unit: String,
    _ before: String, negativeIsAlert: Bool = false
  ) -> some View {
    VStack(alignment: .leading, spacing: LedgerTheme.Space.xxs) {
      if let amount = try? CurrencyAmount(unitCode: unit, amount: value) {
        LedgerFigure(title, amount: amount, size: .figure, negativeIsAlert: negativeIsAlert)
      }
      Text(Self.change(value, from: previous, unit: unit, before: before, formatter: formatter))
        .font(LedgerTheme.Typeface.caption)
        .foregroundStyle(LedgerTheme.inkSecondary)
    }
    .accessibilityElement(children: .combine)
  }

  private func categoriesCard(_ currency: LedgerPeriodRecap.Currency, before: String)
    -> some View
  {
    VStack(alignment: .leading, spacing: LedgerTheme.Space.s) {
      LedgerCardHeader("Top spending") { EmptyView() }
      ForEach(currency.topCategories) { share in
        HStack(spacing: LedgerTheme.Space.m) {
          Text(share.name)
            .font(LedgerTheme.Typeface.body)
            .foregroundStyle(LedgerTheme.ink)
            .lineLimit(1)
          Text("\(share.percent)%")
            .font(LedgerTheme.Typeface.caption.monospacedDigit())
            .foregroundStyle(LedgerTheme.inkTertiary)
          Spacer(minLength: LedgerTheme.Space.s)
          if let previous = share.previousAmount {
            Text(
              Self.change(
                share.amount, from: previous, unit: currency.unitCode, before: before,
                formatter: formatter)
            )
            .font(LedgerTheme.Typeface.caption)
            .foregroundStyle(LedgerTheme.inkSecondary)
          }
          if let amount = try? CurrencyAmount(unitCode: currency.unitCode, amount: share.amount) {
            MoneyText(amount, size: .row, sign: .never, tone: .neutral)
          }
        }
        .accessibilityElement(children: .combine)
      }
    }
    .ledgerCard()
  }

  private func expensesCard(_ currency: LedgerPeriodRecap.Currency) -> some View {
    VStack(alignment: .leading, spacing: LedgerTheme.Space.s) {
      LedgerCardHeader("Biggest expenses") { EmptyView() }
      ForEach(currency.biggestExpenses) { expense in
        HStack(spacing: LedgerTheme.Space.m) {
          VStack(alignment: .leading, spacing: LedgerTheme.Space.xxs) {
            Text(
              expense.categoryID.flatMap { categoryNames[$0] } ?? expense.note ?? "Expense"
            )
            .font(LedgerTheme.Typeface.body)
            .foregroundStyle(LedgerTheme.ink)
            .lineLimit(1)
            Text(formatter.date(expense.date))
              .font(LedgerTheme.Typeface.caption)
              .foregroundStyle(LedgerTheme.inkTertiary)
          }
          Spacer(minLength: LedgerTheme.Space.s)
          if let amount = try? CurrencyAmount(unitCode: currency.unitCode, amount: expense.amount)
          {
            MoneyText(amount, size: .row, sign: .never, tone: .neutral)
          }
        }
        .accessibilityElement(children: .combine)
      }
    }
    .ledgerCard()
  }

  private func monthsCard(_ currency: LedgerPeriodRecap.Currency) -> some View {
    VStack(alignment: .leading, spacing: LedgerTheme.Space.m) {
      LedgerCardHeader("Spending by month") { EmptyView() }
      Chart(currency.months) { month in
        BarMark(
          x: .value("Month", Self.shortMonth(month.month, formatter: formatter)),
          y: .value("Spending", InsightsSurface.double(month.expense)), width: .ratio(0.7)
        )
        .foregroundStyle(LedgerTheme.ink)
        .cornerRadius(2.5)
      }
      .chartYAxis {
        AxisMarks(position: .leading) { value in
          AxisGridLine().foregroundStyle(LedgerTheme.hairlineSoft)
          AxisValueLabel {
            if let number = value.as(Double.self) {
              Text(formatter.compactAxis(number, unitCode: currency.unitCode))
                .font(LedgerTheme.Typeface.caption)
                .foregroundStyle(LedgerTheme.inkTertiary)
            }
          }
        }
      }
      .frame(height: 160)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Spending by month")
      .accessibilityValue(monthsSummary(currency))
      if let best = currency.bestMonth, let worst = currency.worstMonth {
        Text(Self.bestAndWorst(best, worst, unit: currency.unitCode, formatter: formatter))
          .font(LedgerTheme.Typeface.secondary)
          .foregroundStyle(LedgerTheme.inkSecondary)
      }
    }
    .ledgerCard()
  }

  private func monthsSummary(_ currency: LedgerPeriodRecap.Currency) -> String {
    currency.months.map {
      "\(Self.shortMonth($0.month, formatter: formatter)): \(Self.money($0.expense, currency.unitCode, formatter))"
    }.joined(separator: ". ")
  }

  private func activityCard(_ recap: LedgerPeriodRecap) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      LedgerCardHeader("Activity") { EmptyView() }
      LedgerKeyValue("Entries", "\(recap.entryCount)")
      if let busiest = recap.busiestDay {
        LedgerKeyValue(
          "Busiest day",
          "\(formatter.date(busiest)), \(recap.busiestDayCount) \(recap.busiestDayCount == 1 ? "entry" : "entries")"
        )
      }
      LedgerKeyValue("Days with no entries", "\(recap.daysWithoutEntries)")
      if recap.budgetsKept + recap.budgetsOverspent > 0 {
        LedgerKeyValue(
          "Budgets", Self.budgetsText(kept: recap.budgetsKept, overspent: recap.budgetsOverspent))
      }
    }
    .ledgerCard()
  }

  // MARK: Words

  /// "October 2026 in review" or "2025 in review".
  static func title(_ period: LedgerRecapPeriod, formatter: LedgerDisplayFormatter) -> String {
    "\(name(period, formatter: formatter)) in review"
  }

  /// "October 2026" or "2025".
  static func name(_ period: LedgerRecapPeriod, formatter: LedgerDisplayFormatter) -> String {
    guard period.kind == .month, let first = try? period.first else { return "\(period.year)" }
    return formatter.monthTitle(first)
  }

  static func shortMonth(_ month: Int, formatter: LedgerDisplayFormatter) -> String {
    guard let date = try? SourceLocalDate(year: 2001, month: month, day: 1) else { return "" }
    return formatter.shortMonth(date)
  }

  /// "Up ₹500.00 on September 2026", "Down …", or "Same as …". With amounts hidden the size
  /// and the direction are both hidden.
  static func change(
    _ value: ExactDecimal, from previous: ExactDecimal, unit: String, before: String,
    formatter: LedgerDisplayFormatter
  ) -> String {
    guard let difference = try? value.subtracting(previous) else { return "" }
    if formatter.hidesAmounts {
      return "\(money(difference, unit, formatter)) against \(before)"
    }
    if !difference.isPositive && !difference.isNegative { return "Same as \(before)" }
    let size =
      difference.isNegative
      ? ((try? ExactDecimal("0").subtracting(difference)) ?? difference) : difference
    return "\(difference.isNegative ? "Down" : "Up") \(money(size, unit, formatter)) on \(before)"
  }

  static func bestAndWorst(
    _ best: LedgerPeriodRecap.MonthFigures, _ worst: LedgerPeriodRecap.MonthFigures,
    unit: String, formatter: LedgerDisplayFormatter
  ) -> String {
    func month(_ figures: LedgerPeriodRecap.MonthFigures) -> String {
      guard let date = try? SourceLocalDate(year: 2001, month: figures.month, day: 1) else {
        return ""
      }
      return formatter.monthName(date)
    }
    let sign = LedgerDisplayFormatter.SignStyle.always
    return
      "Best month: \(month(best)), net \(money(best.net, unit, formatter, sign: sign)). Hardest month: \(month(worst)), net \(money(worst.net, unit, formatter, sign: sign))."
  }

  static func budgetsText(kept: Int, overspent: Int) -> String {
    "\(kept) kept, \(overspent) overspent"
  }

  static func money(
    _ value: ExactDecimal, _ unit: String, _ formatter: LedgerDisplayFormatter,
    sign: LedgerDisplayFormatter.SignStyle = .never
  ) -> String {
    guard let amount = try? CurrencyAmount(unitCode: unit, amount: value) else {
      return formatter.plain(value, unitCode: unit)
    }
    return formatter.parts(amount, sign: sign).text
  }
}
