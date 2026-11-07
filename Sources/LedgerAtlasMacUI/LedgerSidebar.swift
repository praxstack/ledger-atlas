import LedgerCore
import LedgerStore
import SwiftUI

/// What a sidebar row selects: a screen, or one account (shown on the Accounts screen).
enum SidebarItem: Hashable {
  case screen(AppDestination)
  case account(String)
}

/// One account in the sidebar, with its balance.
struct LedgerSidebarAccount: Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let groupName: String?
  let balance: CurrencyAmount?
  /// A negative balance on an asset account is a problem; on a card or loan it is normal.
  let isAsset: Bool

  /// The open, visible accounts in the order the person arranged them: by group, then by the
  /// account's own order. Balances come from one balance sheet, computed once per snapshot.
  static func list(
    accounts: [LedgerAccount], groups: [LedgerAccountGroup], transactions: [LedgerTransactionSnapshot]
  ) -> [LedgerSidebarAccount] {
    let sheet = try? LedgerAccountBalanceSheet(accounts: accounts, transactions: transactions)
    let groupsByID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    func groupOrder(_ account: LedgerAccount) -> Int {
      account.groupID.flatMap { groupsByID[$0]?.displayOrder } ?? Int.max
    }
    return
      accounts
      .filter { $0.lifecycle == .active && !$0.hidden }
      .sorted {
        (groupOrder($0), $0.displayOrder, $0.name) < (groupOrder($1), $1.displayOrder, $1.name)
      }
      .map { account in
        LedgerSidebarAccount(
          id: account.id, name: account.name,
          groupName: account.groupID.flatMap { groupsByID[$0]?.name },
          balance: sheet?.balances[account.id], isAsset: account.accountClass == .asset)
      }
  }
}

/// The floating sidebar: the money screens, the accounts with live balances, then the tools
/// that organise and keep the ledger. The Money Manager import card stays pinned at the bottom
/// so importing is obvious from the first launch.
struct LedgerSidebar: View {
  @Binding var selection: AppDestination
  @Binding var focusedAccountID: String?
  let accounts: [LedgerSidebarAccount]
  let showsImportCard: Bool
  let importDisabled: Bool
  let importBackup: () -> Void

  private var listSelection: Binding<SidebarItem?> {
    Binding(
      get: {
        if selection == .accounts, let focusedAccountID { return .account(focusedAccountID) }
        return .screen(selection)
      },
      set: { item in
        switch item {
        case .screen(let destination)?:
          focusedAccountID = nil
          selection = destination
        case .account(let id)?:
          focusedAccountID = id
          selection = .accounts
        case nil:
          break
        }
      })
  }

  var body: some View {
    List(selection: listSelection) {
      section(.money)
      if !accounts.isEmpty {
        Section("Accounts") {
          let swatches = LedgerTheme.accountSwatches(for: accounts.map(\.name))
          ForEach(accounts) { account in
            LedgerSidebarAccountRow(
              account: account,
              key: swatches[account.name]?.color ?? LedgerTheme.paletteColor(for: account.name))
              .tag(SidebarItem.account(account.id))
          }
        }
      }
      section(.organise)
      section(.ledger)
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if showsImportCard {
        LedgerImportCard(disabled: importDisabled, importBackup: importBackup)
          .padding(.horizontal, LedgerTheme.Space.m)
          .padding(.bottom, LedgerTheme.Space.m)
      }
    }
  }

  private func section(_ section: AppDestination.SidebarSection) -> some View {
    Section(section.rawValue) {
      ForEach(section.destinations) { destination in
        Label(destination.sidebarTitle, systemImage: destination.systemImageName)
          .tag(SidebarItem.screen(destination))
          .accessibilityLabel(destination.accessibilityLabel)
          .accessibilityHint(destination.accessibilityHint)
      }
    }
  }
}

/// An account row: name on the left, balance on the right in tabular figures.
struct LedgerSidebarAccountRow: View {
  let account: LedgerSidebarAccount
  /// The account's own colour, the same one its Accounts tile uses.
  let key: Color
  @Environment(\.ledgerFormatter) private var formatter

  var body: some View {
    HStack(spacing: LedgerTheme.Space.s) {
      LedgerColorKey(key)
      Text(account.name).lineLimit(1).truncationMode(.tail)
      Spacer(minLength: LedgerTheme.Space.xs)
      if let balance = account.balance {
        MoneyText(balance, size: .small, tone: .automatic, negativeIsAlert: account.isAsset)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spokenLabel)
    .accessibilityHint("Shows this account on the Accounts screen.")
  }

  private var spokenLabel: String {
    guard let balance = account.balance else { return account.name }
    return "\(account.name), \(formatter.parts(balance).text)"
  }
}

/// The pinned import card: one clear way to bring a Money Manager history over.
struct LedgerImportCard: View {
  let disabled: Bool
  let importBackup: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: LedgerTheme.Space.s) {
      HStack(spacing: LedgerTheme.Space.s) {
        LedgerIconTile(
          .symbol("square.and.arrow.down"),
          swatch: LedgerTheme.Swatch(color: LedgerTheme.accent, soft: LedgerTheme.accentSoft))
        VStack(alignment: .leading, spacing: LedgerTheme.Space.xxs) {
          Text("Import from Money Manager")
            .font(LedgerTheme.Typeface.captionEmphasis)
            .foregroundStyle(LedgerTheme.ink)
          Text("You review everything first. The backup is never changed.")
            .font(LedgerTheme.Typeface.caption)
            .foregroundStyle(LedgerTheme.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Button("Choose Backup…", action: importBackup)
        .buttonStyle(LedgerPrimaryButtonStyle())
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(disabled)
        .accessibilityLabel("Choose Money Manager backup to import")
        .accessibilityHint("Opens a file panel. The backup is read, never changed.")
        .help("Import a Money Manager backup (⇧⌘I)")
    }
    .padding(LedgerTheme.Space.m)
    .frame(maxWidth: .infinity, alignment: .leading)
    // Solid, not glass: the sidebar itself is the glass layer.
    .ledgerGroupBox()
  }
}
