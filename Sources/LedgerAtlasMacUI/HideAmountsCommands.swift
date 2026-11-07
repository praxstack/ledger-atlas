import SwiftUI

extension FocusedValues {
  /// The open window's Hide amounts setting (#173), for the View menu command.
  @Entry var ledgerHidesAmounts: Binding<Bool>?
}

/// View > Hide Amounts (⇧⌘H). It turns Hide amounts on or off in the front window; with no
/// ledger window in front it is disabled.
public struct LedgerHideAmountsCommands: Commands {
  @FocusedBinding(\.ledgerHidesAmounts) private var hidesAmounts

  public init() {}

  public var body: some Commands {
    CommandGroup(after: .toolbar) {
      Toggle(
        "Hide Amounts",
        isOn: Binding(get: { hidesAmounts ?? false }, set: { hidesAmounts = $0 })
      )
      .keyboardShortcut("h", modifiers: [.command, .shift])
      .disabled(hidesAmounts == nil)
    }
  }
}
