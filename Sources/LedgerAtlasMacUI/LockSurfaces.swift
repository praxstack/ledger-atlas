import SwiftUI

struct LockedSurface: View {
  let lock: LedgerAppLock
  let unlock: (String) -> Bool
  let biometricUnlock: () async -> Bool
  @State private var passcode = ""
  @State private var invalidAttempt = false
  @State private var biometricAttempted = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Ledger Atlas is locked", systemImage: "lock.shield")
        .font(.title2.bold())
      Text("Unlock to view ledger content. The widget and this window stay redacted while locked.")
        .foregroundStyle(.secondary)
      SecureField("Passcode", text: $passcode)
        .textFieldStyle(.roundedBorder)
        .textContentType(.password)
        .accessibilityLabel("Ledger Atlas passcode")
      if let message = lock.lockoutMessage {
        Text(message).foregroundStyle(.red).accessibilityLabel(message)
      } else if invalidAttempt {
        Text("That passcode was not accepted.").foregroundStyle(.red)
      }
      HStack {
        Button("Unlock") {
          invalidAttempt = !unlock(passcode)
          if !invalidAttempt { passcode = "" }
        }
        .keyboardShortcut(.defaultAction)
        if !biometricAttempted {
          Button("Use Touch ID") {
            biometricAttempted = true
            Task {
              _ = await biometricUnlock()
              biometricAttempted = false
            }
          }
        }
      }
    }
    .frame(maxWidth: 480, alignment: .leading)
    .padding(40)
    .accessibilityElement(children: .contain)
  }
}

struct SettingsSurface: View {
  let lock: LedgerAppLock
  let lockNow: () -> Void
  let reducedMotion: Bool
  @State private var showingPasscodeForm = false
  @State private var message: String?

  var body: some View {
    Form {
      Section("Privacy") {
        LabeledContent("Application lock", value: lock.hasPasscode ? "Enabled" : "Not configured")
        Text("Financial content is redacted in the app and widget while locked.")
          .font(.caption).foregroundStyle(.secondary)
        if lock.hasPasscode {
          Button("Lock now", action: lockNow)
          Button("Remove passcode", role: .destructive) {
            do {
              try lock.removePasscode()
              message = "Application lock removed."
            } catch {
              message = "Passcode could not be removed."
            }
          }
        } else {
          Button("Set passcode…") { showingPasscodeForm = true }
        }
      }
      Section("Accessibility") {
        LabeledContent("Reduce Motion", value: reducedMotion ? "On" : "Off")
        Text("Keyboard navigation and explicit VoiceOver labels are used throughout the app.")
          .font(.caption).foregroundStyle(.secondary)
      }
      if let message { Text(message).foregroundStyle(.secondary) }
    }
    .formStyle(.grouped)
    .navigationTitle("Settings")
    .sheet(isPresented: $showingPasscodeForm) {
      PasscodeForm { passcode in
        do {
          try lock.setPasscode(passcode)
          message = "Application lock enabled."
          return nil
        } catch LedgerAppLock.Error.invalidPasscode {
          return "Use an ASCII passcode between 4 and 128 characters."
        } catch {
          return "Passcode could not be saved."
        }
      }
    }
  }
}

private struct PasscodeForm: View {
  let save: (String) -> String?
  @Environment(\.dismiss) private var dismiss
  @State private var passcode = ""
  @State private var confirmation = ""
  @State private var error: String?

  var body: some View {
    Form {
      SecureField("Passcode", text: $passcode).textContentType(.newPassword)
      SecureField("Confirm passcode", text: $confirmation).textContentType(.newPassword)
      if let error { Text(error).foregroundStyle(.red) }
      HStack {
        Button("Cancel", role: .cancel) { dismiss() }
        Spacer()
        Button("Save") {
          guard passcode == confirmation else {
            error = "Passcodes do not match."
            return
          }
          if let message = save(passcode) {
            error = message
          } else {
            dismiss()
          }
        }
        .disabled(passcode.isEmpty || confirmation.isEmpty)
      }
    }
    .padding(20)
    .frame(width: 380)
    .accessibilityElement(children: .contain)
  }
}

