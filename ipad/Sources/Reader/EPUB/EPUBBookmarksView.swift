import SwiftUI

struct EPUBBookmarksView: View {
  @State private var model: EPUBBookmarksModel
  @State private var removing: BookmarkResponse?
  let onSelect: (String) -> Void
  @Environment(\.dismiss) private var dismiss

  init(
    api: BookOrbitAPI, bookID: Int, cfi: String, defaultTitle: String,
    onSelect: @escaping (String) -> Void
  ) {
    _model = State(
      initialValue: EPUBBookmarksModel(api: api, bookID: bookID, cfi: cfi, title: defaultTitle))
    self.onSelect = onSelect
  }
  var body: some View {
    @Bindable var model = model
    NavigationStack {
      Form {
        Section("Bookmark this passage") {
          TextField("Bookmark title", text: $model.title, axis: .vertical)
            .disabled(model.isBusy || model.hasPendingSave).accessibilityIdentifier(
              "epubBookmarkTitle")
          Button(model.hasPendingSave ? "Retry Save" : "Save bookmark", action: save).frame(
            minHeight: 44
          )
          .disabled(!model.canSave).accessibilityIdentifier("epubSaveBookmark")
          if model.title.utf16.count > 500 { Text("Use a title of 500 characters or fewer.") }
        }
        if let status = model.status { Text(status).accessibilityIdentifier("epubBookmarkStatus") }
        if let error = model.error {
          Section {
            Text(error).accessibilityIdentifier("epubBookmarkError")
            Button("Reload bookmarks", action: load).frame(minHeight: 44).disabled(model.isBusy)
          }
        }
        if model.isLoading { ProgressView("Loading bookmarks…") }
        Section("Saved passages") {
          if model.hasLoaded, model.items.isEmpty { Text("No saved passages for this book.") }
          ForEach(model.items) { bookmark in
            VStack(alignment: .leading) {
              Button {
                if let cfi = bookmark.cfi {
                  onSelect(cfi)
                  dismiss()
                }
              } label: {
                Text(bookmark.title).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                  .fixedSize(horizontal: false, vertical: true)
              }.disabled(model.isBusy || model.hasPendingSave).accessibilityIdentifier(
                "epubOpenBookmark\(bookmark.id)")
              Button("Remove bookmark") { removing = bookmark }.frame(minHeight: 44)
                .disabled(model.isBusy || model.hasPendingSave).accessibilityIdentifier(
                  "epubRemoveBookmark\(bookmark.id)")
            }
          }
          Button("Newer bookmarks", action: previous).frame(minHeight: 44)
            .disabled(model.isBusy || model.hasPendingSave || !model.hasPrevious)
          Button("Older bookmarks", action: next).frame(minHeight: 44)
            .disabled(model.isBusy || model.hasPendingSave || model.nextCursor == nil)
          Button("First page of bookmarks", action: first).frame(minHeight: 44)
            .disabled(model.isBusy || model.hasPendingSave)
        }
      }
      .buttonStyle(.plain).navigationTitle("Bookmarks")
      .toolbar { Button("Done", action: dismiss.callAsFunction).disabled(model.isBusy) }
    }
    .task { await model.load() }.onDisappear { model.close() }
    .interactiveDismissDisabled(model.isBusy)
    .alert("Remove bookmark?", isPresented: confirmsRemoval, presenting: removing) { bookmark in
      Button("Keep bookmark", role: .cancel) { removing = nil }
      Button("Remove", role: .destructive) {
        Task { await model.remove(bookmark) }
        removing = nil
      }
    } message: { _ in
      Text("This removes the saved passage from connected readers.")
    }
  }
  private var confirmsRemoval: Binding<Bool> {
    Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
  }
  private func save() { Task { await model.save() } }
  private func load() { Task { await model.load() } }
  private func next() { Task { await model.nextPage() } }
  private func previous() { Task { await model.previousPage() } }
  private func first() { Task { await model.firstPage() } }
}
