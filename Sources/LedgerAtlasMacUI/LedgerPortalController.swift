import Foundation
import Observation

/// Owns the read-only loopback portal for the whole app, so the app (not a view that may or
/// may not disappear) decides when it stops. It stops when the app locks, when a different
/// ledger opens or the ledger closes, and when the person stops it. The portal itself also
/// stops on sleep and after the idle timeout. While locked it cannot start.
@MainActor
@Observable
public final class LedgerPortalController {
  public enum StopReason: Equatable, Sendable {
    case requested
    case locked
    case ledgerChanged
    case stoppedByPortal
  }

  public enum Error: Swift.Error, Equatable, Sendable {
    case locked
  }

  public private(set) var url: URL?
  public private(set) var lastStopReason: StopReason?
  public private(set) var isLocked = false

  @ObservationIgnored private let portal: LedgerLoopbackPortal
  @ObservationIgnored private var servedLedger: URL?

  public init(portal: LedgerLoopbackPortal = LedgerLoopbackPortal()) {
    self.portal = portal
    portal.onStop = { [weak self] in
      Task { @MainActor in self?.portalDidStop() }
    }
  }

  public var isRunning: Bool { url != nil }

  /// Starts the portal for `ledger` (nil when none is open) with a counts-only projection.
  public func start(projection: LedgerPortalProjection, ledger: URL?) async throws -> URL {
    guard !isLocked else { throw Error.locked }
    servedLedger = ledger?.standardizedFileURL
    let started = try await portal.start(projection: projection)
    // The app may have locked while the listener was coming up.
    guard !isLocked else {
      stop(.locked)
      throw Error.locked
    }
    url = started
    lastStopReason = nil
    return started
  }

  public func stop(_ reason: StopReason = .requested) {
    let wasRunning = url != nil || portal.url != nil
    portal.stop()
    url = nil
    servedLedger = nil
    if wasRunning { lastStopReason = reason }
  }

  public func lockDidChange(isLocked locked: Bool) {
    isLocked = locked
    if locked { stop(.locked) }
  }

  public func ledgerDidChange(to ledger: URL?) {
    guard url != nil, ledger?.standardizedFileURL != servedLedger else { return }
    stop(.ledgerChanged)
  }

  private func portalDidStop() {
    // Sleep or the idle timeout stopped the listener underneath us.
    guard url != nil, portal.url == nil else { return }
    url = nil
    servedLedger = nil
    lastStopReason = .stoppedByPortal
  }
}
