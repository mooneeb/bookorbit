import SwiftUI

struct PDFThumbnailsView: View {
  let model: PDFReaderModel
  let rotation: Int
  @State private var isAuthorized = false
  @State private var isUnavailable = false
  @State private var isSelecting = false
  @State private var selectionError: String?
  @State private var selectionTask: Task<Void, Never>?
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.dismiss) private var dismiss

  private var canSelect: Bool {
    !isSelecting && !model.isClosing && !model.position.conflict.isBlocked
      && !model.position.isResolving
  }

  var body: some View {
    NavigationStack {
      Group {
        if isUnavailable || model.document == nil || model.requiresPassword {
          ContentUnavailableView {
            Label("Thumbnails unavailable", systemImage: "doc")
          } description: {
            Text("Close this browser and reopen the PDF with your current account.")
              .foregroundStyle(.primary)
          }
        } else if isAuthorized, let document = model.document, !document.isLocked {
          PDFThumbnailGrid(
            document: document, currentPage: model.pageIndex, rotation: rotation,
            canSelect: canSelect,
            authorize: { await model.authorizeThumbnails(in: document) },
            unavailable: markUnavailable, onSelect: selectPage)
        } else {
          ProgressView("Opening thumbnails…")
        }
      }
      .navigationTitle("PDF thumbnails")
      .navigationBarTitleDisplayMode(.inline)
      .safeAreaInset(edge: .bottom) {
        VStack(spacing: 8) {
          if isAuthorized, let document = model.document {
            Text("Current page \(model.pageIndex + 1) of \(document.pageCount)")
              .accessibilityIdentifier("pdfThumbnailCurrentPage")
          }
          if model.position.conflict.isBlocked || model.position.isResolving {
            Text("Resolve the resume position in the reader before selecting a page.")
          }
          if let selectionError { Text(selectionError) }
          Button("Cancel", action: cancel)
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, minHeight: 44)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("pdfThumbnailsCancel")
        }
        .font(.body)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal)
        .background(.background)
      }
    }
    .task(id: scenePhase) {
      guard scenePhase == .active else { return }
      guard let document = model.document else {
        markUnavailable()
        return
      }
      let authorized = await model.authorizeThumbnails(in: document)
      guard !Task.isCancelled else { return }
      isAuthorized = authorized
      isUnavailable = !authorized
    }
    .onChange(of: scenePhase) { _, phase in
      if phase != .active { isAuthorized = false }
    }
    .onDisappear {
      selectionTask?.cancel()
      selectionTask = nil
      isAuthorized = false
    }
  }

  private func markUnavailable() {
    isAuthorized = false
    isUnavailable = true
  }

  private func cancel() {
    selectionTask?.cancel()
    dismiss()
  }

  private func selectPage(_ page: Int) {
    guard canSelect else { return }
    isSelecting = true
    selectionError = nil
    selectionTask = Task {
      let selected = await model.openThumbnailPage(page)
      guard !Task.isCancelled else { return }
      isSelecting = false
      if selected {
        dismiss()
      } else {
        selectionError = "This page could not be opened. Close thumbnails and review the reader."
      }
    }
  }
}
