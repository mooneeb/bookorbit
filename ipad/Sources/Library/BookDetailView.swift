import SwiftUI

struct BookDetailView: View {
  let canEditMetadata: Bool
  let canRead: Bool
  @Environment(\.dismiss) private var dismiss
  @State private var model: BookDetailModel
  @State private var isManagingCollections = false
  @State private var collectionResult: String?
  @State private var isEditingCovers = false
  @State private var selectedFile: BookDetailFile?
  @State private var isEditingReading = false

  init(api: BookOrbitAPI, bookID: Int, canEditMetadata: Bool, canRead: Bool) {
    self.canEditMetadata = canEditMetadata
    self.canRead = canRead
    _model = State(initialValue: BookDetailModel(api: api, bookID: bookID))
  }

  private func isReadable(_ file: BookDetailFile) -> Bool {
    let format = file.format?.lowercased() ?? ""
    return NativeEbookVocabulary.mimeTypes[format] != nil
      || ["pdf", "cbz", "cbr", "cb7"].contains(format)
      || AudioStreamFormat.mimeTypes[format] != nil
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
                  if canRead, isReadable(file) {
                    Button("Read") { selectedFile = file }
                      .accessibilityIdentifier("readFile\(file.id)")
                  }
                }
              }
            }
            Section("Collections") {
              Button("Manage collections") { isManagingCollections = true }
                .accessibilityIdentifier("addToCollection")
              if let collectionResult {
                Text(collectionResult).fixedSize(horizontal: false, vertical: true)
                  .accessibilityIdentifier("collectionMembershipResult")
              }
            }
            Section("Your reading") {
              LabeledContent(
                "Status", value: BookReadingDraft.label(book.readStatus?.status ?? "unread")
              )
              .accessibilityIdentifier("bookReadingCurrentStatus")
              if let note = book.personalNote {
                Text(note).fixedSize(horizontal: false, vertical: true)
                  .accessibilityIdentifier("bookReadingCurrentNote")
              }
              Button {
                isEditingReading = true
              } label: {
                Text("Edit your reading").frame(minHeight: 44).contentShape(Rectangle())
              }.accessibilityIdentifier("editBookReading")
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
    .fullScreenCover(item: $selectedFile, onDismiss: { Task { await model.load() } }) { file in
      NativeReaderHost(
        api: model.api, bookID: model.bookID, file: file,
        files: model.book?.files ?? [], title: model.book?.title ?? "Book",
        language: model.book?.language)
    }
    .fullScreenCover(item: $model.draft) { draft in MetadataEditorView(model: model, draft: draft) }
    .fullScreenCover(isPresented: $isEditingReading, onDismiss: { Task { await model.load() } }) {
      if let book = model.book {
        BookReadingView(api: model.api, book: book, acknowledged: model.acknowledgeReading) {
          saved in
          model.acknowledgeReading(saved)
          isEditingReading = false
        }
      }
    }
    .fullScreenCover(isPresented: $isEditingCovers, onDismiss: { Task { await model.load() } }) {
      if let book = model.book { CoverEditorView(api: model.api, book: book) }
    }
    .sheet(isPresented: $isManagingCollections) {
      CollectionPickerView(api: model.api, bookID: model.bookID) { collection, included in
        collectionResult =
          included ? "Added to \(collection.name)" : "Removed from \(collection.name)"
      }
    }
  }
}
