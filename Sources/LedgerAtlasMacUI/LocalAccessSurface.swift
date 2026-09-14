import AppKit
import SwiftUI

struct LocalAccessSurface: View {
  let accountCount: Int
  let transactionCount: Int
  @State private var portal = LedgerLoopbackPortal()
  @State private var portalURL: URL?
  @State private var message: String?
  @State private var isStarting = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Local Web Access").font(.largeTitle.bold())
      Text("This is a temporary read-only status view on this Mac. It exposes no mutation route and contains no financial amounts, names, notes, or paths.")
        .foregroundStyle(.secondary)
      if let portalURL {
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
            self.portalURL = nil
            message = "Portal stopped."
          }
        }
      } else {
        Text("Portal is stopped.").foregroundStyle(.secondary)
        Button(isStarting ? "Starting…" : "Start read-only portal") { start() }
          .disabled(isStarting)
      }
      if let message { Text(message).foregroundStyle(.secondary).accessibilityLabel(message) }
      Spacer()
    }
    .padding(24)
    .navigationTitle("Local Web Access")
    .onDisappear {
      portal.stop()
      portalURL = nil
    }
  }

  private func start() {
    isStarting = true
    message = nil
    Task {
      do {
        portalURL = try await portal.start(
          projection: .init(
            state: .ready, accountCount: accountCount, transactionCount: transactionCount))
      } catch {
        message = "The local portal could not start."
      }
      isStarting = false
    }
  }
}
