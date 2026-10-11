import SwiftUI

struct EntityManagementView: View {
  let user: AuthUser
  @Environment(\.dismiss) private var dismiss
  @State private var model: EntityDirectoryModel
  @State private var selected: BrowseEntityItem?
  @State private var showingBulkPreview = false
  @State private var showingBulkMergePreview = false
  @State private var bulkMergeTarget: BrowseEntityItem?
  @State private var showingDuplicates = false

  init(api: BookOrbitAPI, user: AuthUser) {
    self.user = user
    _model = State(initialValue: EntityDirectoryModel(api: api))
  }

  var body: some View {
    NavigationStack {
      Group {
        if user.hasPermission(.libraryEditMetadata) {
          directory
        } else {
          ContentUnavailableView(
            "Permission required", systemImage: "lock",
            description: Text("Entity management requires permission to edit library metadata."))
        }
      }
      .navigationTitle("Entity management")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", action: dismiss.callAsFunction)
        }
      }
      .sheet(item: $selected, onDismiss: { Task { await model.load(page: model.page) } }) { item in
        EntityEditorView(api: model.api, kind: model.kind, item: item)
      }
      .sheet(
        isPresented: $showingDuplicates, onDismiss: { Task { await model.load(page: model.page) } }
      ) {
        EntityDuplicatesView(api: model.api, kind: model.kind)
      }
      .task { if user.hasPermission(.libraryEditMetadata) { await model.load() } }
      .alert("Review entity deletion", isPresented: $showingBulkPreview) {
        Button("Delete selected entities", role: .destructive) { Task { await model.bulkDelete() } }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "Remove \(model.selection.count) entities and their book relationships. The selection currently represents \(model.selection.reduce(0) { $0 + $1.bookCount }) book relationships, which may include the same book more than once. Books, files, notes and reading progress are retained."
        )
      }
      .alert("Review entity merge", isPresented: $showingBulkMergePreview) {
        Button("Merge selected entities", role: .destructive) {
          if let target = bulkMergeTarget { Task { await model.bulkMerge(target: target) } }
        }
        Button("Cancel", role: .cancel) { bulkMergeTarget = nil }
      } message: {
        Text(
          "Merge \(max(0, model.selection.count - 1)) source entities into \(bulkMergeTarget?.name ?? ""). Source entities are removed. Books, files, notes and reading progress are retained. Existing target relationships are kept."
        )
      }
    }
  }

  private var directory: some View {
    VStack(spacing: 0) {
      Picker("Entity type", selection: $model.kind) {
        ForEach(EntityKind.allCases) { kind in Text(kind.title).tag(kind) }
      }
      .pickerStyle(.menu)
      .accessibilityIdentifier("entityKind")
      .padding(.horizontal)
      Button("Review duplicates") { showingDuplicates = true }
        .accessibilityIdentifier("entityReviewDuplicates")
      OrganizationSearchField(text: $model.search, prompt: "Search entities") {
        Task { await model.load() }
      }
      .padding(.horizontal)
      if let error = model.error {
        Text(error).foregroundStyle(.red).padding()
        Button("Retry") { Task { await model.load(page: model.page) } }
          .accessibilityIdentifier("entityRetry")
      }
      if let outcome = model.bulkOutcome {
        Text(outcome).padding().accessibilityIdentifier("entityBulkOutcome")
      }
      if !model.pendingFileOperations.isEmpty || model.fileUpdateMessage != nil {
        VStack(alignment: .leading, spacing: 8) {
          if !model.pendingFileOperations.isEmpty {
            Text("Entity merge file updates are pending. Database changes are saved.")
            Button("Retry file updates") { Task { await model.retryFileUpdates() } }
              .disabled(model.retryingFileUpdates)
              .accessibilityIdentifier("entityRetryFileUpdates")
          }
          if let message = model.fileUpdateMessage { Text(message).font(.footnote) }
        }
        .padding()
      }
      List(model.items) { item in
        HStack {
          Button {
            model.toggleSelection(item)
          } label: {
            Image(
              systemName: model.selection.contains { $0.id == item.id }
                ? "checkmark.circle.fill" : "circle"
            )
            .frame(minWidth: 44, minHeight: 44)
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("Select \(item.name)")
          .accessibilityIdentifier("entitySelect\(item.id.entityPath)")
          Button {
            selected = item
          } label: {
            VStack(alignment: .leading) {
              Text(item.name).font(.headline)
              Text("\(item.bookCount) books").font(.subheadline)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.borderless)
          .accessibilityIdentifier("entityRow\(item.id.entityPath)")
        }
      }
      .overlay {
        if model.items.isEmpty && !model.busy && model.error == nil {
          ContentUnavailableView.search(text: model.search)
        }
      }
      if model.busy { ProgressView("Loading entities").padding() }
      if !model.selection.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("\(model.selection.count) selected")
            Spacer()
            Button("Clear selection") { model.selection = [] }
          }
          Button("Preview deletion", role: .destructive) { showingBulkPreview = true }
            .accessibilityIdentifier("entityBulkPreview")
          if model.selection.count >= 2 {
            Menu("Choose merge target") {
              ForEach(model.selection) { item in
                Button(item.name) {
                  bulkMergeTarget = item
                  showingBulkMergePreview = true
                }
              }
            }
            .accessibilityIdentifier("entityBulkMergeTarget")
          }
        }.padding()
      }
      HStack {
        Button("Previous") { Task { await model.load(page: model.page - 1) } }
          .disabled(model.page <= 1 || model.busy)
        Spacer()
        Text("Page \(model.page), \(model.total) results").font(.footnote)
        Spacer()
        Button("Next") { Task { await model.load(page: model.page + 1) } }
          .disabled(model.page * 40 >= model.total || model.busy)
      }
      .padding()
    }
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Menu("Sort and filter") {
          Picker("Sort by", selection: $model.sort) {
            Text("Name").tag("name")
            Text("Book count").tag("bookCount")
          }
          Toggle("Descending", isOn: $model.descending)
          if !model.kind.isInline { Toggle("Unused entities only", isOn: $model.emptyOnly) }
        }
      }
    }
    .disabled(model.busy)
    .onChange(of: model.kind) {
      model.clearFileUpdateRecovery()
      model.search = ""
      model.selection = []
      model.bulkOutcome = nil
      Task { await model.load() }
    }
    .onChange(of: model.sort) { Task { await model.load() } }
    .onChange(of: model.descending) { Task { await model.load() } }
    .onChange(of: model.emptyOnly) { Task { await model.load() } }
  }
}
