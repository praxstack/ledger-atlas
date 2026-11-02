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
