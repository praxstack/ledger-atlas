import AppKit
import SwiftUI

/// First launch, or no ledger open: importing a Money Manager backup is the one obvious path,
/// with starting empty, opening a ledger and trying sample data as quiet alternatives.
struct LedgerWelcomeView: View {
  @Binding var sourceTimeZoneIdentifier: String
  let failure: String?
  let importDisabled: Bool
  let importBackup: () -> Void
  let createLedger: () -> Void
  let openLedger: () -> Void
  let trySampleData: () -> Void

  var body: some View {
    ScrollView {
      VStack(spacing: LedgerTheme.Space.xxl) {
        header
        importPanel
        steps
        alternatives
        Label("Everything stays on this Mac. Nothing is uploaded.", systemImage: "lock")
          .font(LedgerTheme.Typeface.caption)
          .foregroundStyle(LedgerTheme.inkTertiary)
      }
      .frame(maxWidth: 560)
      .padding(.horizontal, LedgerTheme.Space.xxxl)
      .padding(.vertical, LedgerTheme.Space.xxxl * 1.5)
      .frame(maxWidth: .infinity)
    }
    .ledgerCanvas()
    .navigationTitle("Welcome")
  }

  private var header: some View {
    VStack(spacing: LedgerTheme.Space.m) {
      LedgerAtlasMark(size: 72)
      Text("Bring over your Money Manager history")
        .font(LedgerTheme.Typeface.display)
        .foregroundStyle(LedgerTheme.ink)
        .multilineTextAlignment(.center)
        .accessibilityAddTraits(.isHeader)
      Text("Every account, category, transfer and note comes across exactly, and you check it all before anything is saved.")
        .font(LedgerTheme.Typeface.body)
        .foregroundStyle(LedgerTheme.inkSecondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        // About 480 pt, so the sentence breaks into two even lines without an orphan.
        .frame(maxWidth: 480)
    }
  }

  private var importPanel: some View {
    VStack(spacing: LedgerTheme.Space.l) {
      Button(action: importBackup) {
        Label("Choose Backup…", systemImage: "square.and.arrow.down")
      }
      .buttonStyle(LedgerPrimaryButtonStyle(large: true))
      .keyboardShortcut(.defaultAction)
      .disabled(importDisabled)
      .accessibilityLabel("Choose Money Manager backup to import")
      .accessibilityHint("Opens a file panel. The backup is read, never changed.")
      .help("Import a Money Manager backup (⇧⌘I)")

      Text("A .mmbak file from Money Manager on iPhone or Mac.")
        .font(LedgerTheme.Typeface.caption)
        .foregroundStyle(LedgerTheme.inkTertiary)

      Picker("Times in the backup are in", selection: $sourceTimeZoneIdentifier) {
        ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { identifier in
          Text(identifier).tag(identifier)
        }
      }
      .pickerStyle(.menu)
      .fixedSize()
      .font(LedgerTheme.Typeface.caption)
      .accessibilityLabel("Backup source time zone")
      .accessibilityHint("The time zone the backup's dates were recorded in. Shown again in the review.")

      if let failure {
        Label(failure, systemImage: "exclamationmark.triangle")
          .font(LedgerTheme.Typeface.secondary)
          .foregroundStyle(LedgerTheme.negative)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(LedgerTheme.Space.xxl)
    .frame(maxWidth: .infinity)
    .background(LedgerTheme.recessed, in: .rect(cornerRadius: LedgerTheme.Radius.card))
    .overlay(
      RoundedRectangle(cornerRadius: LedgerTheme.Radius.card)
        .strokeBorder(LedgerTheme.hairline, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
    )
  }

  private var steps: some View {
    HStack(alignment: .top, spacing: LedgerTheme.Space.l) {
      step(1, "Choose", "Pick the backup file.")
      step(2, "Review", "See counts, totals and anything unusual.")
      step(3, "Approve", "Only then is your ledger written.")
    }
  }

  private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
    VStack(alignment: .leading, spacing: LedgerTheme.Space.xs) {
      Text("\(number)")
        .font(LedgerTheme.Typeface.captionEmphasis)
        .monospacedDigit()
        .foregroundStyle(LedgerTheme.accent)
        .frame(width: 22, height: 22)
        .background(LedgerTheme.accentSoft, in: .circle)
        .accessibilityHidden(true)
      Text(title).font(LedgerTheme.Typeface.bodyEmphasis).foregroundStyle(LedgerTheme.ink)
      Text(detail)
        .font(LedgerTheme.Typeface.caption)
        .foregroundStyle(LedgerTheme.inkSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Step \(number), \(title): \(detail)")
  }

  private var alternatives: some View {
    HStack(spacing: LedgerTheme.Space.s) {
      Button("Start an empty ledger", action: createLedger)
        .accessibilityLabel("Start an empty ledger")
        .accessibilityHint("Makes a new, empty Ledger Atlas ledger.")
      Text("·").foregroundStyle(LedgerTheme.inkTertiary).accessibilityHidden(true)
      // The exact title "Open a ledger" is what the empty-state checks look for.
      Button("Open a ledger", action: openLedger)
        .accessibilityLabel("Open a ledger")
        .accessibilityHint("Opens an existing Ledger Atlas ledger. A ledger from elsewhere is copied in.")
      Text("·").foregroundStyle(LedgerTheme.inkTertiary).accessibilityHidden(true)
      Button("Try sample data", action: trySampleData)
        .accessibilityLabel("Try sample data")
        .accessibilityHint("Opens a made-up household ledger to explore. Your data is not touched.")
    }
    .buttonStyle(LedgerLinkButtonStyle())
    .font(LedgerTheme.Typeface.secondary)
  }
}
