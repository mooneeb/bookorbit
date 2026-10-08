import SwiftUI

struct CollectionEditorView: View {
  let collections: CollectionModel
  let collection: BookCollection
  let onSaved: (BookCollection) -> Void
  let onDeleted: (Int) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var draft: CollectionSettingsDraft
  @State private var isSaving = false
  @State private var isDeleting = false
  @State private var confirmingDelete = false
  @State private var error: String?

  init(
    collections: CollectionModel, collection: BookCollection,
    onSaved: @escaping (BookCollection) -> Void, onDeleted: @escaping (Int) -> Void
  ) {
    self.collections = collections
    self.collection = collection
    self.onSaved = onSaved
    self.onDeleted = onDeleted
    _draft = State(initialValue: CollectionSettingsDraft(collection: collection))
  }

  private var isBusy: Bool { isSaving || isDeleting }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        Form {
          if collection.isOwner {
            CollectionSettingsFields(draft: $draft)
            Section {
              Button("Delete collection", role: .destructive) { confirmingDelete = true }
                .frame(minHeight: 44)
                .accessibilityIdentifier("deleteCollection")
              Text("Deleting this collection keeps its books in your library.")
                .font(.body).fixedSize(horizontal: false, vertical: true)
            }
          } else {
            Text("Only the owner can change this collection.")
          }
          if let error {
            Text(error).font(.body).foregroundStyle(.primary)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("collectionMutationError")
          }
          if isBusy { ProgressView(isDeleting ? "Deleting collection…" : "Saving collection…") }
        }.disabled(isBusy || collections.isMutating)
        HStack {
          Button("Cancel", action: dismiss.callAsFunction)
            .frame(minWidth: 44, minHeight: 44)
          Spacer()
          if collection.isOwner {
            Button("Save collection") { Task { await save() } }
              .frame(minWidth: 44, minHeight: 44)
              .disabled(!draft.isValid || collections.isMutating)
              .accessibilityIdentifier("saveCollectionChanges")
          }
        }.font(.body).padding().disabled(isBusy)
      }
      .navigationTitle("Edit collection")
      .interactiveDismissDisabled(isBusy)
      .alert("Delete collection?", isPresented: $confirmingDelete) {
        Button("Cancel", role: .cancel) {}
        Button("Delete", role: .destructive) { Task { await remove() } }
          .accessibilityIdentifier("confirmDeleteCollection")
      } message: {
        Text("Delete \(collection.name)? Its books will remain in your library.")
      }
    }
  }

  private func save() async {
    guard !isBusy, draft.isValid, collection.isOwner else { return }
    isSaving = true
    error = nil
    defer { isSaving = false }
    do {
      let result = try await collections.update(
        collection, name: draft.name, icon: draft.icon, isPublic: draft.isPublic)
      onSaved(result)
      dismiss()
    } catch { self.error = error.localizedDescription }
  }

  private func remove() async {
    guard !isBusy, collection.isOwner else { return }
    isDeleting = true
    error = nil
    defer { isDeleting = false }
    do {
      try await collections.remove(collection)
      onDeleted(collection.id)
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}
