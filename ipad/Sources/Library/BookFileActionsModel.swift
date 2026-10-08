import Foundation
import Observation
import UIKit
import UniformTypeIdentifiers

@MainActor @Observable
final class BookFileActionsModel: Identifiable {
  enum Mutation: Equatable {
    case rename(String)
    case delete
  }

  let id = UUID()
  let api: BookOrbitAPI
  let bookID: Int
  let fileID: Int
  let userID: Int
  private(set) var book: BookDetail?
  private(set) var file: BookDetailFile?
  private(set) var user: AuthUser?
  private(set) var session: UUID?
  private(set) var isBusy = false
  private(set) var isMutating = false
  private(set) var progress: BookFileTransferProgress?
  private(set) var staged: StagedBookFile?
  private(set) var needsReadback = false
  private(set) var isClosed = false
  var message: String?
  var renameFilename = ""
  var isEditingRename = false
  var isConfirmingDelete = false
  var delivery: BookFileDeliveryPresentation?
  private var operation = UUID()
  private var pendingMutation: Mutation?
  private var transfer: Task<Void, Never>?
  private let acknowledged: (BookDetail) -> Void
  private let mutationPending: (UUID) -> Void

  init(
    api: BookOrbitAPI, bookID: Int, fileID: Int, userID: Int,
    acknowledged: @escaping (BookDetail) -> Void, mutationPending: @escaping (UUID) -> Void
  ) {
    self.api = api
    self.bookID = bookID
    self.fileID = fileID
    self.userID = userID
    self.acknowledged = acknowledged
    self.mutationPending = mutationPending
  }

  var isDownloading: Bool { transfer != nil }
  var canRename: Bool { canAct && user?.hasPermission(.libraryEditMetadata) == true }
  var canDelete: Bool { canAct && user?.hasPermission(.libraryDeleteBooks) == true }
  var canDownload: Bool { canAct && user?.hasPermission(.libraryDownload) == true }
  var canCopyPath: Bool { canAct && file?.absolutePath.isEmpty == false }
  var canDownloadWithoutAudio: Bool {
    canDownload && file?.format?.lowercased() == "epub" && file?.mediaOverlay?.available == true
  }
  var canAct: Bool { !isBusy && !isClosed && !needsReadback && file != nil && staged == nil }
  var trimmedFilename: String { renameFilename.trimmingCharacters(in: .whitespacesAndNewlines) }
  var renameValidation: String? {
    let name = trimmedFilename
    if name.isEmpty { return "Enter a filename including its extension." }
    if name == "." || name == ".." || name.contains("/") || name.contains("\\")
      || name.contains("\0")
    {
      return "Use one filename without folder separators, dot paths, or NUL characters."
    }
    if name.utf8.count > 255 { return "The filename must be no longer than 255 UTF-8 bytes." }
    return nil
  }

  func reload() async {
    guard !isBusy, !isClosed else { return }
    isBusy = true
    let operation = UUID()
    self.operation = operation
    defer { if self.operation == operation { isBusy = false } }
    do {
      if session == nil { session = try await api.authenticatedSessionGeneration() }
      guard let session else { throw ConnectionError.expiredSession }
      try await refresh(session: session, operation: operation)
      guard await accepts(operation, session: session) else { return }
      needsReadback = false
      if let pendingMutation {
        switch pendingMutation {
        case .delete:
          message =
            file == nil
            ? "This file is no longer listed. The earlier deletion acknowledgement was not received."
            : "This file is currently listed. The earlier request may still be finishing. Confirm again only if you still want to delete it."
        case .rename(let name):
          message =
            file?.filename == name
            ? "The current filename matches your request. The earlier acknowledgement was not received."
            : "Current file details loaded. Check the filename before trying the rename again."
        }
        self.pendingMutation = nil
      } else {
        message = file == nil ? "This file is no longer available in this book." : nil
      }
    } catch {
      if let session, !(await accepts(operation, session: session)) { return }
      file = nil
      book = nil
      user = nil
      message = "Could not check this file. Reload when connected. \(error.localizedDescription)"
    }
  }

  func beginRename() {
    guard canRename, let file else { return }
    renameFilename = file.filename ?? ""
    message = nil
    isEditingRename = true
  }

  func cancelRename() {
    guard !isBusy else { return }
    isEditingRename = false
  }

  func beginDelete() {
    guard canDelete else { return }
    message = nil
    isConfirmingDelete = true
  }

  func cancelDelete() {
    guard !isBusy else { return }
    isConfirmingDelete = false
  }

  func rename() async {
    guard canRename, isEditingRename, renameValidation == nil else { return }
    await mutate(.rename(trimmedFilename))
  }

  func delete() async {
    guard canDelete, isConfirmingDelete else { return }
    await mutate(.delete)
  }

  func copyPath() async {
    guard canCopyPath, let session else { return }
    isBusy = true
    let operation = UUID()
    self.operation = operation
    defer { if self.operation == operation { isBusy = false } }
    do {
      try await refresh(session: session, operation: operation)
      guard await accepts(operation, session: session) else { return }
      guard let path = file?.absolutePath, !path.isEmpty else { throw ConnectionError.http(404) }
      UIPasteboard.general.setItems(
        [[UTType.utf8PlainText.identifier: path]], options: [.localOnly: true])
      message =
        UIPasteboard.general.string == path
        ? "Server path copied." : "The server path could not be copied. Try again."
    } catch {
      guard await accepts(operation, session: session) else { return }
      file = nil
      book = nil
      user = nil
      message =
        "Could not copy the current server path. Reload to retry. \(error.localizedDescription)"
    }
  }

  func download(_ kind: BookFileDownloadKind) {
    guard canDownload, kind != .withoutAudio || canDownloadWithoutAudio, let session else { return }
    isBusy = true
    progress = nil
    message = "Preparing download."
    let operation = UUID()
    self.operation = operation
    transfer = Task {
      var prepared = false
      defer {
        if self.operation == operation {
          self.isBusy = false
          self.transfer = nil
          self.progress = nil
        }
      }
      do {
        try await self.refresh(session: session, operation: operation)
        guard await self.accepts(operation, session: session),
          self.user?.hasPermission(.libraryDownload) == true, let file = self.file,
          kind != .withoutAudio
            || (file.format?.lowercased() == "epub" && file.mediaOverlay?.available == true)
        else { throw ConnectionError.denied }
        prepared = true
        let artifact = try await self.api.downloadBookFile(
          fileID: self.fileID, kind: kind, session: session,
          progress: { [weak self] value in
            guard let self, !self.isClosed, self.operation == operation else { return }
            self.progress = value
            self.message = "Downloading."
          })
        guard await self.accepts(operation, session: session), !Task.isCancelled else {
          artifact.remove()
          return
        }
        self.staged = artifact
        self.message = "Download ready. Save or share this file."
      } catch {
        guard await self.accepts(operation, session: session) else { return }
        if !prepared {
          self.file = nil
          self.book = nil
          self.user = nil
        }
        self.message =
          Task.isCancelled
          ? "Download cancelled."
          : "Download failed. \(prepared ? "Try again when connected." : "Reload file details to retry.") \(error.localizedDescription)"
      }
    }
  }

  func cancelDownload() {
    guard transfer != nil else { return }
    transfer?.cancel()
    message = "Cancelling download."
  }

  func presentDelivery(_ kind: BookFileDeliveryPresentation.Kind) async {
    guard !isBusy, !isClosed, let staged, let session else { return }
    guard await accepts(operation, session: session) else { return }
    delivery = BookFileDeliveryPresentation(artifact: staged, kind: kind)
  }

  func finishDelivery(_ result: BookFileDeliveryResult, artifactID: UUID) {
    guard staged?.id == artifactID else { return }
    delivery = nil
    discardDownload()
    switch result {
    case .saved: message = "File saved to your selected location."
    case .shared: message = "File shared."
    case .cancelled: message = "Delivery cancelled."
    case .failed: message = "The file could not be delivered. Download it again to retry."
    }
    if staged != nil {
      message =
        "\(message ?? "") Temporary content could not be removed. Use Discard download to retry cleanup."
    }
  }

  func discardDownload() {
    delivery = nil
    guard let staged else { return }
    if staged.remove() {
      self.staged = nil
      message = "Temporary download removed."
    } else {
      message =
        "The temporary download could not be removed. Use Discard download to retry cleanup."
    }
  }

  func close() {
    transfer?.cancel()
    transfer = nil
    operation = UUID()
    isClosed = true
    isBusy = false
    isMutating = false
    file = nil
    book = nil
    user = nil
    discardDownload()
  }

  private func refresh(session: UUID, operation: UUID) async throws {
    let user: AuthUser = try await api.boundedJSON("auth/me", session: session)
    guard await accepts(operation, session: session), user.id == userID else {
      throw ConnectionError.expiredSession
    }
    let book: BookDetail = try await api.boundedJSON("books/\(bookID)", session: session)
    guard await accepts(operation, session: session), book.id == bookID else {
      throw ConnectionError.invalidResponse
    }
    self.user = user
    self.book = book
    file = book.files.first { $0.id == fileID }
    acknowledged(book)
  }

  private func accepts(_ operation: UUID, session: UUID) async -> Bool {
    guard !isClosed, self.operation == operation else { return false }
    guard (try? await api.authenticatedSessionGeneration()) == session else {
      close()
      message = "Your session changed. Close this dialog and sign in again."
      return false
    }
    return !isClosed && self.operation == operation
  }

  private func mutate(_ mutation: Mutation) async {
    guard let session else { return }
    isBusy = true
    message = nil
    let operation = UUID()
    self.operation = operation
    var attempted = false
    var acknowledged = false
    isMutating = true
    defer {
      if self.operation == operation {
        isBusy = false
        isMutating = false
      }
    }
    do {
      try await refresh(session: session, operation: operation)
      guard await accepts(operation, session: session), file != nil else {
        throw ConnectionError.http(404)
      }
      let permission: Permission = mutation == .delete ? .libraryDeleteBooks : .libraryEditMetadata
      guard user?.hasPermission(permission) == true else { throw ConnectionError.denied }
      try Task.checkCancellation()
      attempted = true
      mutationPending(session)
      switch mutation {
      case .rename(let filename):
        try await api.sendEmpty(
          "books/files/\(fileID)", method: "PATCH",
          body: JSONEncoder().encode(UpdateBookFilePayload(filename: filename)),
          session: session, expectedStatus: 204)
      case .delete:
        try await api.sendEmpty(
          "books/files/\(fileID)", method: "DELETE", session: session, expectedStatus: 204)
      }
      guard await accepts(operation, session: session) else { return }
      acknowledged = true
      isEditingRename = false
      isConfirmingDelete = false
      try await refresh(session: session, operation: operation)
      guard await accepts(operation, session: session) else { return }
      switch mutation {
      case .rename(let filename):
        guard file?.filename == filename else { throw ConnectionError.invalidResponse }
        message = "Rename acknowledged. Current file details loaded."
      case .delete:
        guard file == nil else { throw ConnectionError.invalidResponse }
        message =
          book?.files.isEmpty == true
          ? "File deletion acknowledged. The book remains without files."
          : "File deletion acknowledged. Current remaining files loaded."
      }
    } catch {
      guard await accepts(operation, session: session) else { return }
      if attempted {
        needsReadback = true
        pendingMutation = mutation
        isConfirmingDelete = false
        file = nil
        message =
          acknowledged
          ? "The file change was acknowledged, but current details could not be confirmed. Reload before continuing. \(error.localizedDescription)"
          : "The file change was not confirmed and may have completed. Reload current details before retrying. \(error.localizedDescription)"
      } else {
        file = nil
        book = nil
        user = nil
        message =
          "The file was not changed. Reload file details to retry. \(error.localizedDescription)"
      }
    }
  }
}
