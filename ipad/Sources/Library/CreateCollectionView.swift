import SwiftUI

struct CreateCollectionView: View {
  let collections: CollectionModel
  let onCreated: (BookCollection) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var isSaving = false
  @State private var error: String?

  var body: some View {
    NavigationStack {
      Form {
        TextField("Collection name", text: $name)
          .accessibilityIdentifier("collectionName")
          .disabled(isSaving)
        if let error { Text(error).foregroundStyle(.red) }
        if isSaving { ProgressView("Creating collection…") }
      }
      .navigationTitle("New collection")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: dismiss.callAsFunction).disabled(isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Create") { Task { await create() } }
            .disabled(
              name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 255
                || isSaving
            )
            .accessibilityIdentifier("saveCollection")
        }
      }
      .interactiveDismissDisabled(isSaving)
    }
  }

  private func create() async {
    guard !isSaving else { return }
    isSaving = true
    error = nil
    defer { isSaving = false }
    do {
      let result = try await collections.create(name: name)
      onCreated(result)
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}
