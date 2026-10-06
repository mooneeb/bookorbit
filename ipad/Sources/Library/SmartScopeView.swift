import SwiftUI

struct SmartScopeView: View {
  let api: BookOrbitAPI
  let user: AuthUser
  let select: (BookSmartScope) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var model: SmartScopeModel
  @State private var editing: ScopeEditSelection?
  @State private var deleting: BookSmartScope?
  @State private var actionError: String?
  @State private var isSaving = false

  init(api: BookOrbitAPI, user: AuthUser, select: @escaping (BookSmartScope) -> Void) {
    self.api = api
    self.user = user
    self.select = select
    _model = State(initialValue: SmartScopeModel(api: api))
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        Toggle("Only my scopes", isOn: $model.ownedOnly).padding()
          .onChange(of: model.ownedOnly) { Task { await model.load() } }
        if let error = model.error {
          VStack {
            Text(error).font(.body)
            Button("Try again") { Task { await model.load() } }.font(.body).frame(minHeight: 44)
          }.padding()
        } else {
          List(model.items) { scope in
            VStack(alignment: .leading, spacing: 10) {
              Button {
                select(scope)
                dismiss()
              } label: {
                VStack(alignment: .leading, spacing: 5) {
                  Text(scope.name).font(.headline)
                  Text(scope.isPublic ? "Shared scope" : "Private scope").font(.body)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
              }.buttonStyle(.plain).frame(minHeight: 44)
                .accessibilityIdentifier("scope\(scope.id)")
              HStack {
                if scope.isOwner || user.isSuperuser {
                  Button("Edit") { editing = ScopeEditSelection(scope: scope) }
                  Button("Delete", role: .destructive) { deleting = scope }
                }
                Button(scope.koboSyncEnabled ? "Stop Kobo sync" : "Sync to Kobo") {
                  Task { await updateKobo(scope) }
                }
              }.font(.body).frame(minHeight: 44).disabled(isSaving)
            }.padding(.vertical, 8).foregroundStyle(Color(uiColor: .label))
          }.disabled(isSaving).overlay {
            if model.total == 0 && !model.isBusy {
              Text(model.search.isEmpty ? "No smart scopes yet." : "No matching scopes.")
                .font(.body).foregroundStyle(Color(uiColor: .label))
            }
          }
        }
        if model.isBusy { ProgressView("Loading scopes…").padding() }
        HStack {
          Button("Done", action: dismiss.callAsFunction)
            .buttonStyle(.plain)
            .foregroundStyle(Color(uiColor: .label))
            .frame(minWidth: 44, minHeight: 44)
          Button("New scope") { editing = ScopeEditSelection(scope: nil) }
            .accessibilityIdentifier("newSmartScope")
          Spacer()
          if model.canGoBack { Button("Previous") { Task { await model.previousPage() } } }
          if model.canGoNext { Button("Next") { Task { await model.nextPage() } } }
        }.font(.body).frame(minHeight: 44).padding().disabled(isSaving)
      }.navigationTitle("Smart scopes")
        .searchable(text: $model.search, prompt: "Find a scope")
        .onSubmit(of: .search) { Task { await model.load() } }
        .task { await model.load() }
        .sheet(item: $editing) { selection in
          SmartScopeEditor(model: model, existing: selection.scope) { scope in
            select(scope)
            dismiss()
          }
        }
        .alert(
          "Delete scope?",
          isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
          Button("Cancel", role: .cancel) { deleting = nil }
          Button("Delete", role: .destructive) { Task { await remove() } }
        } message: {
          Text("The books will remain in your library.")
        }
        .alert(
          "Could not update scope",
          isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
          Button("OK") { actionError = nil }
        } message: {
          Text(actionError ?? "")
        }
    }
  }

  private func remove() async {
    guard let deleting, !isSaving else { return }
    isSaving = true
    defer {
      isSaving = false
      self.deleting = nil
    }
    do { try await model.remove(deleting) } catch { actionError = error.localizedDescription }
  }

  private func updateKobo(_ scope: BookSmartScope) async {
    guard !isSaving else { return }
    isSaving = true
    defer { isSaving = false }
    do { try await model.setKoboSync(scope, enabled: !scope.koboSyncEnabled) } catch {
      actionError = error.localizedDescription
    }
  }
}

struct SmartScopePicker: View {
  let selected: (BookSmartScope) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var model: SmartScopeModel

  init(api: BookOrbitAPI, selected: @escaping (BookSmartScope) -> Void) {
    self.selected = selected
    _model = State(initialValue: SmartScopeModel(api: api))
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        List(model.items) { scope in
          Button(scope.name) {
            selected(scope)
            dismiss()
          }
          .font(.body).frame(minHeight: 44)
        }
        if let error = model.error {
          Text(error).font(.body).foregroundStyle(Color(uiColor: .label)).padding()
          Button("Try again") { Task { await model.load() } }.font(.body).frame(minHeight: 44)
        }
        if model.total == 0 && !model.isBusy && model.error == nil {
          Text("No matching scopes.").font(.body).foregroundStyle(Color(uiColor: .label)).padding()
        }
        if model.isBusy { ProgressView("Loading scopes…").padding() }
        HStack {
          Button("Cancel", action: dismiss.callAsFunction)
          Spacer()
          if model.canGoBack { Button("Previous") { Task { await model.previousPage() } } }
          if model.canGoNext { Button("Next") { Task { await model.nextPage() } } }
        }.font(.body).frame(minHeight: 44).padding()
      }.navigationTitle("Choose smart scope")
        .searchable(text: $model.search, prompt: "Find a scope")
        .onSubmit(of: .search) { Task { await model.load() } }
        .task { await model.load() }
    }
  }
}

private struct ScopeEditSelection: Identifiable {
  let id = UUID()
  let scope: BookSmartScope?
}

struct SmartScopeEditor: View {
  let model: SmartScopeModel
  let existing: BookSmartScope?
  let saved: (BookSmartScope) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var filter: FilterDraft
  @State private var isPublic: Bool
  @State private var isSaving = false
  @State private var error: String?

  init(model: SmartScopeModel, existing: BookSmartScope?, saved: @escaping (BookSmartScope) -> Void)
  {
    self.model = model
    self.existing = existing
    self.saved = saved
    _name = State(initialValue: existing?.name ?? "")
    _filter = State(initialValue: .group(existing?.filter))
    _isPublic = State(initialValue: existing?.isPublic ?? false)
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        Form {
          TextField("Scope name", text: $name).accessibilityIdentifier("smartScopeName")
          Toggle("Share with other users", isOn: $isPublic)
            .accessibilityIdentifier("shareSmartScope")
          Text("Shared scopes show each person only books they can access.").font(.body)
          FilterEditor(draft: $filter)
          if let error { Text(error).font(.body).foregroundStyle(Color(uiColor: .label)) }
          if isSaving { ProgressView("Saving scope…") }
        }.disabled(isSaving)
        HStack {
          Button("Cancel", action: dismiss.callAsFunction)
          Spacer()
          Button("Save scope") { Task { await save() } }
            .accessibilityIdentifier("saveSmartScope")
            .disabled(
              name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 255)
        }.font(.body).frame(minHeight: 44).padding().disabled(isSaving)
      }.navigationTitle(existing == nil ? "New scope" : "Edit scope")
        .interactiveDismissDisabled(isSaving)
    }
  }

  private func save() async {
    guard !isSaving else { return }
    isSaving = true
    error = nil
    defer { isSaving = false }
    do {
      let group = try filter.filter()
      guard let group else { throw FilterDraftError.invalidGroup }
      let scope = try await model.save(
        name: name, filter: group,
        sort: existing?.defaultSort ?? [SortSpec(field: "title", dir: "asc")], isPublic: isPublic,
        existing: existing)
      saved(scope)
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}
