import CryptoKit
import Foundation
import LedgerCore
import SwiftUI

private enum PlanningSupport {
  static func date(_ text: String) -> SourceLocalDate? {
    let parts = text.split(separator: "-")
    guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]),
      let day = Int(parts[2])
    else { return nil }
    return try? SourceLocalDate(year: year, month: month, day: day)
  }

  static func today() -> SourceLocalDate {
    let components = Calendar.current.dateComponents([.year, .month, .day], from: .now)
    return (try? SourceLocalDate(
      year: components.year ?? 2000, month: components.month ?? 1, day: components.day ?? 1))!
  }

  static func todayText() -> String {
    let date = today()
    return String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
  }

  /// The first date on or after `day` the rule still produces, nil once it has ended.
  static func nextDate(of rule: LedgerRecurrenceRule, onOrAfter day: SourceLocalDate) -> SourceLocalDate? {
    let skipped = Set(rule.skippedDates)
    for index in firstIndex(of: rule, near: day)..<LedgerSchedule.maximumOccurrences {
      guard let date = try? LedgerSchedule.occurrence(
        index, from: rule.start, frequency: rule.frequency, interval: rule.interval,
        dayOfMonth: rule.dayOfMonth)
      else { return nil }
      if let until = rule.until, date > until { return nil }
      if date >= day, !skipped.contains(date) { return date }
    }
    return nil
  }

  /// An occurrence index just before `day`, so `nextDate` skips the rule's history instead of
  /// walking it from the start.
  private static func firstIndex(of rule: LedgerRecurrenceRule, near day: SourceLocalDate) -> Int {
    let start = rule.start
    let steps: Int
    switch rule.frequency {
    case .monthly:
      steps = ((day.year - start.year) * 12 + day.month - start.month) / rule.interval
    case .yearly:
      steps = (day.year - start.year) / rule.interval
    case .daily, .weekly:
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
      guard
        let from = calendar.date(from: DateComponents(year: start.year, month: start.month, day: start.day)),
        let to = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)),
        let days = calendar.dateComponents([.day], from: from, to: to).day
      else { return 0 }
      steps = (rule.frequency == .weekly ? days / 7 : days) / rule.interval
    }
    return min(max(0, steps - 1), LedgerSchedule.maximumOccurrences - 1)
  }

  static func generatedID(_ prefix: String) -> String {
    SHA256.hash(data: Data("ledger-atlas/\(prefix)/\(UUID().uuidString)".utf8))
      .map { String(format: "%02x", $0) }.joined()
  }
}

struct RecurrenceView: View {
  let state: LedgerSession.State
  let rules: [LedgerRecurrenceRule]
  let accounts: [LedgerAccount]
  let categories: [LedgerCategory]
  let isEditing: Bool
  let lastFailure: String?
  let beginEditing: () -> Void
  let onCreate: (LedgerRecurrenceRule) -> Void
  let onUpdate: (LedgerRecurrenceRule, LedgerEditScope) -> Void
  let onGenerate: (LedgerRecurrenceRule, SourceLocalDate) -> Void
  let open: () -> Void
  /// The ledger's time zone from settings, for which day is "today".
  var timeZone: TimeZone = .current
  /// What is due soon (#171), shown beside the rules while a ledger is open.
  var upcoming: LedgerUpcoming? = nil
  @State private var showingForm = false

  var body: some View {
    let today = LedgerPeriodRule.today(in: timeZone)
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 0) {
        rulesList(today: today).frame(maxWidth: .infinity, maxHeight: .infinity)
        if let upcoming {
          Divider()
          UpcomingPanel(upcoming: upcoming, accounts: accounts, categories: categories)
            .frame(width: 320)
        }
      }
      LedgerActionBar {
        if isEditing {
          Button("New recurrence") { showingForm = true }.buttonStyle(LedgerPrimaryButtonStyle())
        } else if !rules.isEmpty || state.isLoaded {
          Button("Begin editing", action: beginEditing).buttonStyle(LedgerSecondaryButtonStyle())
        } else {
          Button("Open Ledger…", action: open).buttonStyle(LedgerPrimaryButtonStyle())
        }
        if let lastFailure { LedgerStatusLine(failure: lastFailure) }
      }
    }
    .ledgerCanvas()
    .navigationTitle("Recurring")
    .sheet(isPresented: $showingForm) {
      RecurrenceForm(accounts: accounts, categories: categories, onSave: onCreate)
    }
  }

  @ViewBuilder private func rulesList(today: SourceLocalDate) -> some View {
    if rules.isEmpty {
      PlanningEmptyView(
        title: "Nothing recurring yet", systemImage: "repeat",
        message: "Rent, salary and subscriptions can be added on their dates automatically.",
        state: state, isEditing: isEditing, failure: lastFailure, open: open)
    } else {
      List(rules, id: \.id) { rule in
        RecurrenceRow(
          rule: rule, accountName: accounts.first(where: { $0.id == rule.accountID })?.name,
          categoryName: categories.first(where: { $0.id == rule.categoryID })?.name,
          today: today, isEditing: isEditing,
          toggle: { onUpdate($0, .thisAndFuture) },
          generate: { onGenerate(rule, today) })
      }
      .scrollContentBackground(.hidden)
    }
  }
}

private struct RecurrenceRow: View {
  @Environment(\.ledgerFormatter) private var formatter
  let rule: LedgerRecurrenceRule
  let accountName: String?
  let categoryName: String?
  let today: SourceLocalDate
  let isEditing: Bool
  let toggle: (LedgerRecurrenceRule) -> Void
  let generate: () -> Void

  private var cadence: String {
    let unit: String =
      switch rule.frequency {
      case .daily: rule.interval == 1 ? "day" : "days"
      case .weekly: rule.interval == 1 ? "week" : "weeks"
      case .monthly: rule.interval == 1 ? "month" : "months"
      case .yearly: rule.interval == 1 ? "year" : "years"
      }
    return rule.interval == 1 ? "Every \(unit)" : "Every \(rule.interval) \(unit)"
  }

  var body: some View {
    let schedule = self.schedule
    HStack(spacing: LedgerTheme.Space.m) {
      // The category's own symbol and colour, as on Transactions and Categories.
      LedgerIconTile(
        .symbol(LedgerCategorySymbol.name(for: categoryName, kind: rule.kind)),
        swatch: LedgerTheme.swatch(for: categoryName ?? accountName ?? rule.id))
      VStack(alignment: .leading, spacing: LedgerTheme.Space.xxs) {
        HStack(alignment: .firstTextBaseline, spacing: LedgerTheme.Space.s) {
          Text(categoryName ?? rule.kind.rawValue.capitalized)
            .font(LedgerTheme.Typeface.bodyEmphasis)
            .foregroundStyle(rule.lifecycle == .active ? LedgerTheme.ink : LedgerTheme.inkTertiary)
            .strikethrough(rule.lifecycle == .tombstoned)
          Spacer(minLength: LedgerTheme.Space.s)
          MoneyText(
            rule.amount, size: .row, sign: rule.kind == .income ? .always : .never,
            tone: rule.lifecycle == .active ? .automatic : .secondary)
        }
        Text([cadence, schedule, accountName].compactMap { $0 }.joined(separator: " · "))
        .font(LedgerTheme.Typeface.caption).foregroundStyle(LedgerTheme.inkTertiary)
      }
      if rule.paused { LedgerBadge("Paused", systemImage: "pause.circle", tint: LedgerTheme.warning) }
      if rule.lifecycle == .tombstoned { LedgerBadge("Closed", systemImage: "archivebox") }
      Menu {
        if rule.lifecycle == .active {
          Button(rule.paused ? "Resume rule" : "Pause rule") {
            guard let revised = try? LedgerRecurrenceRule(
              id: rule.id, origin: rule.origin, accountID: rule.accountID, categoryID: rule.categoryID,
              kind: rule.kind, amount: rule.amount, frequency: rule.frequency, interval: rule.interval,
              dayOfMonth: rule.dayOfMonth, timeZone: rule.timeZone, start: rule.start, until: rule.until,
              paused: !rule.paused, skippedDates: rule.skippedDates, lifecycle: rule.lifecycle)
            else { return }
            toggle(revised)
          }
          Button("Generate through today", action: generate)
        }
        Button(rule.lifecycle == .active ? "Close rule" : "Restore rule") {
          guard let revised = try? LedgerRecurrenceRule(
            id: rule.id, origin: rule.origin, accountID: rule.accountID, categoryID: rule.categoryID,
            kind: rule.kind, amount: rule.amount, frequency: rule.frequency, interval: rule.interval,
            dayOfMonth: rule.dayOfMonth, timeZone: rule.timeZone, start: rule.start, until: rule.until,
            paused: rule.paused, skippedDates: rule.skippedDates,
            lifecycle: rule.lifecycle == .active ? .tombstoned : .active)
          else { return }
          toggle(revised)
        }
      } label: {
        LedgerRowActionsLabel()
      }
      .ledgerRowActionsMenu()
      .shownWhileEditing(isEditing)
      .accessibilityLabel(
        "Actions for \(categoryName ?? rule.kind.rawValue.capitalized), \(formatter.amount(rule.amount))")
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(categoryName ?? rule.kind.rawValue.capitalized), \(formatter.amount(rule.amount)), "
        + [cadence, schedule, accountName].compactMap { $0 }.joined(separator: ", "))
  }

  /// "next Nov 3, 2026" while the rule runs; when it ended or is closed, when it started.
  private var schedule: String {
    if rule.lifecycle == .active, !rule.paused,
      let next = PlanningSupport.nextDate(of: rule, onOrAfter: today)
    {
      return next == today ? "next today" : "next \(formatter.date(next))"
    }
    if let until = rule.until, until < today { return "ended \(formatter.date(until))" }
    return "started \(formatter.date(rule.start))"
  }
}

private struct RecurrenceForm: View {
  let accounts: [LedgerAccount]
  let categories: [LedgerCategory]
  let onSave: (LedgerRecurrenceRule) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var accountID = ""
  @State private var categoryID: String?
  @State private var kind: LedgerTransactionKind = .expense
  @State private var amount = ""
  @State private var frequency: LedgerRecurrenceFrequency = .monthly
  @State private var interval = "1"
  @State private var dayOfMonth = ""
  @State private var start = PlanningSupport.todayText()
  @State private var until = ""

  var body: some View {
    Form {
      Picker("Account", selection: $accountID) {
        Text("Choose account…").tag("")
        ForEach(accounts.filter { $0.lifecycle == .active }, id: \.id) { Text($0.name).tag($0.id) }
      }
      Picker("Category", selection: $categoryID) {
        Text("No category").tag(String?.none)
        ForEach(categories.filter { $0.lifecycle == .active && !$0.hidden }, id: \.id) {
          Text(CategoryPresentation.label($0, in: categories)).tag(Optional($0.id))
        }
      }
      Picker("Kind", selection: $kind) {
        Text("Income").tag(LedgerTransactionKind.income)
        Text("Expense").tag(LedgerTransactionKind.expense)
      }
      TextField("Amount", text: $amount)
      Picker("Frequency", selection: $frequency) {
        ForEach(LedgerRecurrenceFrequency.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
      }
      TextField("Interval", text: $interval)
      TextField("Day of month (optional)", text: $dayOfMonth)
      TextField("Start date (YYYY-MM-DD)", text: $start)
      TextField("Until date (optional)", text: $until)
      Text("Time zone: \(TimeZone.current.identifier)").font(LedgerTheme.Typeface.caption).foregroundStyle(LedgerTheme.inkSecondary)
      HStack {
        Button("Cancel", role: .cancel) { dismiss() }
        Spacer()
        Button("Create") { create() }.disabled(!valid)
      }
    }
    .padding(20)
    .frame(width: 460)
    .onAppear { if accountID.isEmpty { accountID = accounts.first(where: { $0.lifecycle == .active })?.id ?? "" } }
  }

  private var valid: Bool {
    !accountID.isEmpty && !amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && Int(interval).map { $0 > 0 } == true && PlanningSupport.date(start) != nil
  }

  private func create() {
    guard let origin = try? LedgerOrigin.macNative(),
      let id = try? StableLedgerID.recurrenceRule(origin: origin, localKey: PlanningSupport.generatedID("recurrence")),
      let account = accounts.first(where: { $0.id == accountID }),
      let money = try? CurrencyAmount(unitCode: account.currencyUnit, amount: ExactDecimal(amount)),
      let startDate = PlanningSupport.date(start), let interval = Int(interval), interval > 0,
      let timeZone = try? SourceTimeZone(ianaIdentifier: TimeZone.current.identifier)
    else { return }
    let dayText = dayOfMonth.trimmingCharacters(in: .whitespacesAndNewlines)
    let day: Int?
    if dayText.isEmpty {
      day = nil
    } else {
      guard let parsed = Int(dayText), (1...31).contains(parsed) else { return }
      day = parsed
    }
    let untilDate = until.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : PlanningSupport.date(until)
    guard until.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || untilDate != nil,
      let rule = try? LedgerRecurrenceRule(
        id: id, origin: origin, accountID: accountID, categoryID: categoryID, kind: kind,
        amount: money, frequency: frequency, interval: interval, dayOfMonth: day,
        timeZone: timeZone, start: startDate, until: untilDate)
    else { return }
    onSave(rule)
    dismiss()
  }
}

struct InstallmentsView: View {
  @Environment(\.ledgerFormatter) private var formatter
  let state: LedgerSession.State
  let plans: [LedgerInstallmentPlan]
  let accounts: [LedgerAccount]
  let categories: [LedgerCategory]
  let isEditing: Bool
  let lastFailure: String?
  let beginEditing: () -> Void
  let onCreate: (LedgerInstallmentPlan, SourceTemporal) -> Void
  let onUpdate: (LedgerInstallmentPlan) -> Void
  let open: () -> Void
  @State private var showingForm = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if plans.isEmpty {
        PlanningEmptyView(
          title: "No installment plans", systemImage: "calendar.badge.clock",
          message: "Split one purchase into exact monthly entries that add up to the price.",
          state: state, isEditing: isEditing, failure: lastFailure, open: open)
      } else {
        List(plans, id: \.id) { plan in
          let accountName = accounts.first(where: { $0.id == plan.accountID })?.name ?? "Unknown account"
          let categoryName = categories.first(where: { $0.id == plan.categoryID })
            .map { CategoryPresentation.label($0, in: categories) }
          let progress = plan.occurrenceCount > 0 ? Double(plan.completedCount) / Double(plan.occurrenceCount) : 0
          HStack(spacing: LedgerTheme.Space.m) {
            LedgerIconTile(.symbol("calendar.badge.clock"), swatch: LedgerTheme.swatch(for: categoryName ?? accountName))
            VStack(alignment: .leading, spacing: LedgerTheme.Space.xs) {
              HStack(alignment: .firstTextBaseline, spacing: LedgerTheme.Space.s) {
                Text(categoryName ?? accountName)
                  .font(LedgerTheme.Typeface.bodyEmphasis)
                  .foregroundStyle(plan.lifecycle == .active ? LedgerTheme.ink : LedgerTheme.inkTertiary)
                  .strikethrough(plan.lifecycle == .cancelled)
                Spacer(minLength: LedgerTheme.Space.s)
                MoneyText(plan.principal, size: .row, sign: .never, tone: plan.lifecycle == .active ? .neutral : .secondary)
              }
              LedgerProgressTrack(fraction: progress, tint: LedgerTheme.ink, height: 4)
              Text(
                [
                  "\(plan.completedCount) of \(plan.occurrenceCount) monthly entries",
                  categoryName == nil ? nil : accountName,
                ].compactMap { $0 }.joined(separator: " · ")
              )
              .font(LedgerTheme.Typeface.caption).foregroundStyle(LedgerTheme.inkTertiary)
            }
            if plan.lifecycle != .active {
              LedgerBadge(plan.lifecycle.rawValue.capitalized, systemImage: "archivebox")
            }
            if isEditing {
              Button(plan.lifecycle == .active ? "Cancel" : "Restore") {
                guard let revised = try? LedgerInstallmentPlan(
                  id: plan.id, origin: plan.origin, accountID: plan.accountID, categoryID: plan.categoryID,
                  principal: plan.principal, occurrenceCount: plan.occurrenceCount,
                  completedCount: plan.completedCount,
                  lifecycle: plan.lifecycle == .active ? .cancelled : .active)
                else { return }
                onUpdate(revised)
              }
              .buttonStyle(LedgerSecondaryButtonStyle())
            }
          }
          .padding(.vertical, LedgerTheme.Space.xs)
          .accessibilityElement(children: .combine)
          .accessibilityLabel("Installment plan, \(formatter.amount(plan.principal))")
        }
        .scrollContentBackground(.hidden)
      }
      LedgerActionBar {
        if isEditing {
          Button("New installment plan") { showingForm = true }.buttonStyle(LedgerPrimaryButtonStyle())
        } else if !plans.isEmpty || state.isLoaded {
          Button("Begin editing", action: beginEditing).buttonStyle(LedgerSecondaryButtonStyle())
        } else {
          Button("Open Ledger…", action: open).buttonStyle(LedgerPrimaryButtonStyle())
        }
        if let lastFailure { LedgerStatusLine(failure: lastFailure) }
      }
    }
    .ledgerCanvas()
    .navigationTitle("Installments")
    .sheet(isPresented: $showingForm) {
      InstallmentForm(accounts: accounts, categories: categories, onSave: onCreate)
    }
  }
}

private struct InstallmentForm: View {
  let accounts: [LedgerAccount]
  let categories: [LedgerCategory]
  let onSave: (LedgerInstallmentPlan, SourceTemporal) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var accountID = ""
  @State private var categoryID: String?
  @State private var principal = ""
  @State private var occurrenceCount = "2"

  var body: some View {
    Form {
      Picker("Account", selection: $accountID) {
        Text("Choose account…").tag("")
        ForEach(accounts.filter { $0.lifecycle == .active }, id: \.id) { Text($0.name).tag($0.id) }
      }
      Picker("Category", selection: $categoryID) {
        Text("No category").tag(String?.none)
        ForEach(categories.filter { $0.lifecycle == .active && !$0.hidden }, id: \.id) {
          Text(CategoryPresentation.label($0, in: categories)).tag(Optional($0.id))
        }
      }
      TextField("Principal amount", text: $principal)
      TextField("Number of monthly entries", text: $occurrenceCount)
      HStack {
        Button("Cancel", role: .cancel) { dismiss() }
        Spacer()
        Button("Create") { create() }.disabled(accountID.isEmpty || principal.isEmpty || Int(occurrenceCount) == nil)
      }
    }
    .padding(20).frame(width: 420)
    .onAppear { if accountID.isEmpty { accountID = accounts.first(where: { $0.lifecycle == .active })?.id ?? "" } }
  }

  private func create() {
    guard let origin = try? LedgerOrigin.macNative(),
      let id = try? StableLedgerID.installmentPlan(origin: origin, localKey: PlanningSupport.generatedID("installment")),
      let account = accounts.first(where: { $0.id == accountID }),
      let amount = try? CurrencyAmount(unitCode: account.currencyUnit, amount: ExactDecimal(principal)),
      let count = Int(occurrenceCount), count > 0,
      let plan = try? LedgerInstallmentPlan(
        id: id, origin: origin, accountID: accountID, categoryID: categoryID,
        principal: amount, occurrenceCount: count),
      let occurredAt = try? LedgerJourney.nativeTemporal(
        for: UTCInstant(epochMilliseconds: UTCInstant.currentEpochMilliseconds()))
    else { return }
    onSave(plan, occurredAt)
    dismiss()
  }
}

struct BudgetsView: View {
  @Environment(\.ledgerFormatter) private var formatter
  let state: LedgerSession.State
  let budgets: [LedgerBudget]
  let categories: [LedgerCategory]
  let accounts: [LedgerAccount]
  let transactions: [LedgerTransactionSnapshot]
  /// Today in the person's time zone; budgets are evaluated for the period containing it.
  let today: SourceLocalDate?
  let isEditing: Bool
  let lastFailure: String?
  let beginEditing: () -> Void
  let onCreate: (LedgerBudget) -> Void
  let onUpdate: (LedgerBudget) -> Void
  let open: () -> Void
  @State private var showingForm = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if budgets.isEmpty {
        PlanningEmptyView(
          title: "No budgets", message: "Create a category budget and choose whether unused amounts roll over.",
          state: state, isEditing: isEditing, failure: lastFailure, open: open)
      } else {
        List(budgets, id: \.id) { budget in
          let budgetStatus = status(of: budget)
          let category = categories.first(where: { $0.id == budget.categoryID })?.name ?? "Unknown category"
          HStack(alignment: .center, spacing: LedgerTheme.Space.m) {
            LedgerIconTile(
              .symbol(LedgerCategorySymbol.name(for: category, kind: .expense)),
              swatch: LedgerTheme.swatch(for: category))
            VStack(alignment: .leading, spacing: LedgerTheme.Space.xs) {
              HStack(alignment: .firstTextBaseline) {
                Text(budget.name).font(LedgerTheme.Typeface.body).foregroundStyle(LedgerTheme.ink)
                  .strikethrough(budget.lifecycle == .tombstoned)
                Spacer(minLength: LedgerTheme.Space.s)
                MoneyText(budget.amount, size: .row, sign: .never, tone: .neutral)
              }
              Text(
                [category, budget.period.rawValue.capitalized, budget.rollover ? "Rolls over" : nil]
                  .compactMap { $0 }.joined(separator: " · ")
              )
              .font(LedgerTheme.Typeface.caption).foregroundStyle(LedgerTheme.inkTertiary)
              if let status = budgetStatus {
                LedgerProgressTrack(
                  fraction: Self.fraction(status), tint: LedgerTheme.ink, height: 6)
                Text(Self.describe(status, formatter: formatter, unit: budget.amount.unitCode))
                  .font(LedgerTheme.Typeface.caption)
                  .foregroundStyle(status.isOverBudget ? LedgerTheme.negative : LedgerTheme.inkSecondary)
              }
            }
            if isEditing {
              Button(budget.lifecycle == .active ? "Close" : "Restore") {
                guard let revised = try? LedgerBudget(
                  id: budget.id, origin: budget.origin, name: budget.name, categoryID: budget.categoryID,
                  amount: budget.amount, period: budget.period, rollover: budget.rollover,
                  start: budget.start, lifecycle: budget.lifecycle == .active ? .tombstoned : .active)
                else { return }
                onUpdate(revised)
              }
              .buttonStyle(.borderless)
            }
          }
          .padding(.vertical, LedgerTheme.Space.xs)
          .accessibilityElement(children: .combine)
          .accessibilityLabel(
            "Budget \(budget.name), \(formatter.parts(budget.amount, sign: .never).text)"
              + (budgetStatus.map { ". " + Self.describe($0, formatter: formatter, unit: budget.amount.unitCode) }
                ?? ""))
        }
      }
      LedgerActionBar {
        if isEditing {
          Button("New budget") { showingForm = true }.buttonStyle(LedgerPrimaryButtonStyle())
        } else if !budgets.isEmpty || state.isLoaded {
          Button("Begin editing", action: beginEditing).buttonStyle(LedgerSecondaryButtonStyle())
        } else {
          Button("Open Ledger…", action: open).buttonStyle(LedgerPrimaryButtonStyle())
        }
        if let lastFailure { LedgerStatusLine(failure: lastFailure) }
      }
    }
    .ledgerCanvas()
    .navigationTitle("Budgets")
    .sheet(isPresented: $showingForm) {
      BudgetForm(accounts: accounts, categories: categories, onSave: onCreate)
    }
  }

  private func status(of budget: LedgerBudget) -> LedgerBudgetStatus? {
    guard let today else { return nil }
    return try? budget.status(on: today, transactions: transactions)
  }

  static func fraction(_ status: LedgerBudgetStatus) -> Double {
    let available = Double(status.available.description) ?? 0
    let spent = Double(status.spent.description) ?? 0
    return available > 0 ? spent / available : (spent > 0 ? 2 : 0)
  }

  /// "Spent ₹4,200.00 of ₹6,000.00 · ₹1,800.00 left · ends 30 Nov 2026", in the display style.
  static func describe(
    _ status: LedgerBudgetStatus, formatter: LedgerDisplayFormatter, unit: String
  ) -> String {
    func money(_ value: ExactDecimal) -> String {
      (try? CurrencyAmount(unitCode: unit, amount: value)).map {
        formatter.parts($0, sign: .never).text
      } ?? formatter.plain(value, unitCode: unit)
    }
    let left = status.overspent.map { "over by \(money($0))" } ?? "\(money(status.remaining)) left"
    let carried = status.carried.isPositive ? " (includes \(money(status.carried)) rolled over)" : ""
    return
      "Spent \(money(status.spent)) of \(money(status.available)), \(left)\(carried), ends \(formatter.date(status.periodEnd))"
  }
}

private struct BudgetForm: View {
  let accounts: [LedgerAccount]
  let categories: [LedgerCategory]
  let onSave: (LedgerBudget) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var accountID = ""
  @State private var categoryID = ""
  @State private var amount = ""
  @State private var period: LedgerBudget.Period = .monthly
  @State private var rollover = false
  @State private var start = PlanningSupport.todayText()

  var body: some View {
    Form {
      TextField("Budget name", text: $name)
      Picker("Account currency", selection: $accountID) {
        Text("Choose account…").tag("")
        ForEach(accounts.filter { $0.lifecycle == .active }, id: \.id) { Text("\($0.name) (\($0.currencyUnit))").tag($0.id) }
      }
      Picker("Category", selection: $categoryID) {
        Text("Choose category…").tag("")
        ForEach(categories.filter { $0.lifecycle == .active && !$0.hidden }, id: \.id) { category in
          Text(CategoryPresentation.label(category, in: categories)).tag(category.id)
        }
      }
      TextField("Amount", text: $amount)
      Picker("Period", selection: $period) {
        ForEach(LedgerBudget.Period.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
      }
      Toggle("Roll unused amount forward", isOn: $rollover)
      TextField("Start date (YYYY-MM-DD)", text: $start)
      HStack {
        Button("Cancel", role: .cancel) { dismiss() }
        Spacer()
        Button("Create") { create() }.disabled(!valid)
      }
    }
    .padding(20).frame(width: 440)
    .onAppear {
      if accountID.isEmpty { accountID = accounts.first(where: { $0.lifecycle == .active })?.id ?? "" }
      if categoryID.isEmpty { categoryID = categories.first(where: { $0.lifecycle == .active && !$0.hidden })?.id ?? "" }
    }
  }

  private var valid: Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !accountID.isEmpty
      && !categoryID.isEmpty && !amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && PlanningSupport.date(start) != nil
  }

  private func create() {
    guard let origin = try? LedgerOrigin.macNative(),
      let id = try? StableLedgerID.budget(origin: origin, localKey: PlanningSupport.generatedID("budget")),
      let account = accounts.first(where: { $0.id == accountID }),
      let money = try? CurrencyAmount(unitCode: account.currencyUnit, amount: ExactDecimal(amount)),
      let startDate = PlanningSupport.date(start),
      let budget = try? LedgerBudget(
        id: id, origin: origin, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
        categoryID: categoryID, amount: money, period: period, rollover: rollover, start: startDate)
    else { return }
    onSave(budget)
    dismiss()
  }
}

private struct PlanningEmptyView: View {
  let title: String
  var systemImage = "calendar.badge.plus"
  /// What the screen is for, then how to start.
  let message: String
  var action = "Begin editing to add one."
  let state: LedgerSession.State
  let isEditing: Bool
  let failure: String?
  let open: () -> Void

  var body: some View {
    LedgerSessionEmptyState(
      state: state, title: title, systemImage: systemImage,
      message: isEditing ? message : "\(message) \(action)", failure: failure, open: open)
  }
}

extension LedgerSession.State {
  /// A ledger is open, so an empty planning screen offers editing rather than opening one.
  fileprivate var isLoaded: Bool {
    if case .loaded = self { return true }
    return false
  }
}
