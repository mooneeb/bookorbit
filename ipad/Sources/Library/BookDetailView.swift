import SwiftUI

struct BookDetailView: View {
  let canEditMetadata: Bool
  let canRead: Bool
  let canDeleteBooks: Bool
  let userID: Int
  let bookUnavailable: (Int, BookDeletionOutcome) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var model: BookDetailModel
  @State private var isManagingCollections = false
  @State private var collectionResult: String?
  @State private var isEditingCovers = false
  @State private var selectedFile: BookDetailFile?
  @State private var isEditingReading = false
  @State private var deletion: BookDeletionModel?
  @State private var deletionOutcome: BookDeletionOutcome?
  @State private var deletionNotice: String?
  @State private var movement: BookMoveModel?
  @State private var moveNotice: String?

  init(
    api: BookOrbitAPI, bookID: Int, canEditMetadata: Bool, canRead: Bool,
    canDeleteBooks: Bool = false,
    userID: Int = 0,
    bookUnavailable: @escaping (Int, BookDeletionOutcome) -> Void = { _, _ in }
  ) {
    self.canEditMetadata = canEditMetadata
    self.canRead = canRead
    self.canDeleteBooks = canDeleteBooks
    self.userID = userID
    self.bookUnavailable = bookUnavailable
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
              if let deletionNotice {
                Text(deletionNotice).fixedSize(horizontal: false, vertical: true)
                  .accessibilityIdentifier("bookDeletionNotice")
              }
              if let moveNotice {
                Text(moveNotice).fixedSize(horizontal: false, vertical: true)
                  .accessibilityIdentifier("bookMoveNotice")
              }
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
                if userID > 0 {
                  Button("Move to library", action: promptMove).frame(minHeight: 44)
                    .disabled(model.isSaving).accessibilityIdentifier("moveBook")
                }
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
            if canDeleteBooks, userID > 0 {
              Section {
                Button("Delete book", role: .destructive, action: promptDelete)
                  .frame(minHeight: 44)
                  .disabled(model.isSaving)
                  .accessibilityIdentifier("deleteBook")
              }
            }
          }
        } else if let error = model.error {
          ContentUnavailableView {
            Label("Could not open book", systemImage: "exclamationmark.triangle")
          } description: {
            Text(error)
          } actions: {
            Button("Reload book") { Task { await model.load() } }
              .accessibilityIdentifier("reloadBookDetails")
          }
        } else {
          ProgressView("Loading book…")
        }
      }
      .navigationTitle("Book details")
      .toolbar { Button("Done", action: dismiss.callAsFunction) }
    }
    .task { await model.load() }
    .onChange(of: userID) { _, _ in
      movement?.detach()
      movement = nil
      moveNotice = nil
      deletion?.detach()
      deletion = nil
      deletionOutcome = nil
      deletionNotice = nil
    }
    .sheet(item: $movement) { movement in
      BookMoveView(model: movement, closed: moveClosed)
    }
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
    .sheet(item: $deletion, onDismiss: deletionClosed) { deletion in
      BookDeletionView(model: deletion, resolved: deleted, closed: deletionDisappeared)
    }
  }

  private func promptDelete() {
    guard canDeleteBooks, userID > 0, model.book != nil, !model.isSaving else { return }
    deletion = BookDeletionModel(api: model.api, bookID: model.bookID, userID: userID)
  }

  private func deleted(_ outcome: BookDeletionOutcome) {
    model.discardDeletedBook()
    selectedFile = nil
    deletionOutcome = outcome
    deletion = nil
    bookUnavailable(model.bookID, outcome)
  }

  private func deletionClosed() {
    if deletionOutcome != nil { dismiss() }
  }

  private func deletionDisappeared(_ deletion: BookDeletionModel) {
    guard deletion.didAttemptDeletion, deletion.outcome == nil, let session = deletion.session
    else {
      return
    }
    Task {
      guard await deletion.belongsToCurrentSession() else { return }
      deletionNotice = "The deletion was not confirmed. Reloading the book's current status."
      if let outcome = await model.reconcileDeletion(session: session) {
        deleted(outcome)
        dismiss()
      } else if model.book != nil {
        deletionNotice =
          "This book is currently available. The earlier deletion was not confirmed and may still be finishing."
      }
    }
  }

  private func promptMove() {
    guard canEditMetadata, userID > 0, model.book != nil, !model.isSaving else { return }
    movement = BookMoveModel(api: model.api, bookID: model.bookID, userID: userID)
  }

  private func moveClosed(_ movement: BookMoveModel) {
    guard movement.needsStatusRefresh, let session = movement.session else { return }
    let notice =
      movement.message ?? "The move is unconfirmed. Reload this book to check its current library."
    Task {
      guard await movement.belongsToCurrentSession() else { return }
      selectedFile = nil
      model.draft = nil
      isEditingReading = false
      isEditingCovers = false
      isManagingCollections = false
      moveNotice = notice
      await model.reconcileMove(session: session)
    }
  }
}
