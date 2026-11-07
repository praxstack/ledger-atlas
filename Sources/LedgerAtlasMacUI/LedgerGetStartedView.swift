import AppKit
import SwiftUI

/// Get Started: the few things that make Ledger Atlas yours, in order, each one click away.
/// Bringing over the Money Manager history comes first and shows as done once a ledger is
/// open; the rest open the screen where that step happens.
struct LedgerGetStartedView: View {
  /// A ledger is open, so the history has been brought over (or the person started fresh).
  let hasLedger: Bool
  let importDisabled: Bool
  let importBackup: () -> Void
  let show: (AppDestination) -> Void

  /// Approved wording (Prax, 2026-11-07) for what happens after the first import.
  static let afterImportNote =
    "From today, log on the Mac. Re-importing newer phone backups arrives in January."

  struct Step: Identifiable {
    let id: String
    let symbol: String
    let title: String
    let detail: String
    let action: String
    let destination: AppDestination?
  }

  static let laterSteps: [Step] = [
    Step(
      id: "log", symbol: "plus.circle.fill", title: "Log new spending here",
      detail: afterImportNote, action: "Open Transactions", destination: .ledger),
    Step(
      id: "budget", symbol: "chart.bar.fill", title: "Set a monthly budget",
      detail: "Pick the categories you want to keep an eye on and how much each month.",
      action: "Open Budgets", destination: .budgets),
    Step(
      id: "backup", symbol: "externaldrive.fill", title: "Make your first backup",
      detail: "A backup is one file you can keep anywhere and restore exactly.",
      action: "Open Backup & Restore", destination: .backupRestore),
    Step(
      id: "lock", symbol: "lock.fill", title: "Lock the app with a passcode",
      detail: "Hides every amount and account until you unlock.",
      action: "Open Settings", destination: .settings),
  ]

  var body: some View {
    LedgerPage {
      header
      VStack(spacing: 0) {
        importStep
        ForEach(Self.laterSteps) { step in
          LedgerPageDivider()
          row(step)
        }
      }
      .ledgerCard(padding: 0)
      Label("Everything stays on this Mac. Nothing is uploaded.", systemImage: "lock")
        .font(LedgerTheme.Typeface.caption)
        .foregroundStyle(LedgerTheme.inkSecondary)
    }
    .navigationTitle("Get Started")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: LedgerTheme.Space.s) {
      Text("Make Ledger Atlas yours")
        .font(LedgerTheme.Typeface.display)
        .foregroundStyle(LedgerTheme.ink)
        .accessibilityAddTraits(.isHeader)
      Text(
        hasLedger
          ? "Your history is here. Four short steps keep it up to date and safe."
          : "Start by bringing over your Money Manager history; the rest takes a few minutes."
      )
      .font(LedgerTheme.Typeface.body)
      .foregroundStyle(LedgerTheme.inkSecondary)
      .fixedSize(horizontal: false, vertical: true)
      .ledgerReadableWidth()
    }
  }

  /// Step one: done with a check once a ledger is open, otherwise the primary action.
  private var importStep: some View {
    HStack(alignment: .center, spacing: LedgerTheme.Space.m) {
      LedgerIconTile(
        .symbol(hasLedger ? "checkmark" : "square.and.arrow.down"),
        swatch: hasLedger ? LedgerTheme.palette[2] : LedgerTheme.palette[5])
      VStack(alignment: .leading, spacing: LedgerTheme.Space.xxs) {
        Text("Bring over your Money Manager history")
          .font(LedgerTheme.Typeface.bodyEmphasis)
          .foregroundStyle(LedgerTheme.ink)
        Text(
          hasLedger
            ? "Done. Import Review shows what came across."
            : "Choose the backup, check it, then approve. The backup is only read, never changed."
        )
        .font(LedgerTheme.Typeface.caption)
        .foregroundStyle(LedgerTheme.inkSecondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: LedgerTheme.Space.m)
      if hasLedger {
        Button("Open Import Review") { show(.importReview) }
          .buttonStyle(LedgerSecondaryButtonStyle())
          .accessibilityLabel("Open Import Review")
      } else {
        Button(action: importBackup) {
          Label("Choose Backup…", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(LedgerPrimaryButtonStyle())
        .disabled(importDisabled)
        .accessibilityLabel("Choose Money Manager backup to import")
        .help("Import a Money Manager backup (⇧⌘I)")
      }
    }
    .padding(LedgerTheme.Space.l)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(hasLedger ? "Step 1, done: bring over your Money Manager history" : "Step 1: bring over your Money Manager history")
  }

  private func row(_ step: Step) -> some View {
    HStack(alignment: .center, spacing: LedgerTheme.Space.m) {
      LedgerIconTile(.symbol(step.symbol), swatch: LedgerTheme.swatch(for: step.id))
      VStack(alignment: .leading, spacing: LedgerTheme.Space.xxs) {
        Text(step.title)
          .font(LedgerTheme.Typeface.bodyEmphasis)
          .foregroundStyle(LedgerTheme.ink)
        Text(step.detail)
          .font(LedgerTheme.Typeface.caption)
          .foregroundStyle(LedgerTheme.inkSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: LedgerTheme.Space.m)
      if let destination = step.destination {
        Button(step.action) { show(destination) }
          .buttonStyle(LedgerSecondaryButtonStyle())
          .disabled(!hasLedger)
          .accessibilityLabel(step.action)
      }
    }
    .padding(LedgerTheme.Space.l)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(step.title). \(step.detail)")
  }
}
