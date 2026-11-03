import Foundation

/// Formats of other apps that someone might ask Ledger Atlas to write.
public enum VendorExportFormat: String, CaseIterable, Sendable {
  /// A Money Manager (Realbyte) Android v19 `.mmbak` backup.
  case moneyManagerV19 = "mm-v19"
}

public enum VendorExportError: String, Error, Equatable, Sendable {
  case vendorExportUnsupported = "vendor_export_unsupported"
}

/// Ledger Atlas v1 has no vendor writer. Import from Money Manager is one way, so a request
/// to write a Money Manager backup is refused with a stable reason and nothing is written.
public enum VendorExport {
  /// Shown on the Backup screen so the limit is visible before anyone looks for the option.
  public static let notice =
    "Backups and packages are Ledger Atlas files. Exporting to Money Manager format is not supported."

  /// Always refuses. It never opens, creates or replaces `destination`.
  public static func export(_ format: VendorExportFormat, to destination: URL) throws -> Never {
    throw VendorExportError.vendorExportUnsupported
  }
}
