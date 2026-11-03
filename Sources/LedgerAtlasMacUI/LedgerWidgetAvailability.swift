import Foundation
import Security
import os

/// Whether this build can share its status with the widget, and the publisher to use.
///
/// The widget reads its status from the App Group container. macOS lets an app use that
/// container only when the build is signed with a Team ID that matches the group. The free
/// ad-hoc DMG has no Team ID, so writing there fails (or asks the person for access to "data
/// from other apps"). That build gets no publisher: the widget then shows "Open Ledger Atlas to
/// continue.", and nothing in the app reports or reacts to it.
public enum LedgerWidgetAvailability {
  static let log = Logger(subsystem: "com.praxstack.ledgeratlas", category: "widget")

  /// The publisher for the running app, or nil when the build has no usable App Group.
  package static func publisherForThisBuild(
    teamIdentifier: String? = signingTeamIdentifier(),
    containerURL: (String) -> URL? = {
      FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
    }
  ) -> RedactedWidgetProjectionPublisher? {
    guard teamIdentifier != nil else {
      log.info("widget status off: this build is not signed with a Team ID")
      return nil
    }
    guard let container = containerURL(RedactedWidgetProjectionStore.appGroupIdentifier) else {
      log.info("widget status off: no App Group container")
      return nil
    }
    return RedactedWidgetProjectionPublisher(store: .init(containerURL: container))
  }

  /// The Team ID the running code is signed with; nil for ad-hoc and unsigned builds.
  public static func signingTeamIdentifier() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
      return nil
    }
    var information: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        == errSecSuccess,
      let values = information as? [String: Any]
    else { return nil }
    return values[kSecCodeInfoTeamIdentifier as String] as? String
  }
}
