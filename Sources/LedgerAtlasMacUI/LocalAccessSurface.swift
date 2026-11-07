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
    LedgerCardColumn(maxWidth: 640) {
      // The window title already names the screen; no second large title in the content.
      VStack(alignment: .leading, spacing: LedgerTheme.Space.s) {
        Text("This is a temporary read-only status view on this Mac. It exposes no mutation route and contains no financial amounts, names, notes, or paths.")
          .font(LedgerTheme.Typeface.secondary)
          .foregroundStyle(LedgerTheme.inkSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      VStack(alignment: .leading, spacing: LedgerTheme.Space.m) {
        if let portalURL = portal.url {
          HStack(spacing: LedgerTheme.Space.s) {
            LedgerIconTile(.symbol("network"), swatch: LedgerTheme.Swatch(color: LedgerTheme.positive, soft: LedgerTheme.fieldFill))
            Text("Portal running").font(LedgerTheme.Typeface.cardTitle).foregroundStyle(LedgerTheme.ink)
            LedgerBadge("Read-only", systemImage: "eye", tint: LedgerTheme.positive)
          }
          .accessibilityElement(children: .combine)
          Text(portalURL.absoluteString)
            .font(LedgerTheme.Typeface.mono)
            .foregroundStyle(LedgerTheme.ink)
            .textSelection(.enabled)
            .padding(.horizontal, LedgerTheme.Space.m)
            .padding(.vertical, LedgerTheme.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LedgerTheme.fieldFill, in: .rect(cornerRadius: LedgerTheme.Radius.row))
            .accessibilityLabel("Read-only portal address")
          HStack(spacing: LedgerTheme.Space.s) {
            Button("Copy address") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(portalURL.absoluteString, forType: .string)
              message = "Address copied."
            }
            .buttonStyle(LedgerPrimaryButtonStyle())
            Button("Stop portal", role: .destructive) {
              portal.stop()
              message = "Portal stopped."
            }
            .buttonStyle(LedgerSecondaryButtonStyle())
          }
        } else {
          HStack(spacing: LedgerTheme.Space.s) {
            LedgerIconTile(.symbol("network.slash"), swatch: LedgerTheme.Swatch(color: LedgerTheme.inkSecondary, soft: LedgerTheme.fieldFill))
            Text(Self.stoppedText(portal.lastStopReason))
              .font(LedgerTheme.Typeface.body)
              .foregroundStyle(LedgerTheme.inkSecondary)
          }
          .accessibilityElement(children: .combine)
          Button(isStarting ? "Starting…" : "Start read-only portal") { start() }
            .buttonStyle(LedgerPrimaryButtonStyle())
            .disabled(isStarting)
        }
        if let message { LedgerStatusLine(status: message) }
      }
      .ledgerCard()
    }
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
