import SwiftUI

struct PDFReaderView: View {
  @State private var model: PDFReaderModel
  @State private var confirmsDiscard = false
  @State private var isNavigating = false
  @State private var isSearching = false
  @State private var isBrowsingContents = false
  @ScaledMetric(relativeTo: .body) private var actionWidth = 150.0
  @Environment(\.dismiss) private var dismiss

  init(api: BookOrbitAPI, file: BookDetailFile) {
    _model = State(initialValue: PDFReaderModel(api: api, file: file))
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if let document = model.document {
          PDFCurlView(
            document: document, pageIndex: model.pageIndex, selection: model.searchSelection,
            onTurn: model.didTurn
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
    .onDisappear {
      if !isNavigating && !isSearching && !isBrowsingContents { model.close() }
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
}
