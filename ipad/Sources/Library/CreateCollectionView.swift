import SwiftUI

struct CreateCollectionView: View {
  let collections: CollectionModel
  let onCreated: (BookCollection) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var draft = CollectionSettingsDraft()
  @State private var isSaving = false
  @State private var error: String?

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        Form {
          CollectionSettingsFields(draft: $draft)
          if let error {
            Text(error).font(.body).foregroundStyle(.primary)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("collectionMutationError")
          }
          if isSaving { ProgressView("Creating collection…") }
        }.disabled(isSaving)
        HStack {
          Button("Cancel", action: dismiss.callAsFunction)
            .frame(minWidth: 44, minHeight: 44)
          Spacer()
          Button("Create") { Task { await create() } }
            .frame(minWidth: 44, minHeight: 44)
            .disabled(!draft.isValid || collections.isMutating)
            .accessibilityIdentifier("saveCollection")
        }.font(.body).padding().disabled(isSaving)
      }
      .navigationTitle("New collection")
      .interactiveDismissDisabled(isSaving)
    }
  }

  private func create() async {
    guard !isSaving, draft.isValid else { return }
    isSaving = true
    error = nil
    defer { isSaving = false }
    do {
      let result = try await collections.create(
        name: draft.name, icon: draft.icon, isPublic: draft.isPublic)
      onCreated(result)
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}
