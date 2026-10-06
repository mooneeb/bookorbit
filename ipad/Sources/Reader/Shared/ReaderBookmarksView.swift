import SwiftUI

struct ReaderBookmarksView: View {
  @State private var model: ReaderBookmarksModel
  @State private var removing: BookmarkResponse?
  let onSelect: (Int) -> Void
  @Environment(\.dismiss) private var dismiss

  init(
    api: BookOrbitAPI, bookID: Int, fileID: Int, currentPage: Int, pageCount: Int,
    onSelect: @escaping (Int) -> Void
  ) {
    _model = State(
      initialValue: ReaderBookmarksModel(
        api: api, bookID: bookID, fileID: fileID, currentPage: currentPage, pageCount: pageCount))
    self.onSelect = onSelect
  }

  var body: some View {
    @Bindable var model = model
    NavigationStack {
      Form {
        Section("Bookmark page \(model.currentPage)") {
          TextField("Bookmark title", text: $model.title, axis: .vertical)
            .accessibilityIdentifier("bookmarkTitle")
            .disabled(model.isBusy)
          Button {
            Task { await model.save() }
          } label: {
            actionLabel("Save bookmark")
          }
          .accessibilityIdentifier("saveBookmark")
          .disabled(!model.canSave)
          if model.title.utf16.count > 500 { Text("Use a title of 500 characters or fewer.") }
        }
        if !model.status.isEmpty { Text(model.status).accessibilityIdentifier("bookmarkStatus") }
        if let error = model.error {
          Section {
            Text(error)
            Button {
              Task { await model.load() }
            } label: {
              actionLabel("Retry loading bookmarks")
            }
            .disabled(model.isBusy)
          }
        }
        if model.isLoading { ProgressView("Loading bookmarks…") }
        Section("Saved bookmarks") {
          if model.hasLoaded, model.items.isEmpty { Text("No bookmarks for this file.") }
          ForEach(model.items) { bookmark in
            VStack(alignment: .leading) {
              Button {
                if let page = bookmark.pageNumber, (1...max(1, model.pageCount)).contains(page) {
                  onSelect(page - 1)
                  dismiss()
                }
              } label: {
                VStack(alignment: .leading) {
                  Text(bookmark.title).fixedSize(horizontal: false, vertical: true)
                  Text("Page \(bookmark.pageNumber ?? 0)")
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
              }
              .accessibilityIdentifier("openBookmark\(bookmark.id)")
              .disabled(
                model.isBusy || !(1...max(1, model.pageCount)).contains(bookmark.pageNumber ?? 0))
              Button {
                removing = bookmark
              } label: {
                actionLabel("Remove bookmark")
              }
              .accessibilityIdentifier("removeBookmark\(bookmark.id)")
              .disabled(model.isBusy)
            }
          }
          Button {
            Task { await model.previousPage() }
          } label: {
            actionLabel("Newer bookmarks")
          }
          .disabled(model.isBusy || !model.hasPrevious)
          Button {
            Task { await model.nextPage() }
          } label: {
            actionLabel("Older bookmarks")
          }
          .disabled(model.isBusy || model.nextCursor == nil)
          Button {
            Task { await model.firstPage() }
          } label: {
            actionLabel("First page of bookmarks")
          }
          .disabled(model.isBusy)
        }
      }
      .font(.body)
      .foregroundStyle(.primary)
      .buttonStyle(.plain)
      .navigationTitle("Bookmarks")
      .safeAreaInset(edge: .bottom) {
        Button(action: dismiss.callAsFunction) {
          Text("Done").font(.body).foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding().background(.background).disabled(model.isBusy)
      }
    }
    .task { await model.load() }
    .onDisappear { model.close() }
    .interactiveDismissDisabled(model.isBusy)
    .alert("Remove bookmark?", isPresented: confirmsRemoval, presenting: removing) { bookmark in
      Button("Keep bookmark", role: .cancel) { removing = nil }
      Button("Remove", role: .destructive) {
        Task { await model.remove(bookmark) }
        removing = nil
      }
    } message: { _ in
      Text("This removes the saved page from your bookmarks on connected readers.")
    }
  }

  private var confirmsRemoval: Binding<Bool> {
    Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
  }

  private func actionLabel(_ title: String) -> some View {
    Text(title).font(.body).foregroundStyle(.primary)
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      .contentShape(Rectangle())
  }
}
