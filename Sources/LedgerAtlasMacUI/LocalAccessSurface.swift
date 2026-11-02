import AppKit
import SwiftUI

struct LocalAccessSurface: View {
  let accountCount: Int
  let transactionCount: Int
  let ledgerURL: URL?
  let portal: LedgerPortalController
  @State private var message: String?
  @State private var isStarting = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Local Web Access").font(.largeTitle.bold())
      Text("This is a temporary read-only status view on this Mac. It exposes no mutation route and contains no financial amounts, names, notes, or paths.")
        .foregroundStyle(.secondary)
      if let portalURL = portal.url {
        Label("Portal running", systemImage: "network")
        Text(portalURL.absoluteString)
          .font(.caption.monospaced())
          .textSelection(.enabled)
          .accessibilityLabel("Read-only portal address")
        HStack {
          Button("Copy address") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(portalURL.absoluteString, forType: .string)
            message = "Address copied."
          }
          Button("Stop portal", role: .destructive) {
            portal.stop()
            message = "Portal stopped."
          }
        }
      } else {
        Text(Self.stoppedText(portal.lastStopReason)).foregroundStyle(.secondary)
        Button(isStarting ? "Starting…" : "Start read-only portal") { start() }
          .disabled(isStarting)
      }
      if let message { Text(message).foregroundStyle(.secondary).accessibilityLabel(message) }
      Spacer()
    }
    .padding(24)
    .navigationTitle("Local Web Access")
    .onDisappear { portal.stop() }
  }

  private func start() {
    isStarting = true
    message = nil
    Task {
      do {
        _ = try await portal.start(
          projection: .init(
            state: ledgerURL == nil ? .empty : .ready, accountCount: accountCount,
            transactionCount: transactionCount),
          ledger: ledgerURL)
      } catch {
        message = "The local portal could not start."
      }
      isStarting = false
    }
  }

  static func stoppedText(_ reason: LedgerPortalController.StopReason?) -> String {
    switch reason {
    case .locked: "Portal stopped because Ledger Atlas locked."
    case .ledgerChanged: "Portal stopped because a different ledger opened."
    case .stoppedByPortal: "Portal stopped after sleep or inactivity."
    case .requested, nil: "Portal is stopped."
    }
  }
}
