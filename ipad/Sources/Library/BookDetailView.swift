import SwiftUI

struct BookDetailView: View {
  let canEditMetadata: Bool
  @Environment(\.dismiss) private var dismiss
  @State private var model: BookDetailModel
  @State private var isAddingToCollection = false
  @State private var collectionResult: String?
  @State private var isEditingCovers = false
  @State private var selectedFile: BookDetailFile?

  init(api: BookOrbitAPI, bookID: Int, canEditMetadata: Bool) {
    self.canEditMetadata = canEditMetadata
    _model = State(initialValue: BookDetailModel(api: api, bookID: bookID))
  }

  var body: some View {
    NavigationStack {
      Group {
        if let book = model.book {
          List {
            Section {
              Text(book.title ?? "Untitled book").font(.title)
              if let subtitle = book.subtitle { Text(subtitle).font(.headline) }
              if !book.authors.isEmpty {
                Text(book.authors.map(\.name).joined(separator: ", "))
              }
              Text(book.libraryName).foregroundStyle(.secondary)
              if let description = book.description { Text(description) }
              if canEditMetadata {
                Button("Edit metadata", action: model.beginEditing)
                  .accessibilityIdentifier("editMetadata")
                Button("Edit covers") { isEditingCovers = true }
                  .accessibilityIdentifier("editCovers")
              }
            }
            Section("Files") {
              ForEach(book.files) { file in
                VStack(alignment: .leading) {
                  Text(file.filename ?? "Book file")
                  Text(file.format?.uppercased() ?? "Unknown format").font(.caption)
                    .foregroundStyle(.secondary)
                  if file.format?.lowercased() == "pdf" {
                    Button("Read") { selectedFile = file }
                      .accessibilityIdentifier("readFile\(file.id)")
                  }
                }
              }
            }
            Section("Collections") {
              Button("Add to collection") { isAddingToCollection = true }
                .accessibilityIdentifier("addToCollection")
              if let collectionResult { Text(collectionResult) }
            }
            if !book.customMetadata.isEmpty {
              Section("Custom fields") {
                ForEach(book.customMetadata, id: \.fieldId) { field in
                  VStack(alignment: .leading, spacing: 4) {
                    Text(field.label).font(.headline)
                    Text(field.value.displayText)
                      .fixedSize(horizontal: false, vertical: true)
                      .accessibilityIdentifier("customMetadataValue\(field.fieldId)")
                  }
                  .accessibilityElement(children: .combine)
                }
              }
            }
          }
        } else if let error = model.error {
          ContentUnavailableView(
            "Could not open book", systemImage: "exclamationmark.triangle", description: Text(error)
          )
        } else {
          ProgressView("Loading book…")
        }
      }
      .navigationTitle("Book details")
      .toolbar { Button("Done", action: dismiss.callAsFunction) }
    }
    .task { await model.load() }
    .fullScreenCover(item: $selectedFile) { file in
      PDFReaderView(api: model.api, file: file)
    }
    .fullScreenCover(item: $model.draft) { draft in MetadataEditorView(model: model, draft: draft) }
    .fullScreenCover(isPresented: $isEditingCovers, onDismiss: { Task { await model.load() } }) {
      if let book = model.book { CoverEditorView(api: model.api, book: book) }
    }
    .sheet(isPresented: $isAddingToCollection) {
      CollectionPickerView(api: model.api, bookID: model.bookID) { collection in
        collectionResult = "Added to \(collection.name)"
      }
    }
  }
}
