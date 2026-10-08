import SwiftUI

struct BookDetailView: View {
  let canEditMetadata: Bool
  private let requestedAPI: BookOrbitAPI
  private let requestedBookID: Int
  let canRead: Bool
  let canDeleteBooks: Bool
  let userID: Int
  let bookUnavailable: (Int, BookDeletionOutcome) -> Void
  private let readAloudSyncRequestedAPI: BookOrbitAPI
  private let readAloudSyncRequestedBookID: Int
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
  @State private var positionReset: NativePositionResetModel?
  @State private var positionResetNotice: String?
  @State private var movement: BookMoveModel?
  @State private var moveNotice: String?
  @State private var addedAtContext = UUID()
  @State private var readAloudSync: BookReadAloudSyncModel?
  @State private var fileActions: BookFileActionsModel?
  @State private var isWritingFiles = false

  init(
    api: BookOrbitAPI, bookID: Int, canEditMetadata: Bool, canRead: Bool,
    canDeleteBooks: Bool = false,
    userID: Int = 0,
    bookUnavailable: @escaping (Int, BookDeletionOutcome) -> Void = { _, _ in }
  ) {
    self.canEditMetadata = canEditMetadata
    requestedAPI = api
    requestedBookID = bookID
    self.canRead = canRead
    self.canDeleteBooks = canDeleteBooks
    self.userID = userID
    self.bookUnavailable = bookUnavailable
    readAloudSyncRequestedAPI = api
    readAloudSyncRequestedBookID = bookID
    _model = State(initialValue: BookDetailModel(api: api, bookID: bookID))
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
            if requestedBookID == book.id, requestedAPI === model.api {
              addedAtSection(book)
            }
            Section("Files") {
              BookFileWriteStatusView(book: book)
              if let fileWrite = model.fileWrite {
                if let result = fileWrite.result { BookWriteAndRenameResultView(result: result) }
                if let message = fileWrite.message {
                  Text(message).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("bookFileWriteDetailMessage")
                }
                if canEditMetadata {
                  Button("Review source-file status", action: promptFileWrite)
                    .frame(minHeight: 44).accessibilityIdentifier("bookFileWriteDetailReview")
                }
              }
              if canEditMetadata {
                Button("Edit metadata for file writing", action: model.beginEditing)
                  .frame(minHeight: 44).disabled(model.isSaving)
                  .accessibilityIdentifier("bookFilesEditMetadata")
              }
              ForEach(book.files) { file in
                BookFileRowView(
                  file: file, canRead: canRead, canManage: userID > 0 && !model.isSaving,
                  open: openFile, manage: promptFileActions)
              }
              if book.files.isEmpty {
                Text("This book has no files. Its current server status is \(book.status).")
                  .fixedSize(horizontal: false, vertical: true)
                  .accessibilityIdentifier("bookHasNoFiles")
              }
            }
            if userID > 0 {
              BookPositionResetSection(
                book: book, canDownload: canRead, isDisabled: model.isSaving,
                notice: positionResetNotice, reset: promptPositionReset)
            }
            Section("Collections") {
              Button("Manage collections") { isManagingCollections = true }
                .accessibilityIdentifier("addToCollection")
              if let collectionResult {
                Text(collectionResult).fixedSize(horizontal: false, vertical: true)
                  .accessibilityIdentifier("collectionMembershipResult")
              }
            }
            if BookReadAloudSyncPresentation.isVisible(book) {
              Section("Read-aloud progress sync") {
                LabeledContent(
                  "Saved mode",
                  value: BookReadAloudSyncPresentation.modeLabel(book.readAloudSync.mode)
                )
                .accessibilityIdentifier("bookReadAloudSyncMode")
                BookReadAloudSyncStatusView(book: book)
                Button("Edit progress sync", action: promptReadAloudSync).frame(minHeight: 44)
                  .disabled(model.isSaving).accessibilityIdentifier("editReadAloudSync")
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
    .onChange(of: ObjectIdentifier(readAloudSyncRequestedAPI)) { _, _ in discardReadAloudSync() }
    .onChange(of: readAloudSyncRequestedBookID) { _, _ in discardReadAloudSync() }
    .onChange(of: requestedBookID) { _, _ in addedAtContext = UUID() }
    .onChange(of: ObjectIdentifier(requestedAPI)) { _, _ in addedAtContext = UUID() }
    .onChange(of: userID) { _, _ in
      positionReset?.detach()
      positionReset = nil
      positionResetNotice = nil
      addedAtContext = UUID()
      discardReadAloudSync()
      fileActions?.close()
      fileActions = nil
      model.detachFileWrite()
      isWritingFiles = false
      movement?.detach()
      movement = nil
      moveNotice = nil
      deletion?.detach()
      deletion = nil
      deletionOutcome = nil
      deletionNotice = nil
    }
    .sheet(item: $positionReset) { reset in
      NativePositionResetView(model: reset, closed: positionResetClosed)
    }
    .sheet(item: $fileActions, onDismiss: { Task { await model.load() } }) { actions in
      BookFileActionsView(model: actions)
    }
    .sheet(isPresented: $isWritingFiles) {
      if let fileWrite = model.fileWrite { BookWriteAndRenameView(model: fileWrite) }
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
    .sheet(item: $readAloudSync) { setting in
      BookReadAloudSyncView(model: setting) { saved, session in
        guard readAloudSync?.id == setting.id, !setting.isDetached,
          model.api === readAloudSyncRequestedAPI, model.bookID == readAloudSyncRequestedBookID
        else { return }
        await model.acknowledgeReadAloudSync(saved, session: session) {
          readAloudSync?.id == setting.id && !setting.isDetached
            && model.api === readAloudSyncRequestedAPI
            && model.bookID == readAloudSyncRequestedBookID
        }
      }
    }
  }

  private func promptReadAloudSync() {
    guard let book = model.book, !model.isSaving,
      model.api === readAloudSyncRequestedAPI, model.bookID == readAloudSyncRequestedBookID
    else { return }
    readAloudSync = BookReadAloudSyncModel(
      api: model.api, bookID: model.bookID, files: book.files,
      userID: userID > 0 ? userID : nil)
  }

  private func discardReadAloudSync() {
    readAloudSync?.detach()
    readAloudSync = nil
  }

  private func promptPositionReset(_ target: NativePositionResetTarget) {
    guard userID > 0, model.book != nil, !model.isSaving else { return }
    positionReset = NativePositionResetModel(api: model.api, target: target)
  }

  private func positionResetClosed(_ reset: NativePositionResetModel) {
    guard positionReset?.id == reset.id else {
      reset.detach()
      return
    }
    if reset.isConfirmed {
      positionResetNotice = "Saved position cleared for \(reset.target.label)."
    } else if reset.didAttempt {
      positionResetNotice =
        reset.message ?? reset.error
        ?? "Position reset was not confirmed. Check its current server position before retrying."
    }
    reset.detach()
    positionReset = nil
    if reset.didAttempt { Task { await model.load() } }
  }

  private func addedAtSection(_ book: BookDetail) -> some View {
    let context = addedAtContext
    return BookAddedAtSection(
      api: model.api, book: book, userID: userID, canEditMetadata: canEditMetadata,
      acknowledged: { saved in
        guard addedAtContext == context, saved.id == requestedBookID,
          requestedAPI === model.api
        else { return }
        model.acknowledgeAddedAt(saved)
      }
    )
    .id(
      "\(context).user.\(userID).book.\(requestedBookID).library.\(book.libraryId).added.\(book.addedAt)"
    )
  }

  private func openFile(_ file: BookDetailFile) {
    guard canRead, model.book?.files.contains(where: { $0.id == file.id }) == true else { return }
    selectedFile = file
  }

  private func promptFileActions(_ file: BookDetailFile) {
    guard userID > 0, !model.isSaving,
      model.book?.files.contains(where: { $0.id == file.id }) == true
    else { return }
    fileActions = BookFileActionsModel(
      api: model.api, bookID: model.bookID, fileID: file.id, userID: userID,
      acknowledged: model.acknowledgeFiles, mutationPending: model.awaitFileReadback)
  }

  private func promptFileWrite() {
    model.beginWritingFiles()
    if model.fileWrite != nil { isWritingFiles = true }
  }

  private func promptDelete() {
    guard canDeleteBooks, userID > 0, model.book != nil, !model.isSaving else { return }
    deletion = BookDeletionModel(api: model.api, bookID: model.bookID, userID: userID)
  }

  private func deleted(_ outcome: BookDeletionOutcome) {
    discardReadAloudSync()
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
      discardReadAloudSync()
      model.draft = nil
      isEditingReading = false
      isEditingCovers = false
      isManagingCollections = false
      moveNotice = notice
      await model.reconcileMove(session: session)
    }
  }
}
