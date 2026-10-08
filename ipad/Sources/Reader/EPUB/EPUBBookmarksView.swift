import SwiftUI

struct EPUBBookmarksView: View {
  @State private var model: EPUBBookmarksModel
  @State private var removing: EpubBookmarkNavigationItem?
  let onJump: @MainActor (String) async -> EPUBPositionJumpResult
  @Environment(\.dismiss) private var dismiss

  init(
    reader: EPUBReaderModel, cfi: String, defaultTitle: String,
    onJump: @escaping @MainActor (String) async -> EPUBPositionJumpResult
  ) {
    _model = State(initialValue: EPUBBookmarksModel(reader: reader, cfi: cfi, title: defaultTitle))
    self.onJump = onJump
  }

  var body: some View {
    @Bindable var model = model
    NavigationStack {
      Form {
        Section("Bookmark this passage") {
          TextField("Bookmark title", text: $model.title, axis: .vertical)
            .disabled(model.isBusy || model.hasPendingSave || model.needsPositionSave)
            .accessibilityIdentifier("epubBookmarkTitle")
          Button(model.hasPendingSave ? "Retry Save" : "Save bookmark", action: save)
            .frame(minHeight: 44).disabled(!model.canSave)
            .accessibilityIdentifier("epubSaveBookmark")
          if model.title.unicodeScalars.count > 500 {
            Text("Use a title of 500 characters or fewer.")
          }
        }
        if let status = model.status {
          Text(status).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("epubBookmarkStatus")
        }
        if let error = model.error {
          Text(error).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("epubBookmarkError")
        }
        Section("Find saved passages") {
          TextField("Search title, chapter, or location", text: searchQuery, axis: .vertical)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .submitLabel(.search).onSubmit(load).frame(minHeight: 44)
            .disabled(!model.canBrowse).accessibilityIdentifier("epubBookmarkQuery")
          if !model.query.isEmpty {
            Button("Clear bookmark search", action: model.clearQuery).frame(minHeight: 44)
              .disabled(!model.canBrowse).accessibilityIdentifier("epubBookmarkClearQuery")
          }
          Picker("Sort bookmarks", selection: order) {
            ForEach(EPUBBookmarkOrder.allCases) { option in Text(option.label).tag(option) }
          }
          .disabled(!model.canBrowse).accessibilityIdentifier("epubBookmarkOrder")
        }
        if model.isLoading {
          ProgressView(
            model.normalizedQuery.isEmpty ? "Loading bookmarks…" : "Searching bookmarks…"
          )
          .accessibilityIdentifier("epubBookmarkLoading")
        }
        if model.scanLimited, !model.isLoading {
          Text("Search continues on the next page. More bookmarks remain to be searched.")
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("epubBookmarkSearchContinuation")
        }
        if let error = model.queryError {
          Section {
            Text(error).fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("epubBookmarkQueryError")
            Button("Retry bookmarks", action: retry).frame(minHeight: 44)
              .disabled(!model.canBrowse || model.isLoading)
              .accessibilityIdentifier("epubBookmarkRetryQuery")
          }
        }
        if let error = model.openingError {
          Section {
            Text(error).fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("epubBookmarkOpenError")
            if model.needsPositionSave {
              Text("The passage is open. Retry Save confirms it for reopening and other readers.")
                .fixedSize(horizontal: false, vertical: true)
            }
            Button(
              model.needsPositionSave ? "Retry Save" : "Retry opening bookmark",
              action: retryOpening
            )
            .frame(minHeight: 44).disabled(!model.canRetryOpening)
            .accessibilityIdentifier("epubBookmarkRetryOpen")
          }
        }
        if model.isOpening {
          ProgressView(
            model.needsPositionSave ? "Confirming reading position…" : "Opening bookmark…"
          )
          .accessibilityIdentifier("epubBookmarkOpening")
        }
        Section("Saved passages") {
          if model.hasLoaded, !model.isLoading, model.items.isEmpty {
            Text(emptyMessage)
              .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(
                "epubBookmarkEmpty")
          }
          ForEach(model.items) { bookmark in
            VStack(alignment: .leading, spacing: 8) {
              Button {
                open(bookmark)
              } label: {
                VStack(alignment: .leading, spacing: 4) {
                  Text(bookmark.title).font(.body.weight(.semibold))
                  Text(contextLine(bookmark)).font(.caption)
                  if let date = createdDate(bookmark.createdAt) {
                    Text(date, style: .date).font(.caption)
                  }
                  if bookmark.id == model.currentBookmarkID {
                    Label("Current bookmark", systemImage: "bookmark.fill").font(.caption)
                      .accessibilityIdentifier("epubCurrentBookmark\(bookmark.id)")
                  }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
              }
              .disabled(!model.canSelect).accessibilityIdentifier("epubOpenBookmark\(bookmark.id)")
              .accessibilityAddTraits(bookmark.id == model.currentBookmarkID ? .isSelected : [])
              Button("Remove bookmark") { removing = bookmark }
                .frame(minHeight: 44).disabled(!model.canSelect)
                .accessibilityIdentifier("epubRemoveBookmark\(bookmark.id)")
            }
          }
          Text("Page \(model.pageNumber)").accessibilityIdentifier("epubBookmarkPageNumber")
          Button("Previous page of bookmarks", action: previous).frame(minHeight: 44)
            .disabled(!model.canSelect || !model.hasPrevious).accessibilityIdentifier(
              "epubBookmarkPreviousPage")
          Button("Next page of bookmarks", action: next).frame(minHeight: 44)
            .disabled(!model.canSelect || model.nextCursor == nil).accessibilityIdentifier(
              "epubBookmarkNextPage")
          Button("First page of bookmarks", action: first).frame(minHeight: 44)
            .disabled(!model.canBrowse || model.isLoading).accessibilityIdentifier(
              "epubBookmarkFirstPage")
        }
      }
      .buttonStyle(.plain).navigationTitle("Bookmarks")
      .toolbar {
        Button("Done", action: dismiss.callAsFunction).frame(minWidth: 44, minHeight: 44)
          .disabled(model.isSaving || model.isOpening).accessibilityIdentifier("epubBookmarksDone")
      }
    }
    .task { await model.load() }.onDisappear { model.close() }
    .onChange(of: model.reader.publicationID) { _, _ in
      model.close()
      dismiss()
    }
    .interactiveDismissDisabled(model.isSaving || model.isOpening)
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

  private var searchQuery: Binding<String> { Binding(get: { model.query }, set: model.setQuery) }
  private var order: Binding<EPUBBookmarkOrder> {
    Binding(get: { model.order }, set: model.setOrder)
  }
  private var confirmsRemoval: Binding<Bool> {
    Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
  }

  private var emptyMessage: String {
    if model.normalizedQuery.isEmpty { return "No saved passages on this page." }
    if model.scanLimited { return "No matches in this search page. More bookmarks remain." }
    return model.pageNumber > 1
      ? "No matching bookmarks on this page." : "No bookmarks match this search."
  }

  private func contextLine(_ bookmark: EpubBookmarkNavigationItem) -> String {
    var parts = [String]()
    if let title = bookmark.chapterTitle, !title.isEmpty { parts.append(title) }
    if let percentage = bookmark.contextPercentage { parts.append("\(percentage)%") }
    return parts.isEmpty ? bookmark.locationLabel : parts.joined(separator: " - ")
  }

  private func createdDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)
  }

  private func open(_ bookmark: EpubBookmarkNavigationItem) {
    Task { if await model.open(bookmark, jump: onJump) { dismiss() } }
  }
  private func retryOpening() { Task { if await model.retryOpening(jump: onJump) { dismiss() } } }
  private func save() { Task { await model.save() } }
  private func load() { Task { await model.load() } }
  private func retry() { Task { await model.retry() } }
  private func next() { Task { await model.nextPage() } }
  private func previous() { Task { await model.previousPage() } }
  private func first() { Task { await model.firstPage() } }
}
