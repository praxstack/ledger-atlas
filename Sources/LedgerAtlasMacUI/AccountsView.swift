import AppKit
import CryptoKit
import LedgerCore
import LedgerStore
import SwiftUI
import UniformTypeIdentifiers

struct AccountsView: View {
  let state: LedgerSession.State
  let rows: [LedgerJourney.SurfaceRow]
  let accounts: [LedgerAccount]
  let groups: [LedgerAccountGroup]
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

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if !accounts.isEmpty {
        List {
          ForEach(groups.sorted { $0.displayOrder == $1.displayOrder ? $0.name < $1.name : $0.displayOrder < $1.displayOrder }, id: \.id) { group in
            Section {
              ForEach(Self.sortedAccounts(accounts.filter { $0.groupID == group.id }), id: \.id) { account in
                AccountRow(account: account, isEditing: isEditing, save: saveAccount) {
                  editingAccount = $0
                }
              }
              if !accounts.contains(where: { $0.groupID == group.id }) {
                Text("No accounts in this group").foregroundStyle(.secondary)
              }
            } header: {
              AccountGroupHeader(group: group, isEditing: isEditing, save: saveGroup)
            }
          }
          Section("Ungrouped") {
            let ungrouped = Self.sortedAccounts(accounts.filter { $0.groupID == nil })
            if ungrouped.isEmpty {
              Text("No ungrouped accounts").foregroundStyle(.secondary)
            } else {
              ForEach(ungrouped, id: \.id) { account in
                AccountRow(account: account, isEditing: isEditing, save: saveAccount) {
                  editingAccount = $0
                }
              }
            }
          }
        }
      } else if !rows.isEmpty {
        List(rows) { row in
          VStack(alignment: .leading, spacing: 4) {
            Text(row.title)
            Text(row.detail).font(.caption).foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel("\(row.title), \(row.detail)")
        }
      } else {
        emptyContent
      }
      if let lastFailure {
        Text(lastFailure)
          .foregroundStyle(.red)
          .accessibilityLabel(lastFailure)
      }
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
      .padding(.horizontal, 16)
      .padding(.bottom, 12)
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

  private static func revise(_ group: LedgerAccountGroup, lifecycle: LedgerLifecycleState) -> LedgerAccountGroup? {
    try? LedgerAccountGroup(id: group.id, name: group.name, displayOrder: group.displayOrder, lifecycle: lifecycle)
  }

  private static func sortedAccounts(_ accounts: [LedgerAccount]) -> [LedgerAccount] {
    accounts.sorted {
      $0.displayOrder == $1.displayOrder ? $0.name < $1.name : $0.displayOrder < $1.displayOrder
    }
  }
}

struct AccountRow: View {
  let account: LedgerAccount
  let isEditing: Bool
  let save: (LedgerAccount) -> Void
  let edit: (LedgerAccount) -> Void

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 3) {
        Text(account.name)
        Text("\(account.currencyUnit) · \(account.variant.rawValue) · \(account.lifecycle.rawValue)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if account.hidden { Label("Hidden", systemImage: "eye.slash").font(.caption) }
      if !account.includeInTotals { Label("Excluded from totals", systemImage: "minus.circle").font(.caption) }
      if account.lifecycle == .tombstoned { Label("Closed", systemImage: "archivebox").font(.caption) }
      Menu("Actions") {
        Button("Edit account") { edit(account) }
        Button(account.hidden ? "Show account" : "Hide account") {
          update(hidden: !account.hidden)
        }
        Button(account.includeInTotals ? "Exclude from totals" : "Include in totals") {
          update(includeInTotals: !account.includeInTotals)
        }
        Button(account.lifecycle == .active ? "Close account" : "Restore account") {
          update(lifecycle: account.lifecycle == .active ? .tombstoned : .active)
        }
      }
      .disabled(!isEditing)
      .accessibilityLabel("Actions for \(account.name)")
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(account.name), \(account.currencyUnit), \(account.lifecycle.rawValue)")
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
      Text("Currency: \(account.currencyUnit)").font(.caption).foregroundStyle(.secondary)
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
  let group: LedgerAccountGroup
  let isEditing: Bool
  let save: (LedgerAccountGroup) -> Void

  var body: some View {
    HStack {
      Text(group.name)
      if group.lifecycle == .tombstoned {
        Text("Closed").font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if isEditing {
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
  let onSave: (LedgerAccountGroup) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""

  var body: some View {
    Form {
      TextField("Group name", text: $name)
      HStack {
        Button("Cancel", role: .cancel) { dismiss() }
        Spacer()
        Button("Create") { create() }
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 360)
  }

  private func create() {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let id = Self.generatedID(), let group = try? LedgerAccountGroup(id: id, name: trimmedName) else { return }
    onSave(group)
    dismiss()
  }

  private static func generatedID() -> String? {
    let value = SHA256.hash(data: Data("ledger-atlas/account-group/\(UUID().uuidString)".utf8)).map { String(format: "%02x", $0) }.joined()
    return CanonicalIdentifier.isValid(value) ? value : nil
  }
}
