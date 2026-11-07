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
      VStack(alignment: .leading, spacing: LedgerTheme.Space.m) {
        // The window title already names the screen; no second large title in the content.
        LedgerCardHeader("Read-only portal") { statusLabel }
        Text("Open a status page for this ledger in a browser on this Mac. It shows counts only, never amounts, names, notes or file paths, and nothing can be changed from it.")
          .font(LedgerTheme.Typeface.secondary)
          .foregroundStyle(LedgerTheme.inkSecondary)
          .frame(maxWidth: 560, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
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
    .navigationTitle(AppDestination.localAccess.sidebarTitle)
    .onDisappear { portal.stop() }
  }

  /// A dot and one word, so the state reads at a glance and never by colour alone.
  private var statusLabel: some View {
    let running = portal.url != nil
    return HStack(spacing: LedgerTheme.Space.xs) {
      Image(systemName: "circle.fill")
        .font(LedgerTheme.Typeface.caption)
        .imageScale(.small)
        .foregroundStyle(running ? LedgerTheme.positive : LedgerTheme.inkTertiary)
        .accessibilityHidden(true)
      Text(running ? "Running" : "Stopped")
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(running ? "Portal running" : "Portal stopped")
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
