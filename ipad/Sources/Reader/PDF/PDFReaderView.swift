import SwiftUI

struct PDFReaderView: View {
  let api: BookOrbitAPI
  let bookID: Int
  let fileID: Int
  @State private var model: PDFReaderModel
  @State private var preferences: ReaderPreferencesModel
  @State private var confirmsDiscard = false
  @State private var isNavigating = false
  @State private var isSearching = false
  @State private var isBrowsingContents = false
  @State private var isEditingPreferences = false
  @State private var isBrowsingBookmarks = false
  @State private var isTurning = false
  @State private var pageLayout = FixedPageLayout(pageCount: 0, facing: false, singlePrefix: 0)
  @ScaledMetric(relativeTo: .body) private var actionWidth = 150.0
  @Environment(\.dismiss) private var dismiss

  init(api: BookOrbitAPI, bookID: Int, file: BookDetailFile) {
    self.api = api
    self.bookID = bookID
    fileID = file.id
    _model = State(initialValue: PDFReaderModel(api: api, file: file))
    _preferences = State(
      initialValue: ReaderPreferencesModel(api: api, fileID: file.id, group: "pdf"))
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if let document = model.document {
          PDFCurlView(
            document: document, pageIndex: model.pageIndex, selection: model.searchSelection,
            onTurn: model.didTurn, settings: preferences.value.pdf,
            animation: preferences.value.pageAnimation, onLayout: { pageLayout = $0 },
            onTransition: { isTurning = $0 }
          )
          .allowsHitTesting(!model.isClosing)
        } else if model.error == nil {
          ProgressView("Opening PDF…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        if let error = model.error { Text(error).padding() }
        VStack {
          if let document = model.document {
            Text("Page \(model.pageIndex + 1) of \(document.pageCount)")
          }
          if !model.status.isEmpty { Text(model.status) }
          if model.hasUnsavedPosition {
            Button("Retry saving", action: model.retrySaving)
              .buttonStyle(.plain)
              .frame(minHeight: 44)
            Button("Close without saving") { confirmsDiscard = true }
              .buttonStyle(.plain)
              .frame(minHeight: 44)
          }
          LazyVGrid(columns: [GridItem(.adaptive(minimum: actionWidth))]) {
            Button("Previous page", action: previousPage)
              .frame(minHeight: 44)
              .keyboardShortcut(.leftArrow, modifiers: [])
              .accessibilityIdentifier("pdfPreviousPage")
              .disabled(
                model.document == nil
                  || pageLayout.adjacentPage(to: model.pageIndex, delta: -1) == nil
                  || model.isClosing || isTurning)
            Button("Next page", action: nextPage)
              .frame(minHeight: 44)
              .keyboardShortcut(.rightArrow, modifiers: [])
              .accessibilityIdentifier("pdfNextPage")
              .disabled(
                model.document == nil
                  || pageLayout.adjacentPage(to: model.pageIndex, delta: 1) == nil
                  || model.isClosing || isTurning)
            Button("Go to page") { isNavigating = true }
              .frame(minHeight: 44)
              .accessibilityIdentifier("pdfNavigate")
              .disabled(model.document == nil || model.isClosing)
            Button("Contents") { isBrowsingContents = true }
              .frame(minHeight: 44)
              .accessibilityIdentifier("pdfContents")
              .disabled(model.document == nil || model.isClosing)
            Button("Search") { isSearching = true }
              .frame(minHeight: 44)
              .accessibilityIdentifier("pdfSearch")
              .disabled(model.document == nil || model.isClosing)
            Button("Reader settings") { isEditingPreferences = true }
              .frame(minHeight: 44)
              .accessibilityIdentifier("readerSettings")
              .disabled(model.isClosing || preferences.isLoading)
            Button {
              isBrowsingBookmarks = true
            } label: {
              Text("Bookmarks").frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("readerBookmarks")
            .disabled(model.document == nil || model.isClosing || isTurning)
            Button("Close reader", action: closeReader)
              .frame(minHeight: 44)
              .disabled(model.isClosing)
          }
          .buttonStyle(.plain)
          .frame(minHeight: 44)
        }
        .font(.body)
        .foregroundStyle(.primary)
        .padding()
      }
      .navigationTitle("PDF reader")
      .navigationBarTitleDisplayMode(.inline)
    }
    .task { await model.load() }
    .task { await preferences.load() }
    .onDisappear {
      if !isNavigating && !isSearching && !isBrowsingContents && !isEditingPreferences
        && !isBrowsingBookmarks
      {
        model.close()
        preferences.close()
      }
    }
    .fullScreenCover(isPresented: $isBrowsingBookmarks) {
      if let document = model.document {
        ReaderBookmarksView(
          api: api, bookID: bookID, fileID: fileID, currentPage: model.pageIndex + 1,
          pageCount: document.pageCount, onSelect: model.didTurn)
      }
    }
    .fullScreenCover(isPresented: $isEditingPreferences) {
      ReaderPreferencesView(model: preferences)
    }
    .fullScreenCover(isPresented: $isBrowsingContents) {
      if let document = model.document {
        PDFContentsView(document: document, onSelect: model.openContentsPage)
      }
    }
    .fullScreenCover(isPresented: $isSearching) {
      if let document = model.document {
        PDFSearchView(document: document, onSelect: model.openSearchMatch)
      }
    }
    .fullScreenCover(isPresented: $isNavigating) {
      if let document = model.document {
        ReaderPageNavigationView(
          currentPage: model.pageIndex + 1, pageCount: document.pageCount, onNavigate: model.didTurn
        )
      }
    }
    .alert("Discard unsaved position?", isPresented: $confirmsDiscard) {
      Button("Keep reading", role: .cancel) {}
      Button("Discard and close", role: .destructive, action: dismiss.callAsFunction)
    } message: {
      Text(
        "Your latest page turn has not been saved. The next session will resume at the last saved position."
      )
    }
  }

  private func closeReader() {
    Task {
      if await model.prepareToClose() { dismiss() }
    }
  }
  private func previousPage() {
    if let page = pageLayout.adjacentPage(to: model.pageIndex, delta: -1) {
      model.didTurn(to: page)
    }
  }
  private func nextPage() {
    if let page = pageLayout.adjacentPage(to: model.pageIndex, delta: 1) { model.didTurn(to: page) }
  }
}
