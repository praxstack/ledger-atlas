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
  let isEditing: Bool
  let lastFailure: String?
  let beginEditing: () -> Void
  let saveCategory: (LedgerCategory) -> Void
  let createCategory: (LedgerCategory) -> Void
  let open: () -> Void
  @State private var showingCategoryForm = false
  @State private var editingCategory: LedgerCategory?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if !categories.isEmpty {
        List {
          ForEach(categories.filter { $0.parentID == nil }.sorted(by: Self.categoryOrder), id: \.id) { category in
            CategoryTreeRow(
              category: category, allCategories: categories, isEditing: isEditing, save: saveCategory,
              edit: { editingCategory = $0 })
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
          Button("New category") { showingCategoryForm = true }.accessibilityLabel("New category")
        } else if !categories.isEmpty || !rows.isEmpty {
          Button("Begin editing", action: beginEditing).accessibilityLabel("Begin editing categories")
        } else {
          Button("Open Ledger…", action: open)
        }
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 12)
    }
    .navigationTitle("Categories")
    .sheet(isPresented: $showingCategoryForm) {
      CategoryForm(categories: categories, onSave: { category in
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

  private static func categoryOrder(_ lhs: LedgerCategory, _ rhs: LedgerCategory) -> Bool {
    lhs.displayOrder == rhs.displayOrder ? lhs.name < rhs.name : lhs.displayOrder < rhs.displayOrder
  }
}

struct CategoryTreeRow: View {
  let category: LedgerCategory
  let allCategories: [LedgerCategory]
  let isEditing: Bool
  let save: (LedgerCategory) -> Void
  let edit: (LedgerCategory) -> Void
  @State private var expanded = true

  private var children: [LedgerCategory] {
    allCategories.filter { $0.parentID == category.id }.sorted {
      $0.displayOrder == $1.displayOrder ? $0.name < $1.name : $0.displayOrder < $1.displayOrder
    }
  }

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      ForEach(children, id: \.id) { child in
        CategoryTreeRow(
          category: child, allCategories: allCategories, isEditing: isEditing, save: save, edit: edit)
      }
    } label: {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(CategoryPresentation.label(category, in: allCategories))
          Text("\(category.kind.rawValue) · \(category.lifecycle.rawValue)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if category.hidden { Label("Hidden", systemImage: "eye.slash").font(.caption) }
        Menu("Actions") {
          Button("Edit category") { edit(category) }
          Button(category.hidden ? "Show category" : "Hide category") { update(hidden: !category.hidden) }
          Button(category.lifecycle == .active ? "Close category" : "Restore category") {
            update(lifecycle: category.lifecycle == .active ? .tombstoned : .active)
          }
        }
        .disabled(!isEditing)
        .accessibilityLabel("Actions for \(category.name)")
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("\(category.name), \(category.kind.rawValue), \(category.lifecycle.rawValue)")
    }
  }

  private func update(lifecycle: LedgerLifecycleState? = nil, hidden: Bool? = nil) {
    guard let revised = try? LedgerCategory(
      id: category.id, name: category.name, kind: category.kind, origin: category.origin,
      lifecycle: lifecycle ?? category.lifecycle, parentID: category.parentID,
      displayOrder: category.displayOrder, hidden: hidden ?? category.hidden)
    else { return }
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
  @State private var displayOrder: String
  @State private var hidden: Bool

  init(category: LedgerCategory, categories: [LedgerCategory], onSave: @escaping (LedgerCategory) -> Void) {
    self.category = category
    self.categories = categories
    self.onSave = onSave
    _name = State(initialValue: category.name)
    _parentID = State(initialValue: category.parentID)
    _displayOrder = State(initialValue: String(category.displayOrder))
    _hidden = State(initialValue: category.hidden)
  }

  var body: some View {
    Form {
      TextField("Category name", text: $name)
      Picker("Parent", selection: $parentID) {
        Text("Top level").tag(String?.none)
        ForEach(availableParents, id: \.id) {
          Text(CategoryPresentation.label($0, in: categories)).tag(Optional($0.id))
        }
      }
      TextField("Display order", text: $displayOrder)
      Toggle("Hidden", isOn: $hidden)
      HStack {
        Button("Cancel", role: .cancel) { dismiss() }
        Spacer()
        Button("Save") { save() }
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Int(displayOrder) == nil)
      }
    }
    .padding(20).frame(width: 420)
  }

  private var availableParents: [LedgerCategory] {
    let excluded = descendantIDs(of: category.id).union([category.id])
    return categories.filter {
      $0.lifecycle == .active && !$0.hidden && !excluded.contains($0.id)
    }.sorted { ($0.displayOrder, $0.name) < ($1.displayOrder, $1.name) }
  }

  private func descendantIDs(of id: String) -> Set<String> {
    var result: Set<String> = []
    var pending = [id]
    while let current = pending.popLast() {
      for child in categories where child.parentID == current && result.insert(child.id).inserted {
        pending.append(child.id)
      }
    }
    return result
  }

  private func save() {
    guard let order = Int(displayOrder), order >= 0,
      let revised = try? LedgerCategory(
        id: category.id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), kind: category.kind,
        origin: category.origin, lifecycle: category.lifecycle, parentID: parentID,
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
  @State private var kind: LedgerCategoryKind = .expense
  @State private var parentID: String?

  var body: some View {
    Form {
      TextField("Category name", text: $name)
      Picker("Kind", selection: $kind) {
        ForEach(LedgerCategoryKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
      }
      Picker("Parent", selection: $parentID) {
        Text("Top level").tag(String?.none)
        ForEach(categories.filter { $0.lifecycle == .active && !$0.hidden }.sorted { $0.name < $1.name }, id: \.id) { category in
          Text(CategoryPresentation.label(category, in: categories)).tag(Optional(category.id))
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
  }

  private func create() {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let origin = try? LedgerOrigin.macNative(),
      let id = try? StableLedgerID.category(origin: origin, localKey: Self.generatedID()),
      let category = try? LedgerCategory(id: id, name: trimmedName, kind: kind, origin: origin, parentID: parentID)
    else { return }
    onSave(category)
    dismiss()
  }

  private static func generatedID() -> String {
    SHA256.hash(data: Data("ledger-atlas/category/\(UUID().uuidString)".utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
