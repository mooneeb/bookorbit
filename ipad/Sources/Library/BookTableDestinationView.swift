import SwiftUI

struct BookTableDestinationView: View {
  let destination: BookTableDestination
  @Environment(\.dismiss) private var dismiss
  @State private var model: BookDetailModel
  @State private var didBeginEditing = false

  init(api: BookOrbitAPI, destination: BookTableDestination) {
    self.destination = destination
    _model = State(initialValue: BookDetailModel(api: api, bookID: destination.bookID))
  }

  var body: some View {
    Group {
      if let book = model.book {
        switch destination.kind {
        case .metadata:
          if let draft = model.draft { MetadataEditorView(model: model, draft: draft) }
        case .coverEditor: CoverEditorView(api: model.api, book: book)
        case .reader(let fileID):
          if let file = book.files.first(where: {
            $0.id == fileID && BookTableColumnSchema.isReadable($0.format)
          }) {
            NativeReaderHost(
              api: model.api, bookID: book.id, file: file, files: book.files,
              title: book.title ?? "Book", language: book.language)
          } else {
            ContentUnavailableView(
              "File unavailable", systemImage: "doc.badge.ellipsis",
              description: Text("This format is no longer available. Close and reload the table.")
            )
            .overlay(alignment: .topTrailing) {
              Button("Close", action: dismiss.callAsFunction).padding()
            }
          }
        }
      } else {
        NavigationStack {
          Group {
            if let error = model.error {
              ContentUnavailableView {
                Label("Could not open book", systemImage: "wifi.exclamationmark")
              } description: {
                Text(error)
              } actions: {
                Button("Try again") { Task { await load() } }
              }
            } else {
              ProgressView("Loading book…")
            }
          }.toolbar { Button("Close", action: dismiss.callAsFunction) }
        }
      }
    }
    .task { await load() }
    .onChange(of: model.draft == nil) { _, empty in
      if empty && didBeginEditing { dismiss() }
    }
  }

  private func load() async {
    await model.load()
    if case .metadata = destination.kind, model.book != nil {
      model.beginEditing()
      didBeginEditing = true
    }
  }
}
