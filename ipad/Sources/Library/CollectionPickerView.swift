import SwiftUI

struct CollectionPickerView: View {
  let bookID: Int
  let onChanged: (BookCollection, Bool) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var collections: CollectionModel
  @State private var changingCollectionID: Int?
  @State private var error: String?

  init(api: BookOrbitAPI, bookID: Int, onChanged: @escaping (BookCollection, Bool) -> Void) {
    self.bookID = bookID
    self.onChanged = onChanged
    _collections = State(
      initialValue: CollectionModel(api: api, ownedOnly: true, bookID: bookID))
  }

  private var isSaving: Bool { changingCollectionID != nil }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        HStack(spacing: 8) {
          OrganizationSearchField(
            text: $collections.search, prompt: "Find collection",
            submit: { Task { await collections.load() } }, clearButtonMode: .never,
            identifier: "collectionPickerSearch")
          if !collections.search.isEmpty {
            Button(action: clearSearch) {
              Label("Clear text", systemImage: "xmark.circle.fill")
                .labelStyle(.iconOnly).font(.body)
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("clearCollectionPickerSearch")
          }
        }.padding().disabled(isSaving)
        List {
          ForEach(collections.items) { collection in
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                CollectionIcon(value: collection.icon)
                Text(collection.name).font(.headline)
                  .fixedSize(horizontal: false, vertical: true)
              }
              Text(membershipLabel(collection))
                .font(.body).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("collectionMembershipState\(collection.id)")
              if collection.isOwner, let membership = collection.memberCount {
                Button(membership > 0 ? "Remove from collection" : "Add to collection") {
                  Task { await changeMembership(collection, included: membership == 0) }
                }
                .font(.body).frame(minHeight: 44)
                .disabled(isSaving || collections.isBusy || collections.error != nil)
                .accessibilityLabel(collection.name)
                .accessibilityValue(
                  membership > 0
                    ? "In collection. Remove this book." : "Not in collection. Add this book."
                )
                .accessibilityIdentifier("collectionChoice")
              }
              if changingCollectionID == collection.id { ProgressView("Updating collection…") }
            }.padding(.vertical, 4)
          }
          if let error = error ?? collections.error {
            Text(error).font(.body).fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("collectionMembershipError")
            Button("Try again") { Task { await reload() } }
              .font(.body).frame(minHeight: 44).disabled(isSaving)
          }
          if collections.total == 0 && !collections.isBusy && collections.error == nil {
            Text("No matching collections. Create a collection from the library sidebar.")
              .font(.body).fixedSize(horizontal: false, vertical: true)
          }
        }
        if collections.isBusy { ProgressView("Loading collections…").padding() }
        HStack {
          Button("Done", action: dismiss.callAsFunction).frame(minWidth: 44, minHeight: 44)
            .accessibilityIdentifier("collectionPickerDone")
          Spacer()
          if collections.canGoBack {
            Button("Previous") { Task { await collections.previousPage() } }
              .frame(minHeight: 44).accessibilityIdentifier("previousCollectionPage")
          }
          if collections.canGoNext {
            Button("Next") { Task { await collections.nextPage() } }
              .frame(minHeight: 44).accessibilityIdentifier("nextCollectionPage")
          }
        }.font(.body).padding().disabled(isSaving)
      }
      .foregroundStyle(.primary)
      .navigationTitle("Book collections")
      .interactiveDismissDisabled(isSaving)
    }
    .task { await collections.load() }
  }

  private func membershipLabel(_ collection: BookCollection) -> String {
    guard let membership = collection.memberCount else {
      return "Membership unavailable. Try again."
    }
    return membership > 0
      ? "This book is in this collection." : "This book is not in this collection."
  }

  private func clearSearch() {
    collections.search = ""
    Task { await reload() }
  }

  private func reload() async {
    error = nil
    await collections.load()
  }

  private func changeMembership(_ collection: BookCollection, included: Bool) async {
    guard !isSaving, collection.isOwner, collection.memberCount != nil else { return }
    changingCollectionID = collection.id
    error = nil
    defer { changingCollectionID = nil }
    do {
      let result =
        if included {
          try await collections.addBook(bookID, to: collection)
        } else {
          try await collections.removeBook(bookID, from: collection)
        }
      onChanged(result, included)
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}
