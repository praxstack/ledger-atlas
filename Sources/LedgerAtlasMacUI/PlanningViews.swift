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
  @State private var showingForm = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if rules.isEmpty {
        PlanningEmptyView(
          title: "No recurrence rules", message: "Create a rule to generate dated income or expenses.",
          state: state, isEditing: isEditing, failure: lastFailure, open: open)
      } else {
        List(rules, id: \.id) { rule in
          RecurrenceRow(
            rule: rule, accountName: accounts.first(where: { $0.id == rule.accountID })?.name,
            categoryName: categories.first(where: { $0.id == rule.categoryID })?.name,
            isEditing: isEditing,
            toggle: { onUpdate($0, .thisAndFuture) },
            generate: { onGenerate(rule, PlanningSupport.today()) })
        }
      }
      if let lastFailure {
        Text(lastFailure).foregroundStyle(.red).accessibilityLabel(lastFailure)
      }
      HStack {
        if isEditing {
          Button("New recurrence") { showingForm = true }
        } else if !rules.isEmpty {
          Button("Begin editing", action: beginEditing)
        } else {
          Button("Open Ledger…", action: open)
        }
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 12)
    }
    .navigationTitle("Recurrence")
    .sheet(isPresented: $showingForm) {
      RecurrenceForm(accounts: accounts, categories: categories, onSave: onCreate)
    }
  }
}

private struct RecurrenceRow: View {
  let rule: LedgerRecurrenceRule
  let accountName: String?
  let categoryName: String?
  let isEditing: Bool
  let toggle: (LedgerRecurrenceRule) -> Void
  let generate: () -> Void

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        Text("\(rule.kind.rawValue.capitalized) · \(rule.amount.amount.rawLiteral) \(rule.amount.unitCode)")
        Text("Every \(rule.interval) \(rule.frequency.rawValue) · starts \(dateText(rule.start))")
          .font(.caption).foregroundStyle(.secondary)
        Text([accountName, categoryName].compactMap { $0 }.joined(separator: " · "))
          .font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if rule.paused { Label("Paused", systemImage: "pause.circle") }
      if rule.lifecycle == .tombstoned { Label("Closed", systemImage: "archivebox") }
      Menu("Actions") {
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
      }
      .disabled(!isEditing)
      .accessibilityLabel("Actions for recurrence rule")
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(rule.kind.rawValue) recurrence, \(rule.amount.amount.rawLiteral) \(rule.amount.unitCode)")
  }

  private func dateText(_ date: SourceLocalDate) -> String {
    String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
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
      Text("Time zone: \(TimeZone.current.identifier)").font(.caption).foregroundStyle(.secondary)
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
    VStack(alignment: .leading, spacing: 12) {
      if plans.isEmpty {
        PlanningEmptyView(
          title: "No installment plans", message: "Create a plan to divide a purchase into exact monthly entries.",
          state: state, isEditing: isEditing, failure: lastFailure, open: open)
      } else {
        List(plans, id: \.id) { plan in
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text("\(plan.principal.amount.rawLiteral) \(plan.principal.unitCode)")
              Text("\(plan.completedCount)/\(plan.occurrenceCount) occurrences · \(accounts.first(where: { $0.id == plan.accountID })?.name ?? "Unknown account")")
                .font(.caption).foregroundStyle(.secondary)
              if let category = categories.first(where: { $0.id == plan.categoryID }) {
                Text(CategoryPresentation.label(category, in: categories))
                  .font(.caption).foregroundStyle(.secondary)
              }
            }
            Spacer()
            Text(plan.lifecycle.rawValue.capitalized).font(.caption)
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
              .buttonStyle(.borderless)
            }
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel("Installment plan, \(plan.principal.amount.rawLiteral) \(plan.principal.unitCode)")
        }
      }
      if let lastFailure { Text(lastFailure).foregroundStyle(.red).accessibilityLabel(lastFailure) }
      HStack {
        if isEditing { Button("New installment plan") { showingForm = true } }
        else if !plans.isEmpty { Button("Begin editing", action: beginEditing) }
        else { Button("Open Ledger…", action: open) }
      }
      .padding(.horizontal, 16).padding(.bottom, 12)
    }
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
  let state: LedgerSession.State
  let budgets: [LedgerBudget]
  let categories: [LedgerCategory]
  let accounts: [LedgerAccount]
  let isEditing: Bool
  let lastFailure: String?
  let beginEditing: () -> Void
  let onCreate: (LedgerBudget) -> Void
  let onUpdate: (LedgerBudget) -> Void
  let open: () -> Void
  @State private var showingForm = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if budgets.isEmpty {
        PlanningEmptyView(
          title: "No budgets", message: "Create a category budget and choose whether unused amounts roll over.",
          state: state, isEditing: isEditing, failure: lastFailure, open: open)
      } else {
        List(budgets, id: \.id) { budget in
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text(budget.name)
              Text("\(budget.amount.amount.rawLiteral) \(budget.amount.unitCode) · \(budget.period.rawValue)")
                .font(.caption).foregroundStyle(.secondary)
              Text(categories.first(where: { $0.id == budget.categoryID })?.name ?? "Unknown category")
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if budget.rollover { Text("Rollover").font(.caption) }
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
          .accessibilityElement(children: .combine)
          .accessibilityLabel("Budget \(budget.name), \(budget.amount.amount.rawLiteral) \(budget.amount.unitCode)")
        }
      }
      if let lastFailure { Text(lastFailure).foregroundStyle(.red).accessibilityLabel(lastFailure) }
      HStack {
        if isEditing { Button("New budget") { showingForm = true } }
        else if !budgets.isEmpty { Button("Begin editing", action: beginEditing) }
        else { Button("Open Ledger…", action: open) }
      }
      .padding(.horizontal, 16).padding(.bottom, 12)
    }
    .navigationTitle("Budgets")
    .sheet(isPresented: $showingForm) {
      BudgetForm(accounts: accounts, categories: categories, onSave: onCreate)
    }
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
  let message: String
  let state: LedgerSession.State
  let isEditing: Bool
  let failure: String?
  let open: () -> Void

  var body: some View {
    Group {
      switch state {
      case .loaded:
        ContentUnavailableView(title, systemImage: "calendar.badge.plus", description: Text(isEditing ? message : "Begin editing to manage this plan."))
      case .loading:
        ProgressView("Opening ledger…")
      case .unavailable:
        VStack(spacing: 12) {
          Text("Ledger unavailable").font(.title2.bold())
          Text("Choose a compatible ledger to view planning data.").foregroundStyle(.secondary)
          if let failure { Text(failure).foregroundStyle(.red) }
          Button("Open Ledger…", action: open)
        }
      case .noLedger:
        VStack(spacing: 12) {
          Text("Open a ledger").font(.title2.bold())
          Text("Choose a Ledger Atlas ledger to view planning data.").foregroundStyle(.secondary)
          if let failure { Text(failure).foregroundStyle(.red) }
          Button("Open Ledger…", action: open)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(32)
  }
}
