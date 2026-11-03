import AppKit
import CryptoKit
import LedgerCore
import LedgerStore
import SwiftUI
import UniformTypeIdentifiers

package enum LedgerLifecycleOperation: Equatable, Sendable {
  case create, open

  package var retryButtonTitle: String { self == .create ? "Create Ledger…" : "Open Ledger…" }
  package var retryAccessibilityLabel: String { self == .create ? "Create Ledger" : "Open Ledger" }
}
package typealias LedgerLifecycleRunner =
  @Sendable (LedgerLifecycleOperation, URL) async throws
  -> LedgerStoreLifecycle.Result
package typealias LedgerSnapshotReader =
  @Sendable (LedgerStore) throws
  -> LedgerStore.LedgerReadSnapshot

package enum LedgerLifecycleGuidance: Sendable {
  case noLedger, unavailable

  package func text(retrying operation: LedgerLifecycleOperation? = nil) -> String {
    if let operation {
      return operation == .create
        ? "Choose Create Ledger to retry. Recovery is reported only after the ledger is validated."
        : "Choose Open Ledger to retry. Recovery is reported only after the ledger is validated."
    }
    return switch self {
    case .noLedger:
      "Choose Open Ledger to select a ledger. If an earlier attempt failed, select it again to retry."
    case .unavailable:
      "Choose Open Ledger to retry. Recovery is reported only after the ledger is validated."
    }
  }
}

package struct LedgerLifecycleOutcome: Equatable, Sendable {
  package enum Kind: Equatable, Sendable {
    case cancelled, missingBookmark, created, opened, upgraded, failed
  }

  package let kind: Kind
  package let recoveryImageExists: Bool
  package let message: String?
  package let retryOperation: LedgerLifecycleOperation?
  /// Why the store refused, when it did. Open Ledger uses it to remove a copy it made of a file
  /// that turned out not to be a ledger.
  package let failure: LedgerStoreLifecycle.Error?

  package init(
    kind: Kind, recoveryImageExists: Bool, message: String?,
    retryOperation: LedgerLifecycleOperation? = nil, failure: LedgerStoreLifecycle.Error? = nil
  ) {
    self.kind = kind
    self.recoveryImageExists = recoveryImageExists
    self.message = message
    self.retryOperation = retryOperation
    self.failure = failure
  }
}

struct LedgerLifecycleCompletion: @unchecked Sendable {
  // Exclusive ownership transfers from detached lifecycle work to the main actor.
  let store: LedgerStore
  let disposition: LedgerStoreLifecycle.Disposition
  let recoveryImageURL: URL?

  init(_ result: LedgerStoreLifecycle.Result) {
    store = result.store
    disposition = result.disposition
    recoveryImageURL = result.recoveryImageURL
  }
}

struct LedgerLifecyclePreparation: @unchecked Sendable {
  let completion: LedgerLifecycleCompletion
  let snapshot: LedgerStore.LedgerReadSnapshot?
  let snapshotReadFailed: Bool

  init(_ result: LedgerStoreLifecycle.Result, snapshotReader: LedgerSnapshotReader) {
    completion = LedgerLifecycleCompletion(result)
    do {
      snapshot = try snapshotReader(result.store)
      snapshotReadFailed = false
    } catch {
      snapshot = nil
      snapshotReadFailed = true
    }
  }
}

enum LedgerLifecycleFlowError: Error {
  case permissionDenied
  case snapshotValidationFailed
}

func runLedgerLifecycle(_ operation: LedgerLifecycleOperation, at url: URL) async throws
  -> LedgerStoreLifecycle.Result
{
  switch operation {
  case .create: try LedgerStoreLifecycle.create(at: url)
  case .open: try LedgerStoreLifecycle.open(at: url)
  }
}
