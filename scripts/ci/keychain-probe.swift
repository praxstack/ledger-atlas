// Keychain probe. Built optimized (no DEBUG) and ad-hoc signed with the app's sandbox and
// app-group entitlements, like the shipped DMG. It reports what the Keychain allows for the
// receipt trust key (synchronizable first, as LedgerReceiptTrust does) and the app-lock item.
// Mode "write" creates items; mode "read" only reads, for a second, differently signed build.
import Foundation
import Security

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "write"
let service = "com.praxstack.ledger-atlas.keychain-probe"
var rows: [String] = []

func name(_ status: OSStatus) -> String {
  let text = SecCopyErrorMessageString(status, nil) as String? ?? ""
  return "\(status) \(text)"
}

func add(_ account: String, synchronizable: Bool?) -> OSStatus {
  var attributes: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: account,
    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
    kSecValueData as String: Data(repeating: 7, count: 32),
  ]
  if let synchronizable { attributes[kSecAttrSynchronizable as String] = synchronizable }
  return SecItemAdd(attributes as CFDictionary, nil)
}

func read(_ account: String, synchronizable: Any?) -> OSStatus {
  var query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: account,
    kSecReturnData as String: true,
    kSecMatchLimit as String: kSecMatchLimitOne,
  ]
  if let synchronizable { query[kSecAttrSynchronizable as String] = synchronizable }
  var item: CFTypeRef?
  return SecItemCopyMatching(query as CFDictionary, &item)
}

func row(_ step: String, _ status: OSStatus) {
  rows.append("| \(mode) | \(step) | \(name(status)) |")
  // Flush each row at once: a later call can block on a Keychain prompt.
  print(rows.last!)
  fflush(stdout)
}

if mode == "write" {
  row("add synchronizable (receipt key, as shipped)", add("sync", synchronizable: true))
  row("read synchronizable", read("sync", synchronizable: true))
  row("add device-only (app lock style)", add("local", synchronizable: nil))
  row("read device-only", read("local", synchronizable: nil))
  row("read device-only, synchronizable any", read("local", synchronizable: kSecAttrSynchronizableAny))
} else {
  row("read synchronizable (other build)", read("sync", synchronizable: true))
  row("read device-only (other build)", read("local", synchronizable: nil))
}
