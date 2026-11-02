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
      if lock.storageUnavailable {
        Text("Credential storage is unavailable. Restore access and reopen Ledger Atlas.")
          .foregroundStyle(.red)
      } else if let message = lock.lockoutMessage {
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
  @Binding var settings: LedgerProductSettings
  let lockNow: () -> Void
  let reducedMotion: Bool
  let exportDiagnostics: () -> Void
  @State private var passcodeForm: PasscodeForm.Mode?
  @State private var message: String?

  var body: some View {
    Form {
      Section("Privacy") {
        LabeledContent("Application lock", value: lock.hasPasscode ? "Enabled" : "Not configured")
        Text(
          "Financial content is redacted in the app and widget while locked. The lock hides the open ledger; it does not encrypt ledger files on disk."
        )
        .font(.caption).foregroundStyle(.secondary)
        if lock.hasPasscode {
          Button("Lock now", action: lockNow)
          Button("Change passcode…") { passcodeForm = .change }
          Button("Remove passcode…", role: .destructive) { passcodeForm = .remove }
        } else {
          Button("Set passcode…") { passcodeForm = .set }
        }
      }
      Section("Accessibility") {
        LabeledContent("Reduce Motion", value: reducedMotion ? "On" : "Off")
        Text("Keyboard navigation and explicit VoiceOver labels are used throughout the app.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Presentation") {
        Picker("Appearance", selection: $settings.appearance) {
          Text("System").tag(LedgerProductSettings.Appearance.system)
          Text("Light").tag(LedgerProductSettings.Appearance.light)
          Text("Dark").tag(LedgerProductSettings.Appearance.dark)
        }
        Picker("Locale", selection: $settings.localeIdentifier) {
          Text("English (United States)").tag("en_US")
          Text("English (United Kingdom)").tag("en_GB")
          Text("German").tag("de_DE")
          Text("Japanese").tag("ja_JP")
        }
        Text("Locale changes affect presentation only. Canonical amounts and dates remain typed values.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Report periods") {
        Picker("First weekday", selection: $settings.firstWeekday) {
          Text("Sunday").tag(1)
          Text("Monday").tag(2)
        }
        Stepper("Period start day: \(settings.periodStartDay)", value: $settings.periodStartDay, in: 1...28)
          .accessibilityValue(String(settings.periodStartDay))
        Text("Period starts are limited to days 1 through 28 so every month has a valid boundary.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Notifications") {
        Toggle("Daily reminders", isOn: $settings.remindersEnabled)
          .onChange(of: settings.remindersEnabled) { _, enabled in
            settings.save()
            Task { @MainActor in
              let granted = await LedgerNotificationScheduler.setDailyReminder(enabled: enabled)
              if !granted {
                settings.remindersEnabled = false
                message = "Notifications were not authorized."
              } else {
                message = enabled ? "Daily reminder scheduled for 9:00." : "Daily reminder disabled."
              }
            }
          }
        Text("Reminders are scheduled only after macOS authorization.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Support") {
        Button("Export content-free diagnostics", action: exportDiagnostics)
        Text("The file contains schema versions and counts only. It excludes financial values, names, notes, and paths.")
          .font(.caption).foregroundStyle(.secondary)
      }
      if let message { Text(message).foregroundStyle(.secondary) }
    }
    .formStyle(.grouped)
    .navigationTitle("Settings")
    .onChange(of: settings) { _, value in value.save() }
    .sheet(item: $passcodeForm) { mode in
      PasscodeForm(mode: mode) { current, passcode in
        do {
          switch mode {
          case .set:
            try lock.setPasscode(passcode)
            message = "Application lock enabled."
          case .change:
            try lock.changePasscode(current: current, to: passcode)
            message = "Passcode changed."
          case .remove:
            try lock.removePasscode(current: current)
            message = "Application lock removed."
          }
          return nil
        } catch LedgerAppLock.Error.invalidPasscode {
          return "Use an ASCII passcode between 4 and 128 characters."
        } catch LedgerAppLock.Error.incorrectPasscode {
          return lock.lockoutMessage ?? "The current passcode was not accepted."
        } catch LedgerAppLock.Error.authenticationRequired {
          return lock.lockoutMessage ?? "Unlock Ledger Atlas first."
        } catch {
          return "The passcode could not be saved."
        }
      }
    }
  }
}

struct PasscodeForm: View {
  enum Mode: String, Identifiable {
    case set, change, remove
    var id: String { rawValue }

    var title: String {
      switch self {
      case .set: "Set passcode"
      case .change: "Change passcode"
      case .remove: "Remove passcode"
      }
    }

    var needsCurrent: Bool { self != .set }
    var needsNew: Bool { self != .remove }
  }

  let mode: Mode
  /// Returns an error message, or nil when the change succeeded.
  let save: (_ current: String, _ passcode: String) -> String?
  @Environment(\.dismiss) private var dismiss
  @State private var current = ""
  @State private var passcode = ""
  @State private var confirmation = ""
  @State private var error: String?

  var body: some View {
    Form {
      Text(mode.title).font(.headline)
      if mode.needsCurrent {
        SecureField("Current passcode", text: $current).textContentType(.password)
      }
      if mode.needsNew {
        SecureField("New passcode", text: $passcode).textContentType(.newPassword)
        SecureField("Confirm new passcode", text: $confirmation).textContentType(.newPassword)
      }
      if let error { Text(error).foregroundStyle(.red).accessibilityLabel(error) }
      HStack {
        Button("Cancel", role: .cancel) { dismiss() }
        Spacer()
        Button(mode == .remove ? "Remove" : "Save", role: mode == .remove ? .destructive : nil) {
          guard !mode.needsNew || passcode == confirmation else {
            error = "Passcodes do not match."
            return
          }
          if let message = save(current, passcode) {
            error = message
          } else {
            dismiss()
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canSubmit)
      }
    }
    .padding(20)
    .frame(width: 380)
    .accessibilityElement(children: .contain)
  }

  private var canSubmit: Bool {
    (!mode.needsCurrent || !current.isEmpty)
      && (!mode.needsNew || (!passcode.isEmpty && !confirmation.isEmpty))
  }
}
