import SwiftUI

struct CollectionPickerView: View {
  let bookID: Int
  let onAdded: (BookCollection) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var collections: CollectionModel
  @State private var isSaving = false
  @State private var error: String?

  init(api: BookOrbitAPI, bookID: Int, onAdded: @escaping (BookCollection) -> Void) {
    self.bookID = bookID
    self.onAdded = onAdded
    _collections = State(initialValue: CollectionModel(api: api, ownedOnly: true))
  }

  var body: some View {
    NavigationStack {
      List {
        ForEach(collections.items) { collection in
          Button(collection.name) { Task { await add(to: collection) } }
            .disabled(isSaving)
            .accessibilityIdentifier("collectionChoice")
        }
        if collections.canGoBack {
          Button("Previous collections") { Task { await collections.previousPage() } }
            .disabled(isSaving)
        }
        if collections.canGoNext {
          Button("Next collections") { Task { await collections.nextPage() } }
            .disabled(isSaving)
        }
        if collections.isBusy || isSaving { ProgressView("Loading…") }
        if let error = error ?? collections.error {
          Text(error)
          Button("Try again") { Task { await collections.load() } }.disabled(isSaving)
        }
        if collections.total == 0 && !collections.isBusy && collections.error == nil {
          Text("No matching collections. Create a collection from the library sidebar.")
        }
      }
      .navigationTitle("Add to collection")
      .searchable(text: $collections.search, prompt: "Find collection")
      .onSubmit(of: .search) { Task { await collections.load() } }
      .toolbar { Button("Cancel", action: dismiss.callAsFunction).disabled(isSaving) }
      .interactiveDismissDisabled(isSaving)
    }
    .task { await collections.load() }
  }

  private func add(to collection: BookCollection) async {
    guard !isSaving else { return }
    isSaving = true
    error = nil
    defer { isSaving = false }
    do {
      let result = try await collections.addBook(bookID, to: collection.id)
      onAdded(result)
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}
