import LedgerCore
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
  @State private var draft = LedgerProductSettings()
  @State private var invalid: (field: LedgerProductSettings.Field, message: String)?
  @FocusState private var focusedField: LedgerProductSettings.Field?

  /// Applies a valid draft; an invalid one keeps the last good settings and focuses the field.
  private func commit(_ candidate: LedgerProductSettings) {
    guard candidate != settings else { return }
    let before = settings
    if let field = settings.apply(candidate) {
      invalid = (field, candidate.validationErrors()[field] ?? "This value is not valid.")
      focusedField = field
      return
    }
    invalid = nil
    settings.save()
    if candidate.remindersEnabled != before.remindersEnabled || candidate.reminderHour != before.reminderHour {
      scheduleReminder(enabled: candidate.remindersEnabled, hour: candidate.reminderHour)
    }
  }

  private func scheduleReminder(enabled: Bool, hour: Int) {
    Task { @MainActor in
      let granted = await LedgerNotificationScheduler.setDailyReminder(enabled: enabled, hour: hour)
      if !granted {
        // Save "off" first so the draft change below is a no-op commit and keeps this message.
        settings.remindersEnabled = false
        settings.save()
        draft.remindersEnabled = false
        message = "Notifications were not authorized. You can allow them in System Settings > Notifications."
      } else {
        message = enabled ? String(format: "Daily reminder scheduled for %02d:00.", hour) : "Daily reminder off."
      }
    }
  }

  @ViewBuilder private func fieldError(_ field: LedgerProductSettings.Field) -> some View {
    if let invalid, invalid.field == field {
      Text(invalid.message).font(.caption).foregroundStyle(.red).accessibilityLabel(invalid.message)
    }
  }

  private var example: String {
    let formatter = LedgerDisplayFormatter(settings: draft)
    let today = LedgerPeriodRule.today(in: draft.timeZone)
    guard let amount = try? CurrencyAmount(unitCode: "USD", amount: ExactDecimal("1234.5")) else {
      return formatter.date(today)
    }
    return "\(formatter.amount(amount)) · \(formatter.date(today))"
  }

  private var currentPeriod: String {
    let formatter = LedgerDisplayFormatter(settings: draft)
    let period = draft.periodRule.monthPeriod(containing: LedgerPeriodRule.today(in: draft.timeZone))
    let last = LedgerPeriodRule.date(fromDays: LedgerPeriodRule.days(from: period.end) - 1)
    return "\(formatter.date(period.start)) – \(formatter.date(last))"
  }

  private struct LocaleChoice: Identifiable {
    let id: String
    let name: String
  }

  private static let locales: [LocaleChoice] = [
    .init(id: "en_US", name: "English (United States)"), .init(id: "en_GB", name: "English (United Kingdom)"),
    .init(id: "en_IN", name: "English (India)"), .init(id: "hi_IN", name: "Hindi (India)"),
    .init(id: "de_DE", name: "German"), .init(id: "fr_FR", name: "French"),
    .init(id: "es_ES", name: "Spanish"), .init(id: "ja_JP", name: "Japanese"),
  ]

  private static func weekdayName(_ weekday: Int) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar.weekdaySymbols[weekday - 1]
  }

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
        Picker("Motion", selection: $draft.motion) {
          Text("Follow macOS").tag(LedgerProductSettings.Motion.followSystem)
          Text("Always reduce").tag(LedgerProductSettings.Motion.reduced)
        }
        LabeledContent("macOS Reduce Motion", value: reducedMotion ? "On" : "Off")
        Text("Keyboard navigation and explicit VoiceOver labels are used throughout the app.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Presentation") {
        Picker("Appearance", selection: $draft.appearance) {
          Text("System").tag(LedgerProductSettings.Appearance.system)
          Text("Light").tag(LedgerProductSettings.Appearance.light)
          Text("Dark").tag(LedgerProductSettings.Appearance.dark)
        }
        Picker("Locale", selection: $draft.localeIdentifier) {
          ForEach(Self.locales) { Text($0.name).tag($0.id) }
        }
        .focused($focusedField, equals: .localeIdentifier)
        fieldError(.localeIdentifier)
        Picker("Time zone", selection: $draft.timeZoneIdentifier) {
          Text("Follow macOS (\(TimeZone.current.identifier))").tag(String?.none)
          ForEach(TimeZone.knownTimeZoneIdentifiers.sorted(), id: \.self) { Text($0).tag(String?.some($0)) }
        }
        .focused($focusedField, equals: .timeZoneIdentifier)
        fieldError(.timeZoneIdentifier)
        Picker("Amount colours", selection: $draft.amountColors) {
          Text("Income green, expense red").tag(LedgerProductSettings.AmountColors.incomeGreenExpenseRed)
          Text("Income blue, expense red").tag(LedgerProductSettings.AmountColors.incomeBlueExpenseRed)
          Text("No colour").tag(LedgerProductSettings.AmountColors.monochrome)
        }
        Picker("Start screen", selection: $draft.startScreen) {
          ForEach(LedgerProductSettings.startScreenChoices) { Text($0.title).tag($0) }
        }
        .focused($focusedField, equals: .startScreen)
        fieldError(.startScreen)
        LabeledContent("Example", value: example)
          .accessibilityLabel("Example: \(example)")
        Text(
          "Locale and time zone change how amounts and dates look. Stored amounts and dates never change, and displayed text is never read back as data."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Section("Report periods") {
        Picker("First weekday", selection: $draft.firstWeekday) {
          ForEach(1...7, id: \.self) { Text(Self.weekdayName($0)).tag($0) }
        }
        .focused($focusedField, equals: .firstWeekday)
        fieldError(.firstWeekday)
        Stepper(
          "Month starts on day \(draft.periodStartDay)", value: $draft.periodStartDay,
          in: LedgerProductSettings.periodStartDays
        )
        .accessibilityValue(String(draft.periodStartDay))
        .focused($focusedField, equals: .periodStartDay)
        fieldError(.periodStartDay)
        LabeledContent("Current month", value: currentPeriod)
        Toggle("Carry over unspent budget and balance", isOn: $draft.carryOverEnabled)
        Text("Months shorter than the start day begin on their last day, so every period has a boundary.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Notifications") {
        Toggle("Daily reminder", isOn: $draft.remindersEnabled)
        Picker("Reminder time", selection: $draft.reminderHour) {
          ForEach(LedgerProductSettings.reminderHours, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
        }
        .disabled(!draft.remindersEnabled)
        .focused($focusedField, equals: .reminderHour)
        fieldError(.reminderHour)
        Text("Reminders are scheduled only after macOS authorization. They never include amounts or names.")
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
    .onAppear { draft = settings }
    .onChange(of: settings) { _, value in if draft != value { draft = value } }
    .onChange(of: draft) { _, candidate in commit(candidate) }
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
