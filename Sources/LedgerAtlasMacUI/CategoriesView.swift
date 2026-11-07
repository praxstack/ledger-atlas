import AppKit
import CryptoKit
import LedgerCore
import LedgerStore
import SwiftUI
import UniformTypeIdentifiers

struct CategoriesView: View {
  let state: LedgerSession.State
  let rows: [LedgerJourney.SurfaceRow]
  let categories: [LedgerCategory]
  var transactions: [LedgerTransactionSnapshot] = []
  let isEditing: Bool
  let lastFailure: String?
  let beginEditing: () -> Void
  let saveCategory: (LedgerCategory) -> Void
  let createCategory: (LedgerCategory) -> Void
  let open: () -> Void
  @State private var showingCategoryForm = false
  @State private var editingCategory: LedgerCategory?
  /// The category being drilled into; nil shows the top level.
  @State private var focusID: String?

  private var tree: CategoryTree { CategoryTree(categories) }

  var body: some View {
    let tree = self.tree
    let usage = CategoryUsage.counts(transactions, in: tree)
    let focus = focusID.flatMap { tree[$0] }
    VStack(alignment: .leading, spacing: 12) {
      if !categories.isEmpty {
        CategoryBreadcrumbs(path: focus.map { tree.path(to: $0.id) } ?? [], select: { focusID = $0 })
          .padding(.horizontal, 16)
        let visible = tree.children(of: focus?.id)
        if visible.isEmpty {
          ContentUnavailableView(
            "No subcategories", systemImage: "tag",
            description: Text(isEditing ? "Create one to split this category further." : "This category has no subcategories."))
        } else {
          List(visible, id: \.id) { category in
            CategoryTreeRow(
              category: category, tree: tree, usage: usage[category.id] ?? CategoryUsage(),
              isEditing: isEditing, save: saveCategory, edit: { editingCategory = $0 },
              drillIn: { focusID = $0 })
          }
        }
      } else if !rows.isEmpty {
        List(rows) { row in
          VStack(alignment: .leading, spacing: 4) {
            Text(row.title)
            Text(row.detail).font(.caption).foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel("\(row.title), \(row.detail)")
        }
      } else {
        switch state {
        case .loaded:
          ContentUnavailableView("No categories", systemImage: "tag", description: Text(isEditing ? "Create a category to classify transactions." : "Begin editing to manage categories."))
        case .unavailable:
          EmptyLedgerPrompt(title: "Ledger unavailable", description: "Choose a compatible ledger to view its categories.", guidance: .unavailable, failure: lastFailure, buttonTitle: "Open Ledger…", open: open)
        case .noLedger:
          EmptyLedgerPrompt(title: "Open a ledger", description: "Choose a Ledger Atlas ledger to view its categories.", guidance: .noLedger, failure: lastFailure, buttonTitle: "Open Ledger…", open: open)
        case .loading:
          ProgressView("Opening ledger…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      if let lastFailure {
        Text(lastFailure).foregroundStyle(.red).accessibilityLabel(lastFailure)
      }
      HStack {
        if isEditing {
          // Only an open, visible category can take new subcategories (the store rule).
          let canAddChild = focus.map { $0.lifecycle == .active && !$0.hidden } ?? true
          Button(focus == nil ? "New category" : "New subcategory") { showingCategoryForm = true }
            .disabled(!canAddChild)
            .help(canAddChild ? "" : "Restore or show this category before adding subcategories.")
            .accessibilityLabel(focus.map { "New subcategory of \($0.name)" } ?? "New category")
        } else if !categories.isEmpty || !rows.isEmpty {
          Button("Begin editing", action: beginEditing).accessibilityLabel("Begin editing categories")
        } else {
          Button("Open Ledger…", action: open)
        }
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 12)
    }
    .navigationTitle(focus?.name ?? "Categories")
    .onChange(of: categories) { _, updated in
      // A reload can remove the focused category; fall back to the top level.
      if let focusID, !updated.contains(where: { $0.id == focusID }) { self.focusID = nil }
    }
    .sheet(isPresented: $showingCategoryForm) {
      CategoryForm(categories: categories, initialParentID: focus?.id, onSave: { category in
        createCategory(category)
        showingCategoryForm = false
      })
    }
    .sheet(isPresented: Binding(
      get: { editingCategory != nil }, set: { if !$0 { editingCategory = nil } })) {
      if let editingCategory {
        CategoryEditForm(category: editingCategory, categories: categories) { revised in
          saveCategory(revised)
          self.editingCategory = nil
        }
      }
    }
  }
}

struct CategoryBreadcrumbs: View {
  let path: [LedgerCategory]
  let select: (String?) -> Void

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 4) {
        crumb("All categories", id: nil, isCurrent: path.isEmpty)
        ForEach(Array(path.enumerated()), id: \.element.id) { index, category in
          Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            .accessibilityHidden(true)
          crumb(category.name, id: category.id, isCurrent: index == path.count - 1)
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Category path")
  }

  @ViewBuilder private func crumb(_ title: String, id: String?, isCurrent: Bool) -> some View {
    if isCurrent {
      Text(title).fontWeight(.semibold).accessibilityAddTraits(.isHeader)
    } else {
      Button(title) { select(id) }.buttonStyle(.link).accessibilityLabel(title)
    }
  }
}

struct CategoryTreeRow: View {
  let category: LedgerCategory
  let tree: CategoryTree
  let usage: CategoryUsage
  let isEditing: Bool
  let save: (LedgerCategory) -> Void
  let edit: (LedgerCategory) -> Void
  let drillIn: (String) -> Void

  private var childCount: Int { tree.children(of: category.id).count }
  private var siblings: [LedgerCategory] { tree.children(of: tree.parent(of: category.id)?.id) }

  private var summary: String {
    var parts = [category.kind.rawValue.capitalized]
    if category.lifecycle == .tombstoned { parts.append("closed") }
    parts.append(usage.total == 1 ? "1 transaction" : "\(usage.total) transactions")
    if childCount > 0 {
      parts.append("\(usage.direct) here")
      parts.append(childCount == 1 ? "1 subcategory" : "\(childCount) subcategories")
    }
    return parts.joined(separator: " · ")
  }

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 3) {
        Text(category.name)
          .foregroundStyle(category.lifecycle == .active ? .primary : .secondary)
        Text(summary).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if category.hidden { Label("Hidden", systemImage: "eye.slash").font(.caption) }
      if isEditing { actions }
      if childCount > 0 {
        Button { drillIn(category.id) } label: { Image(systemName: "chevron.right") }
          .buttonStyle(.borderless)
          .accessibilityLabel("Open subcategories of \(category.name)")
      }
    }
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { if childCount > 0 { drillIn(category.id) } }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(category.name), \(summary)\(category.hidden ? ", hidden" : "")")
  }

  private var actions: some View {
    let index = siblings.firstIndex(where: { $0.id == category.id }) ?? 0
    let closeBlocker = tree.closeBlocker(for: category.id)
    let restoreBlocker = tree.restoreBlocker(for: category.id)
    return Menu("Actions") {
      Button("Edit category…") { edit(category) }
      Button("Move up") { move(by: -1) }.disabled(index == 0)
      Button("Move down") { move(by: 1) }.disabled(index >= siblings.count - 1)
      Divider()
      if category.hidden {
        Button("Show category") { update { try $0.with(hidden: false) } }
      } else {
        Button("Hide category") { update { try $0.with(hidden: true) } }
          .disabled(closeBlocker != nil)
          .help(closeBlocker ?? "Hide it from pickers without changing past transactions.")
      }
      if category.lifecycle == .active {
        Button("Close category") { update { try $0.with(lifecycle: .tombstoned) } }
          .disabled(closeBlocker != nil)
          .help(closeBlocker ?? "Past transactions keep this category.")
      } else {
        Button("Restore category") { update { try $0.with(lifecycle: .active) } }
          .disabled(restoreBlocker != nil)
          .help(restoreBlocker ?? "Make it available again.")
      }
    }
    .fixedSize()
    .accessibilityLabel("Actions for \(category.name)")
  }

  private func move(by offset: Int) {
    for revised in tree.reordered(category.id, by: offset) { save(revised) }
  }

  private func update(_ change: (LedgerCategory) throws -> LedgerCategory) {
    guard let revised = try? change(category) else { return }
    save(revised)
  }
}

struct CategoryEditForm: View {
  let category: LedgerCategory
  let categories: [LedgerCategory]
  let onSave: (LedgerCategory) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var parentID: String?
  @State private var hidden: Bool

  init(category: LedgerCategory, categories: [LedgerCategory], onSave: @escaping (LedgerCategory) -> Void) {
    self.category = category
    self.categories = categories
    self.onSave = onSave
    _name = State(initialValue: category.name)
    _parentID = State(initialValue: category.parentID)
    _hidden = State(initialValue: category.hidden)
  }

  private var tree: CategoryTree { CategoryTree(categories) }

  var body: some View {
    let tree = self.tree
    let parents = tree.validParents(for: category.kind, movingID: category.id)
    let hideBlocker = category.hidden ? nil : tree.closeBlocker(for: category.id)
    Form {
      TextField("Category name", text: $name)
      Picker("Parent", selection: $parentID) {
        Text("Top level").tag(String?.none)
        if let current = category.parentID, !parents.contains(where: { $0.id == current }) {
          // Keep the current parent selectable even if it is now hidden or closed.
          Text(tree.label(for: current) ?? "Current parent").tag(Optional(current))
        }
        ForEach(parents, id: \.id) {
          Text(tree.label(for: $0.id) ?? $0.name).tag(Optional($0.id))
        }
      }
      Toggle("Hidden", isOn: $hidden).disabled(hideBlocker != nil)
      if let hideBlocker, !hidden {
        Text(hideBlocker).font(.caption).foregroundStyle(.secondary)
      }
      Text("Past transactions keep this category when you rename or move it.")
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("Cancel", role: .cancel) { dismiss() }
        Spacer()
        Button("Save") { save() }
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20).frame(width: 420)
  }

  private func save() {
    let movedParent = parentID != category.parentID
    // A moved category goes to the end of its new siblings.
    let order = movedParent
      ? (tree.children(of: parentID).filter { $0.id != category.id }.map(\.displayOrder).max() ?? -1) + 1
      : category.displayOrder
    guard let revised = try? category.with(
      name: name.trimmingCharacters(in: .whitespacesAndNewlines), parentID: .some(parentID),
      displayOrder: order, hidden: hidden)
    else { return }
    onSave(revised)
    dismiss()
  }
}

struct CategoryForm: View {
  let categories: [LedgerCategory]
  let onSave: (LedgerCategory) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var kind: LedgerCategoryKind
  @State private var parentID: String?

  init(
    categories: [LedgerCategory], initialParentID: String? = nil,
    onSave: @escaping (LedgerCategory) -> Void
  ) {
    self.categories = categories
    self.onSave = onSave
    let parent = initialParentID.flatMap { id in
      categories.first { $0.id == id && $0.lifecycle == .active && !$0.hidden }
    }
    _kind = State(initialValue: parent?.kind ?? .expense)
    _parentID = State(initialValue: parent?.id)
  }

  private var tree: CategoryTree { CategoryTree(categories) }

  var body: some View {
    let tree = self.tree
    Form {
      TextField("Category name", text: $name)
      Picker("Kind", selection: $kind) {
        ForEach(LedgerCategoryKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
      }
      Picker("Parent", selection: $parentID) {
        Text("Top level").tag(String?.none)
        ForEach(tree.validParents(for: kind), id: \.id) { category in
          Text(tree.label(for: category.id) ?? category.name).tag(Optional(category.id))
        }
      }
      HStack {
        Button("Cancel", role: .cancel) { dismiss() }
        Spacer()
        Button("Create") { create() }
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 420)
    .onChange(of: kind) { _, newKind in
      // A subcategory must have its parent's kind.
      if let parentID, tree[parentID]?.kind != newKind { self.parentID = nil }
    }
  }

  private func create() {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let origin = try? LedgerOrigin.macNative(),
      let id = try? StableLedgerID.category(origin: origin, localKey: Self.generatedID()),
      let category = try? LedgerCategory(
        id: id, name: trimmedName, kind: kind, origin: origin, parentID: parentID,
        displayOrder: (tree.children(of: parentID).map(\.displayOrder).max() ?? -1) + 1)
    else { return }
    onSave(category)
    dismiss()
  }

  private static func generatedID() -> String {
    SHA256.hash(data: Data("ledger-atlas/category/\(UUID().uuidString)".utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
