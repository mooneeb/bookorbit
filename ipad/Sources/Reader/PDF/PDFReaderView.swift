import SwiftUI

struct PDFReaderView: View {
  @State private var model: PDFReaderModel
  @State private var confirmsDiscard = false
  @State private var isNavigating = false
  @Environment(\.dismiss) private var dismiss

  init(api: BookOrbitAPI, file: BookDetailFile) {
    _model = State(initialValue: PDFReaderModel(api: api, file: file))
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if let document = model.document {
          PDFCurlView(document: document, pageIndex: model.pageIndex, onTurn: model.didTurn)
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
          HStack {
            Button("Go to page") { isNavigating = true }
              .frame(minHeight: 44)
              .accessibilityIdentifier("pdfNavigate")
              .disabled(model.document == nil || model.isClosing)
            Spacer()
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
      if !isNavigating { model.close() }
    }
    .fullScreenCover(isPresented: $isNavigating) {
      if let document = model.document {
        PDFPageNavigationView(
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
