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
    VStack(alignment: .leading, spacing: 4) {
      Text(guidance.text(retrying: retryOperation)).foregroundStyle(.secondary)
      if let failure {
        Text(failure).foregroundStyle(.red)
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

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title).font(.largeTitle.bold())
      LedgerLifecycleGuidanceView(
        guidance: guidance, failure: failure, retryOperation: retryOperation)
      Button(retryOperation.retryButtonTitle) { retry(retryOperation) }
        .accessibilityLabel(retryOperation.retryAccessibilityLabel)
    }
    .padding(32)
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
    VStack(spacing: 12) {
      Image(systemName: "folder").font(.largeTitle).foregroundStyle(.secondary)
      Text(title).font(.title2.bold())
      Text(description).foregroundStyle(.secondary)
      LedgerLifecycleGuidanceView(guidance: guidance, failure: failure)
      Button(buttonTitle, action: open)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(32)
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
    }
  }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        ProgressView().controlSize(.small)
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
          Text(
            "\(LedgerElapsedTime.text(since: started, now: context.date)). A large backup can take several minutes."
          )
          .font(.caption).foregroundStyle(.secondary)
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
          .font(.caption).foregroundStyle(.secondary)
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
