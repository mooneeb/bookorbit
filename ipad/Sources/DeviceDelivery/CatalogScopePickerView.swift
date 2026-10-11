import SwiftUI

enum CatalogScopeKind: String, Identifiable {
  case collection, smartScope
  var id: String { rawValue }
}

struct CatalogScopePickerView: View {
  @Environment(\.dismiss) private var dismiss
  let kind: CatalogScopeKind
  let selected: @MainActor (Int, String) -> Void
  @State private var collections: CollectionModel
  @State private var scopes: SmartScopeModel

  init(
    api: BookOrbitAPI, kind: CatalogScopeKind, selected: @escaping @MainActor (Int, String) -> Void
  ) {
    self.kind = kind
    self.selected = selected
    _collections = State(initialValue: CollectionModel(api: api))
    _scopes = State(initialValue: SmartScopeModel(api: api))
  }

  var body: some View {
    NavigationStack {
      List {
        if let error = kind == .collection ? collections.error : scopes.error {
          Text(error).foregroundStyle(.red)
          Button("Retry", action: reload)
        }
        if kind == .collection {
          ForEach(collections.items) { collection in
            Button(collection.name) { select(id: collection.id, name: collection.name) }
              .accessibilityIdentifier("catalogCollection\(collection.id)")
          }
        } else {
          ForEach(scopes.items) { scope in
            Button(scope.name) { select(id: scope.id, name: scope.name) }
              .accessibilityIdentifier("catalogSmartScope\(scope.id)")
          }
        }
        HStack {
          Button("Previous", action: previous).disabled(!canPrevious)
          Spacer()
          Text("Page \(page + 1), \(total) results")
          Spacer()
          Button("Next", action: next).disabled(!canNext)
        }
      }
      .searchable(
        text: search, prompt: kind == .collection ? "Search collections" : "Search smart scopes"
      )
      .onSubmit(of: .search, reload)
      .navigationTitle(kind == .collection ? "Collections" : "Smart scopes")
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: close) } }
      .overlay { if collections.isBusy || scopes.isBusy { ProgressView() } }
      .task { await load() }
    }
  }

  private var search: Binding<String> {
    kind == .collection ? $collections.search : $scopes.search
  }
  private var canPrevious: Bool { kind == .collection ? collections.canGoBack : scopes.canGoBack }
  private var canNext: Bool { kind == .collection ? collections.canGoNext : scopes.canGoNext }
  private var page: Int { kind == .collection ? collections.page : scopes.page }
  private var total: Int { kind == .collection ? collections.total : scopes.total }
  private func close() { dismiss() }
  private func select(id: Int, name: String) {
    selected(id, name)
    dismiss()
  }
  private func reload() { Task { await load() } }
  private func load() async {
    if kind == .collection { await collections.load() } else { await scopes.load() }
  }
  private func previous() {
    Task {
      if kind == .collection {
        await collections.previousPage()
      } else {
        await scopes.previousPage()
      }
    }
  }
  private func next() {
    Task {
      if kind == .collection { await collections.nextPage() } else { await scopes.nextPage() }
    }
  }
}
