import AppKit
import CryptoKit
import LedgerCore
import LedgerStore
import SwiftUI
import UniformTypeIdentifiers

struct LedgerLifecycleGuidanceView: View {
  let guidance: LedgerLifecycleGuidance
  let failure: String?
  let retryOperation: LedgerLifecycleOperation?

  init(
    guidance: LedgerLifecycleGuidance, failure: String?,
    retryOperation: LedgerLifecycleOperation? = nil
  ) {
    self.guidance = guidance
    self.failure = failure
    self.retryOperation = retryOperation
  }

  var body: some View {
    VStack(alignment: .leading, spacing: LedgerTheme.Space.xs) {
      Text(guidance.text(retrying: retryOperation))
        .font(LedgerTheme.Typeface.secondary)
        .foregroundStyle(LedgerTheme.inkSecondary)
        .fixedSize(horizontal: false, vertical: true)
      if let failure {
        Text(failure)
          .font(LedgerTheme.Typeface.secondary)
          .foregroundStyle(LedgerTheme.negative)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      [guidance.text(retrying: retryOperation), failure].compactMap { $0 }.joined(separator: " ")
    )
    .accessibilityHint("Use the available action to select or retry a ledger.")
  }
}

struct LedgerLifecycleClosedSessionView: View {
  let title: String
  let guidance: LedgerLifecycleGuidance
  let failure: String?
  let retryOperation: LedgerLifecycleOperation
  let retry: (LedgerLifecycleOperation) -> Void
  var importBackup: (() -> Void)? = nil

  var body: some View {
    VStack(spacing: LedgerTheme.Space.m) {
      ZStack {
        RoundedRectangle(cornerRadius: LedgerTheme.Radius.tile, style: .continuous).fill(LedgerTheme.fieldFill)
        Image(systemName: "exclamationmark.triangle")
          .font(LedgerTheme.Typeface.figure)
          .foregroundStyle(LedgerTheme.warning)
      }
      .frame(width: 44, height: 44)
      .accessibilityHidden(true)
      Text(title)
        .font(LedgerTheme.Typeface.screenTitle)
        .foregroundStyle(LedgerTheme.ink)
        .accessibilityAddTraits(.isHeader)
      LedgerLifecycleGuidanceView(
        guidance: guidance, failure: failure, retryOperation: retryOperation)
        .multilineTextAlignment(.center)
      HStack(spacing: LedgerTheme.Space.s) {
        Button(retryOperation.retryButtonTitle) { retry(retryOperation) }
          .buttonStyle(LedgerPrimaryButtonStyle())
          .accessibilityLabel(retryOperation.retryAccessibilityLabel)
        if let importBackup {
          Button(LedgerAtlasRootView.importBackupActionTitle, action: importBackup)
            .buttonStyle(LedgerSecondaryButtonStyle())
        }
      }
      .padding(.top, LedgerTheme.Space.xs)
    }
    .frame(maxWidth: 420)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(LedgerTheme.Space.xxxl)
    .ledgerCanvas()
    .accessibilityElement(children: .contain)
  }
}

struct EmptyLedgerPrompt: View {
  let title: String
  let description: String
  let guidance: LedgerLifecycleGuidance
  let failure: String?
  let buttonTitle: String
  let open: () -> Void

  var body: some View {
    VStack(spacing: LedgerTheme.Space.m) {
      ZStack {
        RoundedRectangle(cornerRadius: LedgerTheme.Radius.tile, style: .continuous).fill(LedgerTheme.fieldFill)
        Image(systemName: "folder")
          .font(LedgerTheme.Typeface.figure)
          .foregroundStyle(LedgerTheme.inkSecondary)
      }
      .frame(width: 44, height: 44)
      .accessibilityHidden(true)
      Text(title)
        .font(LedgerTheme.Typeface.screenTitle)
        .foregroundStyle(LedgerTheme.ink)
        .accessibilityAddTraits(.isHeader)
      Text(description)
        .font(LedgerTheme.Typeface.secondary)
        .foregroundStyle(LedgerTheme.inkSecondary)
        .multilineTextAlignment(.center)
      LedgerLifecycleGuidanceView(guidance: guidance, failure: failure)
        .multilineTextAlignment(.center)
      Button(buttonTitle, action: open)
        .buttonStyle(LedgerPrimaryButtonStyle())
        .padding(.top, LedgerTheme.Space.xs)
    }
    .frame(maxWidth: 420)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(LedgerTheme.Space.xxxl)
  }
}

/// Shown while an import step runs off the main thread. A real backup takes minutes, so it
/// says so and counts the time.
struct ImportProgressView: View {
  let work: LedgerJourney.BackgroundWork
  @State private var started = Date()

  private var title: String {
    switch work {
    case .preparingImport: "Reading the backup…"
    case .importing: "Importing into a new ledger…"
    case .bulkEditing, .revertingBulkEdit: BulkEditWording.working(work) ?? ""
    }
  }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        ProgressView().controlSize(.small)
        VStack(alignment: .leading, spacing: LedgerTheme.Space.xxs) {
          Text(title).font(LedgerTheme.Typeface.bodyEmphasis).foregroundStyle(LedgerTheme.ink)
          Text(
            "\(LedgerElapsedTime.text(since: started, now: context.date)). A large backup can take several minutes."
          )
          .font(LedgerTheme.Typeface.caption).foregroundStyle(LedgerTheme.inkSecondary)
        }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(title)
    .accessibilityIdentifier("import.progress")
  }
}

/// Shown while a ledger opens. The first open of a large ledger checks every record and can
/// take a minute or more; later opens of the same file skip that and take seconds.
struct OpeningLedgerView: View {
  @State private var started = Date()

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let seconds = context.date.timeIntervalSince(started)
      VStack(spacing: 8) {
        ProgressView("Opening ledger…")
        if seconds >= 3 {
          Text(
            "Checking every record (\(LedgerElapsedTime.text(since: started, now: context.date))). The first open of a large ledger can take a minute or more; later opens are quick."
          )
          .font(LedgerTheme.Typeface.caption).foregroundStyle(LedgerTheme.inkSecondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 360)
        }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Opening ledger")
  }
}

enum LedgerElapsedTime {
  /// "12 s" under a minute, then "1 min 05 s".
  static func text(since start: Date, now: Date) -> String {
    let total = max(0, Int(now.timeIntervalSince(start)))
    guard total >= 60 else { return "\(total) s" }
    return String(format: "%d min %02d s", total / 60, total % 60)
  }
}
