import LedgerCore
import LedgerStore
import SwiftUI

/// What a bulk change asks for (#168): a plan to confirm, or why it can't be made.
enum BulkEditPrompt: Identifiable {
  case confirm(LedgerBulkEditPlan)
  case refused(String)

  var id: String {
    switch self {
    case .confirm(let plan): "confirm-\(plan.change)-\(plan.changeCount)"
    case .refused(let message): "refused-\(message)"
    }
  }
}

/// Names a bulk change in words: "Set the category to Groceries", "Add the tag trip".
enum BulkEditWording {
  /// What the bar says while a bulk change or its revert is written (#246).
  static func working(_ work: LedgerJourney.BackgroundWork) -> String? {
    switch work {
    case .bulkEditing(let count):
      return count == 1 ? "Changing 1 entry…" : "Changing \(count) entries…"
    case .revertingBulkEdit(let count):
      return count == 1 ? "Reverting 1 entry…" : "Reverting \(count) entries…"
    case .preparingImport, .importing:
      return nil
    }
  }

  static func action(
    _ change: LedgerBulkChange, categories: [LedgerCategory], tags: [LedgerTag]
  ) -> String {
    switch change {
    case .category(nil): return "Remove the category"
    case .category(let id?):
      let name = categories.first { $0.id == id }.map { CategoryPresentation.label($0, in: categories) }
      return "Set the category to \(name ?? "the chosen category")"
    case .addTag(let id): return "Add the tag \(tagName(id, tags))"
    case .removeTag(let id): return "Remove the tag \(tagName(id, tags))"
    }
  }

  static func entries(_ count: Int) -> String { count == 1 ? "1 entry" : "\(count) entries" }

  /// "Category set to Groceries on 212 entries."
  static func done(
    _ receipt: LedgerBulkEditReceipt, categories: [LedgerCategory], tags: [LedgerTag]
  ) -> String {
    let count = entries(receipt.entries.count)
    switch receipt.change {
    case .category(nil):
      return "Category removed from \(count)."
    case .category(let id?):
      let name = categories.first { $0.id == id }.map { CategoryPresentation.label($0, in: categories) }
      return "Category set to \(name ?? "the chosen category") on \(count)."
    case .addTag(let id): return "Tag \(tagName(id, tags)) added to \(count)."
    case .removeTag(let id): return "Tag \(tagName(id, tags)) removed from \(count)."
    }
  }

  private static func tagName(_ id: String, _ tags: [LedgerTag]) -> String {
    tags.first { $0.id == id }?.name ?? "chosen"
  }
}

/// Confirms a bulk change: how many entries, what happens to them and how to take it back.
struct BulkEditConfirmSheet: View {
  let plan: LedgerBulkEditPlan
  let categories: [LedgerCategory]
  let tags: [LedgerTag]
  let confirm: () -> Void
  @Environment(\.dismiss) private var dismiss

  private var title: String {
    "\(BulkEditWording.action(plan.change, categories: categories, tags: tags)) on \(BulkEditWording.entries(plan.changeCount))?"
  }

  private var details: [String] {
    var lines: [String] = []
    if plan.linkedCount > 0 {
      lines.append(
        plan.linkedCount == 1
          ? "Includes 1 linked entry (an installment payment, a split line or a transfer's fee), so the whole item stays alike."
          : "Includes \(plan.linkedCount) linked entries (installment payments, split lines or a transfer's fee), so each whole item stays alike.")
    }
    if plan.unchangedCount > 0 {
      lines.append(
        plan.unchangedCount == 1
          ? "1 entry is already like that and stays as it is."
          : "\(plan.unchangedCount) entries are already like that and stay as they are.")
    }
    lines.append(
      "Amounts, dates, accounts and notes don't change. Each entry keeps its earlier version in its history, and Edit › Revert Bulk Change undoes all of it in one step.")
    return lines
  }

  var body: some View {
    VStack(alignment: .leading, spacing: LedgerTheme.Space.l) {
      Text(title)
        .font(LedgerTheme.Typeface.cardTitle)
        .foregroundStyle(LedgerTheme.ink)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
      VStack(alignment: .leading, spacing: LedgerTheme.Space.s) {
        ForEach(details, id: \.self) { line in
          Text(line)
            .font(LedgerTheme.Typeface.secondary)
            .foregroundStyle(LedgerTheme.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
          .buttonStyle(LedgerSecondaryButtonStyle())
        Button("Change \(BulkEditWording.entries(plan.changeCount))") {
          confirm()
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(LedgerPrimaryButtonStyle())
      }
    }
    .padding(LedgerTheme.Space.xl)
    .frame(width: 440)
  }
}

/// Why a bulk change was not made. Nothing was written.
struct BulkEditRefusedSheet: View {
  let message: String
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: LedgerTheme.Space.l) {
      Label("These entries were not changed", systemImage: "exclamationmark.triangle")
        .font(LedgerTheme.Typeface.cardTitle)
        .foregroundStyle(LedgerTheme.ink)
        .accessibilityAddTraits(.isHeader)
      Text(message)
        .font(LedgerTheme.Typeface.secondary)
        .foregroundStyle(LedgerTheme.inkSecondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("OK") { dismiss() }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(LedgerPrimaryButtonStyle())
      }
    }
    .padding(LedgerTheme.Space.xl)
    .frame(width: 420)
  }
}

/// The last bulk change, under the list, with the one-step way back.
/// Shown in place of the notice while a bulk change or its revert is written. Other edits
/// wait for it, and Quit asks first.
struct BulkEditProgress: View {
  let text: String

  var body: some View {
    HStack(spacing: LedgerTheme.Space.m) {
      ProgressView()
        .controlSize(.small)
        .accessibilityHidden(true)
      Text(text)
        .font(LedgerTheme.Typeface.caption)
        .foregroundStyle(LedgerTheme.ink)
      Spacer(minLength: LedgerTheme.Space.s)
    }
    .padding(.horizontal, LedgerTheme.Space.l)
    .padding(.vertical, LedgerTheme.Space.s)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(LedgerTheme.recessed)
    .overlay(alignment: .top) { Divider().overlay(LedgerTheme.hairline) }
    .accessibilityElement(children: .combine)
  }
}

struct BulkEditNotice: View {
  let text: String
  let revert: () -> Void
  let dismiss: () -> Void

  var body: some View {
    HStack(spacing: LedgerTheme.Space.m) {
      Image(systemName: "checkmark.circle")
        .foregroundStyle(LedgerTheme.inkSecondary)
        .accessibilityHidden(true)
      Text(text)
        .font(LedgerTheme.Typeface.caption)
        .foregroundStyle(LedgerTheme.ink)
        .lineLimit(2)
      Spacer(minLength: LedgerTheme.Space.s)
      Button("Revert This Bulk Change", action: revert)
        .buttonStyle(LedgerSecondaryButtonStyle())
        .help("Give every entry back the category and tags it had (Edit › Revert Bulk Change)")
      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Dismiss")
      .help("Dismiss. The change stays.")
    }
    .padding(.horizontal, LedgerTheme.Space.l)
    .padding(.vertical, LedgerTheme.Space.s)
    .background(LedgerTheme.recessed)
    .overlay(alignment: .top) { Divider().overlay(LedgerTheme.hairline) }
    .accessibilityElement(children: .contain)
  }
}

/// Edit › Revert Bulk Change, while a ledger view with a bulk change to revert is in front.
struct RevertBulkEditAction {
  let perform: @MainActor () -> Void
}

extension FocusedValues {
  @Entry var revertBulkEdit: RevertBulkEditAction?
}

public struct BulkEditCommands: Commands {
  @FocusedValue(\.revertBulkEdit) private var revert

  public init() {}

  public var body: some Commands {
    CommandGroup(after: .undoRedo) {
      Button("Revert Bulk Change") { revert?.perform() }
        .disabled(revert == nil)
    }
  }
}
