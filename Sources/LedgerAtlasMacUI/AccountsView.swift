import AppKit
import CryptoKit
import LedgerCore
import LedgerStore
import SwiftUI
import UniformTypeIdentifiers

struct AccountsView: View {
  @Environment(\.ledgerFormatter) private var formatter
  let state: LedgerSession.State
  let rows: [LedgerJourney.SurfaceRow]
  let accounts: [LedgerAccount]
  let groups: [LedgerAccountGroup]
  let transactions: [LedgerTransactionSnapshot]
  let isEditing: Bool
  let lastFailure: String?
  let beginEditing: () -> Void
  let saveAccount: (LedgerAccount) -> Void
  let saveGroup: (LedgerAccountGroup) -> Void
  let createAccount: (LedgerAccount) -> Void
  let createGroup: (LedgerAccountGroup) -> Void
  let open: () -> Void
  @State private var showingAccountForm = false
  @State private var showingGroupForm = false
  @State private var editingAccount: LedgerAccount?
  @State private var renamingGroup: LedgerAccountGroup?

  var body: some View {
    let sheet = try? LedgerAccountBalanceSheet(accounts: accounts, transactions: transactions)
    let orderedGroups = Self.sortedGroups(groups)
    VStack(alignment: .leading, spacing: LedgerTheme.Space.m) {
      if !accounts.isEmpty {
        if let sheet {
          AccountTotalsSummary(sheet: sheet)
            .padding(.horizontal, LedgerTheme.Space.xxl)
        }
        List {
          ForEach(Array(orderedGroups.enumerated()), id: \.element.id) { index, group in
            let members = Self.sortedAccounts(accounts.filter { $0.groupID == group.id })
            Section {
              ForEach(Array(members.enumerated()), id: \.element.id) { position, account in
                accountRow(account, balance: sheet?.balances[account.id], in: members, at: position)
              }
              if members.isEmpty {
                Text("No accounts in this group")
                  .font(LedgerTheme.Typeface.secondary)
                  .foregroundStyle(LedgerTheme.inkTertiary)
              }
            } header: {
              AccountGroupHeader(
                group: group, subtotal: sheet?.groupTotals[group.id] ?? [:],
                isEditing: isEditing, save: saveGroup,
                rename: { renamingGroup = group },
                moveUp: index > 0 ? { move(group, in: orderedGroups, by: -1) } : nil,
                moveDown: index < orderedGroups.count - 1
                  ? { move(group, in: orderedGroups, by: 1) } : nil)
            }
          }
          Section {
            let ungrouped = Self.sortedAccounts(accounts.filter { $0.groupID == nil })
            if ungrouped.isEmpty {
              Text("No ungrouped accounts")
                .font(LedgerTheme.Typeface.secondary)
                .foregroundStyle(LedgerTheme.inkTertiary)
            } else {
              ForEach(Array(ungrouped.enumerated()), id: \.element.id) { position, account in
                accountRow(account, balance: sheet?.balances[account.id], in: ungrouped, at: position)
              }
            }
          } header: {
            HStack {
              Text("Ungrouped")
              Spacer()
              Text(AccountAmountText.subtotal(sheet?.groupTotals[nil] ?? [:], formatter))
                .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
          }
        }
      } else if !rows.isEmpty {
        List(rows) { row in
          VStack(alignment: .leading, spacing: 4) {
            Text(row.title)
            Text(row.detail).font(LedgerTheme.Typeface.caption).foregroundStyle(LedgerTheme.inkTertiary)
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel("\(row.title), \(row.detail)")
        }
      } else {
        emptyContent
      }
      LedgerStatusLine(failure: lastFailure)
        .padding(.horizontal, LedgerTheme.Space.xxl)
      HStack {
        if isEditing {
          Button("New account") { showingAccountForm = true }
            .accessibilityLabel("New account")
          Button("New group") { showingGroupForm = true }
            .accessibilityLabel("New account group")
        } else if !accounts.isEmpty || !rows.isEmpty {
          Button("Begin editing", action: beginEditing)
            .accessibilityLabel("Begin editing accounts")
        } else {
          Button("Open Ledger…", action: open)
        }
      }
      .padding(.horizontal, LedgerTheme.Space.xxl)
      .padding(.bottom, LedgerTheme.Space.m)
    }
    .navigationTitle("Accounts")
    .sheet(isPresented: $showingAccountForm) {
      AccountForm(groups: groups, onSave: { account in
        createAccount(account)
        showingAccountForm = false
      })
    }
    .sheet(isPresented: $showingGroupForm) {
      AccountGroupForm(onSave: { group in
        createGroup(group)
        showingGroupForm = false
      })
    }
    .sheet(isPresented: Binding(
      get: { renamingGroup != nil }, set: { if !$0 { renamingGroup = nil } })) {
      if let renamingGroup {
        AccountGroupForm(group: renamingGroup, onSave: { revised in
          saveGroup(revised)
          self.renamingGroup = nil
        })
      }
    }
    .sheet(isPresented: Binding(
      get: { editingAccount != nil }, set: { if !$0 { editingAccount = nil } })) {
      if let editingAccount {
        AccountEditForm(account: editingAccount, groups: groups) { revised in
          saveAccount(revised)
          self.editingAccount = nil
        }
      }
    }
  }

  @ViewBuilder
  private var emptyContent: some View {
    switch state {
    case .loaded:
      ContentUnavailableView(
        "No accounts", systemImage: "rectangle.stack",
        description: Text(isEditing ? "Create an account or group to start organizing balances." : "Begin editing to manage accounts."))
    case .unavailable:
      EmptyLedgerPrompt(title: "Ledger unavailable", description: "Choose a compatible ledger to view its accounts.", guidance: .unavailable, failure: lastFailure, buttonTitle: "Open Ledger…", open: open)
    case .noLedger:
      EmptyLedgerPrompt(title: "Open a ledger", description: "Choose a Ledger Atlas ledger to view its accounts.", guidance: .noLedger, failure: lastFailure, buttonTitle: "Open Ledger…", open: open)
    case .loading:
      ProgressView("Opening ledger…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  /// The same colours the sidebar gives its accounts (active, shown ones), so a tile matches
  /// its sidebar dot. Hidden and closed accounts aren't in the sidebar and keep a hashed colour.
  private var tileSwatches: [String: LedgerTheme.Swatch] {
    LedgerTheme.accountSwatches(
      for: accounts.filter { $0.lifecycle == .active && !$0.hidden }.map(\.name))
  }

  private func accountRow(
    _ account: LedgerAccount, balance: CurrencyAmount?, in members: [LedgerAccount], at position: Int
  ) -> some View {
    AccountRow(
      account: account, balance: balance,
      swatch: tileSwatches[account.name] ?? LedgerTheme.swatch(for: account.name),
      isEditing: isEditing, save: saveAccount,
      edit: { editingAccount = $0 },
      moveUp: position > 0 ? { move(account, in: members, by: -1) } : nil,
      moveDown: position < members.count - 1 ? { move(account, in: members, by: 1) } : nil)
  }

  /// Moves one account within its section and saves every account whose order changed.
  private func move(_ account: LedgerAccount, in members: [LedgerAccount], by offset: Int) {
    for revised in Self.reordered(members, moving: account.id, by: offset) {
      saveAccount(revised)
    }
  }

  private func move(_ group: LedgerAccountGroup, in ordered: [LedgerAccountGroup], by offset: Int) {
    for revised in Self.reordered(ordered, moving: group.id, by: offset) {
      saveGroup(revised)
    }
  }

  /// Swaps one account with its neighbour, then numbers the section 0, 1, 2… so equal display
  /// orders (the default) still move. Returns only accounts whose order changed.
  nonisolated static func reordered(_ members: [LedgerAccount], moving id: String, by offset: Int)
    -> [LedgerAccount]
  {
    var ids = members.map(\.id)
    guard let from = ids.firstIndex(of: id), ids.indices.contains(from + offset) else { return [] }
    ids.swapAt(from, from + offset)
    return members.compactMap { account in
      guard let order = ids.firstIndex(of: account.id), order != account.displayOrder else {
        return nil
      }
      return try? LedgerAccount(
        id: account.id, name: account.name, currencyUnit: account.currencyUnit,
        origin: account.origin, lifecycle: account.lifecycle, groupID: account.groupID,
        displayOrder: order, hidden: account.hidden, includeInTotals: account.includeInTotals,
        variant: account.variant)
    }
  }

  nonisolated static func reordered(_ groups: [LedgerAccountGroup], moving id: String, by offset: Int)
    -> [LedgerAccountGroup]
  {
    var ids = groups.map(\.id)
    guard let from = ids.firstIndex(of: id), ids.indices.contains(from + offset) else { return [] }
    ids.swapAt(from, from + offset)
    return groups.compactMap { group in
      guard let order = ids.firstIndex(of: group.id), order != group.displayOrder else {
        return nil
      }
      return try? LedgerAccountGroup(
        id: group.id, name: group.name, displayOrder: order, lifecycle: group.lifecycle)
    }
  }

  nonisolated static func sortedGroups(_ groups: [LedgerAccountGroup]) -> [LedgerAccountGroup] {
    groups.sorted {
      $0.displayOrder == $1.displayOrder ? ($0.name, $0.id) < ($1.name, $1.id) : $0.displayOrder < $1.displayOrder
    }
  }

  nonisolated static func sortedAccounts(_ accounts: [LedgerAccount]) -> [LedgerAccount] {
    accounts.sorted {
      $0.displayOrder == $1.displayOrder ? ($0.name, $0.id) < ($1.name, $1.id) : $0.displayOrder < $1.displayOrder
    }
  }
}

/// Text amounts for the accounts screen, in the display formatter's style ("₹4,83,676.30").
/// The formatter keeps every stored decimal place, so nothing is rounded for display.
enum AccountAmountText {
  static func amount(_ value: CurrencyAmount, _ formatter: LedgerDisplayFormatter) -> String {
    formatter.parts(value).text
  }

  static func subtotal(_ byUnit: [String: ExactDecimal], _ formatter: LedgerDisplayFormatter) -> String {
    byUnit.sorted { $0.key < $1.key }.compactMap { unit, value in
      (try? CurrencyAmount(unitCode: unit, amount: value)).map { formatter.parts($0).text }
    }
    .joined(separator: " · ")
  }
}

struct AccountTotalsSummary: View {
  let sheet: LedgerAccountBalanceSheet
  @Environment(\.ledgerFormatter) private var formatter

  var body: some View {
    VStack(alignment: .leading, spacing: LedgerTheme.Space.s) {
      ForEach(sheet.summaries, id: \.unitCode) { summary in
        // Figures of different sizes share one baseline, and so do their labels.
        HStack(alignment: .lastTextBaseline, spacing: LedgerTheme.Space.xxl) {
          figure("Net worth", summary.unitCode, summary.net, size: .figure, alert: true)
          figure("Assets", summary.unitCode, summary.assets, size: .row, alert: false)
          figure("Liabilities", summary.unitCode, summary.liabilities, size: .row, alert: false)
          Spacer(minLength: 0)
          Text(summary.accountCount == 1 ? "1 account" : "\(summary.accountCount) accounts")
            .font(LedgerTheme.Typeface.caption)
            .foregroundStyle(LedgerTheme.inkTertiary)
        }
        .ledgerCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
          "\(summary.unitCode): assets \(text(summary.unitCode, summary.assets)), liabilities \(text(summary.unitCode, summary.liabilities)), net \(text(summary.unitCode, summary.net)), \(summary.accountCount) accounts counted")
      }
      if sheet.foreignCurrencyEffectCount > 0 {
        Label(
          "\(sheet.foreignCurrencyEffectCount) entries use a currency different from their account and are not in these balances.",
          systemImage: "exclamationmark.triangle")
          .font(LedgerTheme.Typeface.caption)
          .foregroundStyle(LedgerTheme.warning)
      }
      Text("Totals count open, visible accounts that are included in totals.")
        .font(LedgerTheme.Typeface.caption)
        .foregroundStyle(LedgerTheme.inkTertiary)
    }
  }

  private func text(_ unit: String, _ value: ExactDecimal) -> String {
    (try? CurrencyAmount(unitCode: unit, amount: value)).map { formatter.parts($0).text }
      ?? formatter.figure(value.description)
  }

  @ViewBuilder
  private func figure(
    _ title: String, _ unit: String, _ value: ExactDecimal, size: MoneyText.Size, alert: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: LedgerTheme.Space.xxs) {
      Text(title).font(LedgerTheme.Typeface.caption).foregroundStyle(LedgerTheme.inkTertiary)
      if let amount = try? CurrencyAmount(unitCode: unit, amount: value) {
        MoneyText(amount, size: size, negativeIsAlert: alert)
      } else {
        Text(formatter.figure(value.description)).monospacedDigit()
      }
    }
  }
}

struct AccountRow: View {
  let account: LedgerAccount
  var balance: CurrencyAmount? = nil
  var swatch: LedgerTheme.Swatch? = nil
  let isEditing: Bool
  let save: (LedgerAccount) -> Void
  let edit: (LedgerAccount) -> Void
  var moveUp: (() -> Void)? = nil
  var moveDown: (() -> Void)? = nil

  @Environment(\.ledgerFormatter) private var formatter

  var body: some View {
    HStack(spacing: LedgerTheme.Space.m) {
      LedgerIconTile(
        .symbol(Self.symbol(for: account)), swatch: swatch ?? LedgerTheme.swatch(for: account.name))
      VStack(alignment: .leading, spacing: LedgerTheme.Space.xxs) {
        Text(account.name)
          .font(LedgerTheme.Typeface.body)
          .foregroundStyle(LedgerTheme.ink)
        Text("\(Self.kindLabel(account.variant)) · \(account.currencyUnit)")
          .font(LedgerTheme.Typeface.caption)
          .foregroundStyle(LedgerTheme.inkTertiary)
      }
      Spacer()
      if account.hidden { LedgerBadge("Hidden", systemImage: "eye.slash") }
      if !account.includeInTotals { LedgerBadge("Excluded from totals", systemImage: "minus.circle") }
      if account.lifecycle == .tombstoned { LedgerBadge("Closed", systemImage: "archivebox") }
      if let balance {
        MoneyText(
          balance, size: .row, tone: account.countsInTotals ? .automatic : .secondary,
          negativeIsAlert: account.accountClass == .asset)
      }
      Menu {
        Button("Edit account") { edit(account) }
        if let moveUp { Button("Move up", action: moveUp) }
        if let moveDown { Button("Move down", action: moveDown) }
        Button(account.hidden ? "Show account" : "Hide account") {
          update(hidden: !account.hidden)
        }
        Button(account.includeInTotals ? "Exclude from totals" : "Include in totals") {
          update(includeInTotals: !account.includeInTotals)
        }
        Button(account.lifecycle == .active ? "Close account" : "Restore account") {
          update(lifecycle: account.lifecycle == .active ? .tombstoned : .active)
        }
      } label: {
        LedgerRowActionsLabel()
      }
      .ledgerRowActionsMenu()
      .shownWhileEditing(isEditing)
      .accessibilityLabel("Actions for \(account.name)")
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityText)
  }

  private var accessibilityText: String {
    var parts = [account.name, account.variant.rawValue, account.lifecycle.rawValue]
    if let balance { parts.insert("balance \(AccountAmountText.amount(balance, formatter))", at: 1) }
    if account.hidden { parts.append("hidden") }
    if !account.includeInTotals { parts.append("excluded from totals") }
    return parts.joined(separator: ", ")
  }

  /// What kind of account it is, in words a person uses.
  static func kindLabel(_ variant: LedgerAccountVariant) -> String {
    switch variant {
    case .standard: "Account"
    case .investment: "Investment"
    case .loan: "Loan"
    case .overdraft: "Credit or overdraft"
    }
  }

  /// A symbol for the account's type: one icon language with the category tiles, instead of
  /// initials that read like contact avatars.
  static func symbol(for account: LedgerAccount) -> String {
    switch account.variant {
    case .investment: return "chart.line.uptrend.xyaxis"
    case .loan: return "building.columns"
    case .overdraft: return "creditcard"
    case .standard:
      let name = account.name.lowercased()
      if name.contains("card") { return "creditcard" }
      if name.contains("cash") { return "banknote" }
      if name.contains("wallet") { return "wallet.pass" }
      if name.contains("saving") || name.contains("emergency") || name.contains("deposit") {
        return "lock.shield"
      }
      return "building.columns"
    }
  }

  static func initials(_ name: String) -> String {
    let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2)
    let letters = words.compactMap(\.first).map { String($0).uppercased() }.joined()
    return letters.isEmpty ? "·" : letters
  }

  private func update(
    name: String? = nil, lifecycle: LedgerLifecycleState? = nil, hidden: Bool? = nil,
    includeInTotals: Bool? = nil
  ) {
    guard let revised = try? LedgerAccount(
      id: account.id, name: name ?? account.name, currencyUnit: account.currencyUnit,
      origin: account.origin, lifecycle: lifecycle ?? account.lifecycle, groupID: account.groupID,
      displayOrder: account.displayOrder, hidden: hidden ?? account.hidden,
      includeInTotals: includeInTotals ?? account.includeInTotals, variant: account.variant)
    else { return }
    save(revised)
  }
}

struct AccountEditForm: View {
  let account: LedgerAccount
  let groups: [LedgerAccountGroup]
  let onSave: (LedgerAccount) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var groupID: String?
  @State private var displayOrder: String
  @State private var hidden: Bool
  @State private var includeInTotals: Bool
  @State private var variant: LedgerAccountVariant

  init(account: LedgerAccount, groups: [LedgerAccountGroup], onSave: @escaping (LedgerAccount) -> Void) {
    self.account = account
    self.groups = groups
    self.onSave = onSave
    _name = State(initialValue: account.name)
    _groupID = State(initialValue: account.groupID)
    _displayOrder = State(initialValue: String(account.displayOrder))
    _hidden = State(initialValue: account.hidden)
    _includeInTotals = State(initialValue: account.includeInTotals)
    _variant = State(initialValue: account.variant)
  }

  var body: some View {
    Form {
      TextField("Account name", text: $name)
      Text("Currency: \(account.currencyUnit)").font(LedgerTheme.Typeface.caption).foregroundStyle(LedgerTheme.inkSecondary)
      Picker("Group", selection: $groupID) {
        Text("No group").tag(String?.none)
        ForEach(groups.filter { $0.lifecycle == .active }, id: \.id) { Text($0.name).tag(Optional($0.id)) }
      }
      TextField("Display order", text: $displayOrder)
      Picker("Account type", selection: $variant) {
        ForEach(LedgerAccountVariant.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
      }
      Toggle("Hidden", isOn: $hidden)
      Toggle("Include in totals", isOn: $includeInTotals)
      HStack {
        Button("Cancel", role: .cancel) { dismiss() }
        Spacer()
        Button("Save") { save() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Int(displayOrder) == nil)
      }
    }
    .padding(20).frame(width: 420)
  }

  private func save() {
    guard let order = Int(displayOrder), order >= 0,
      let revised = try? LedgerAccount(
        id: account.id, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
        currencyUnit: account.currencyUnit, origin: account.origin, lifecycle: account.lifecycle,
        groupID: groupID, displayOrder: order, hidden: hidden,
        includeInTotals: includeInTotals, variant: variant)
    else { return }
    onSave(revised)
    dismiss()
  }
}

struct AccountGroupHeader: View {
  @Environment(\.ledgerFormatter) private var formatter
  let group: LedgerAccountGroup
  var subtotal: [String: ExactDecimal] = [:]
  let isEditing: Bool
  let save: (LedgerAccountGroup) -> Void
  var rename: (() -> Void)? = nil
  var moveUp: (() -> Void)? = nil
  var moveDown: (() -> Void)? = nil

  var body: some View {
    HStack {
      Text(group.name)
      if group.lifecycle == .tombstoned {
        Text("Closed").font(LedgerTheme.Typeface.caption).foregroundStyle(LedgerTheme.inkSecondary)
      }
      Spacer()
      if !subtotal.isEmpty {
        Text(AccountAmountText.subtotal(subtotal, formatter))
          .monospacedDigit()
          .accessibilityLabel("Group total \(AccountAmountText.subtotal(subtotal, formatter))")
      }
      if isEditing {
        if let rename {
          Button("Rename", action: rename)
            .buttonStyle(.borderless)
            .accessibilityLabel("Rename account group \(group.name)")
        }
        if let moveUp {
          Button(action: moveUp) { Image(systemName: "chevron.up") }
            .buttonStyle(.borderless)
            .accessibilityLabel("Move account group \(group.name) up")
        }
        if let moveDown {
          Button(action: moveDown) { Image(systemName: "chevron.down") }
            .buttonStyle(.borderless)
            .accessibilityLabel("Move account group \(group.name) down")
        }
        Button(group.lifecycle == .active ? "Close group" : "Restore group") {
          guard let revised = try? LedgerAccountGroup(
            id: group.id, name: group.name, displayOrder: group.displayOrder,
            lifecycle: group.lifecycle == .active ? .tombstoned : .active)
          else { return }
          save(revised)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("\(group.lifecycle == .active ? "Close" : "Restore") account group \(group.name)")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Account group \(group.name), \(group.lifecycle.rawValue)")
  }
}

struct AccountForm: View {
  let groups: [LedgerAccountGroup]
  let onSave: (LedgerAccount) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var currency = "USD"
  @State private var groupID: String?
  @State private var variant: LedgerAccountVariant = .standard
  @State private var includeInTotals = true

  var body: some View {
    Form {
      TextField("Account name", text: $name)
      TextField("Currency code", text: $currency)
        .textCase(.uppercase)
      Picker("Group", selection: $groupID) {
        Text("No group").tag(String?.none)
        ForEach(groups.filter { $0.lifecycle == .active }, id: \.id) { group in
          Text(group.name).tag(Optional(group.id))
        }
      }
      Picker("Account type", selection: $variant) {
        ForEach(LedgerAccountVariant.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
      }
      Toggle("Include in totals", isOn: $includeInTotals)
      HStack {
        Button("Cancel", role: .cancel) { dismiss() }
        Spacer()
        Button("Create") { create() }
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || currency.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 420)
    .accessibilityElement(children: .contain)
  }

  private func create() {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let unit = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard let origin = try? LedgerOrigin.macNative(),
      let id = try? StableLedgerID.account(origin: origin, localKey: Self.generatedID()),
      let account = try? LedgerAccount(
      id: id, name: trimmedName, currencyUnit: unit, origin: origin,
        groupID: groupID, includeInTotals: includeInTotals, variant: variant)
    else { return }
    onSave(account)
    dismiss()
  }

  private static func generatedID() -> String {
    SHA256.hash(data: Data("ledger-atlas/account/\(UUID().uuidString)".utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

struct AccountGroupForm: View {
  /// Nil creates a new group; a group renames that group and keeps its order and state.
  var group: LedgerAccountGroup? = nil
  let onSave: (LedgerAccountGroup) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""

  var body: some View {
    Form {
      TextField("Group name", text: $name)
      HStack {
        Button("Cancel", role: .cancel) { dismiss() }
        Spacer()
        Button(group == nil ? "Create" : "Save") { create() }
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 360)
    .onAppear { if let group, name.isEmpty { name = group.name } }
  }

  private func create() {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let saved: LedgerAccountGroup?
    if let group {
      saved = try? LedgerAccountGroup(
        id: group.id, name: trimmedName, displayOrder: group.displayOrder,
        lifecycle: group.lifecycle)
    } else if let id = Self.generatedID() {
      saved = try? LedgerAccountGroup(id: id, name: trimmedName)
    } else {
      saved = nil
    }
    guard let saved else { return }
    onSave(saved)
    dismiss()
  }

  private static func generatedID() -> String? {
    let value = SHA256.hash(data: Data("ledger-atlas/account-group/\(UUID().uuidString)".utf8)).map { String(format: "%02x", $0) }.joined()
    return CanonicalIdentifier.isValid(value) ? value : nil
  }
}
