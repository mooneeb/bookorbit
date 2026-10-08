import Foundation
import Observation

@MainActor @Observable
final class BookMoveModel: Identifiable {
  enum Phase: Equatable {
    case checking, destination, review, moving, finished, uncertain, denied, failed
  }

  let id = UUID()
  let api: BookOrbitAPI
  let bookID: Int
  let userID: Int
  private(set) var book: BookDetail?
  private(set) var phase = Phase.checking
  private(set) var destinations: [BookMoveDestination] = []
  private(set) var folders: [BookMoveFolder] = []
  private(set) var destinationPage = 0
  private(set) var destinationTotal = 0
  private(set) var folderPage = 0
  private(set) var folderTotal = 0
  private(set) var target: BookMoveDestination?
  private(set) var folder: BookMoveFolder?
  private(set) var preview: BookMovePreviewResult?
  private(set) var progress: BookMoveBookProgress?
  private(set) var summary: BookMoveCompletionEvent?
  private(set) var message: String?
  private(set) var didAttemptMove = false
  private(set) var needsStatusRefresh = false
  private(set) var hasUnconfirmedMove = false
  private(set) var session: UUID?
  var destinationSearch = ""
  var folderSearch = ""
  var collisionPolicy = ""
  private var sourceLibraryID: Int?
  private var operation = UUID()
  private var isAttached = true
  private var execution: Task<Void, Never>?
  let pageSize = 40

  init(api: BookOrbitAPI, bookID: Int, userID: Int) {
    self.api = api
    self.bookID = bookID
    self.userID = userID
  }

  var isBusy: Bool { phase == .checking || phase == .moving }
  var canPreview: Bool { phase == .destination && target != nil && folder != nil }
  var canConfirm: Bool {
    guard phase == .review, let preview else { return false }
    if preview.readyCount == 1 { return true }
    guard let collision = preview.collisions.first else { return false }
    return ["keep_both", "skip"].contains(collisionPolicy)
      || (collisionPolicy == "merge" && collision.kind == "hash_duplicate"
        && collision.existingBookId != nil)
  }
  var canReconcile: Bool { didAttemptMove && !isBusy && isAttached }
  var canPrepareAgain: Bool { isAttached && !isBusy && !didAttemptMove }
  var canPreviousDestinations: Bool { destinationPage > 0 && !isBusy }
  var canNextDestinations: Bool { (destinationPage + 1) * pageSize < destinationTotal && !isBusy }
  var canPreviousFolders: Bool { folderPage > 0 && !isBusy }
  var canNextFolders: Bool { (folderPage + 1) * pageSize < folderTotal && !isBusy }

  func prepare() async {
    guard isAttached, !didAttemptMove else { return }
    let operation = beginChecking()
    do {
      if session == nil { session = try await api.authenticatedSessionGeneration() }
      guard let session else { throw ConnectionError.expiredSession }
      let current = try await checkedBook(session: session)
      guard await accepts(operation) else { return }
      book = current
      sourceLibraryID = current.libraryId
      phase = .destination
      await loadDestinations(page: 0)
    } catch { await fail(error, operation: operation) }
  }

  func loadDestinations(page: Int) async {
    guard isAttached, phase != .moving, !didAttemptMove,
      let sourceLibraryID, let session, page >= 0
    else { return }
    let operation = beginChecking()
    preview = nil
    do {
      let result: BookMoveDestinationsPage = try await api.boundedJSON(
        "libraries/move-destinations",
        query: [
          URLQueryItem(name: "sourceLibraryId", value: String(sourceLibraryID)),
          URLQueryItem(name: "page", value: String(page)),
          URLQueryItem(name: "size", value: String(pageSize)),
          URLQueryItem(name: "q", value: destinationSearch),
        ], byteLimit: 256 * 1024, session: session, expectedStatus: 200)
      guard await accepts(operation) else { return }
      guard result.page == page, result.size == pageSize, result.total >= 0,
        result.items.count <= pageSize, Set(result.items.map(\.id)).count == result.items.count,
        result.items.allSatisfy({
          $0.id > 0 && $0.id != sourceLibraryID
            && ["book_per_file", "book_per_folder"].contains($0.organizationMode)
        })
      else { throw ConnectionError.invalidResponse }
      destinations = result.items
      destinationPage = page
      destinationTotal = result.total
      phase = .destination
    } catch { await fail(error, operation: operation) }
  }

  func chooseDestination(_ target: BookMoveDestination) async {
    guard phase == .destination, destinations.contains(where: { $0.id == target.id }) else {
      return
    }
    self.target = target
    folder = nil
    folders = []
    folderTotal = 0
    folderSearch = ""
    preview = nil
    await loadFolders(page: 0)
  }

  func loadFolders(page: Int) async {
    guard isAttached, phase != .moving, !didAttemptMove,
      let target, let session, page >= 0
    else { return }
    let operation = beginChecking()
    preview = nil
    do {
      let result: BookMoveFoldersPage = try await api.boundedJSON(
        "libraries/\(target.id)/move-folders",
        query: [
          URLQueryItem(name: "page", value: String(page)),
          URLQueryItem(name: "size", value: String(pageSize)),
          URLQueryItem(name: "q", value: folderSearch),
        ], byteLimit: 1024 * 1024, session: session, expectedStatus: 200)
      guard await accepts(operation) else { return }
      guard result.libraryId == target.id, result.page == page, result.size == pageSize,
        result.total >= 0, result.items.count <= pageSize,
        Set(result.items.map(\.id)).count == result.items.count,
        result.items.allSatisfy({ $0.id > 0 && !$0.path.isEmpty })
      else { throw ConnectionError.invalidResponse }
      folders = result.items
      folderPage = page
      folderTotal = result.total
      phase = .destination
    } catch { await fail(error, operation: operation) }
  }

  func chooseFolder(_ folder: BookMoveFolder) {
    guard phase == .destination, folders.contains(where: { $0.id == folder.id }) else { return }
    self.folder = folder
    preview = nil
  }

  func loadPreview() async {
    guard canPreview, let session, let target, let folder else { return }
    let operation = beginChecking()
    do {
      let current = try await checkedBook(session: session)
      guard await accepts(operation) else { return }
      guard current.libraryId == sourceLibraryID else {
        resetDestination(current)
        return
      }
      let result = try await fetchPreview(
        targetID: target.id, folderID: folder.id, session: session)
      guard await accepts(operation) else { return }
      book = current
      preview = result
      collisionPolicy = ""
      phase = .review
    } catch { await fail(error, operation: operation) }
  }

  func backToDestinations() {
    guard !isBusy, !didAttemptMove else { return }
    operation = UUID()
    preview = nil
    collisionPolicy = ""
    message = nil
    phase = .destination
  }

  func confirm() {
    guard canConfirm, execution == nil else { return }
    execution = Task { [weak self] in await self?.execute() }
  }

  func stop() {
    guard phase == .moving else { return }
    execution?.cancel()
    message = "Stopping the connection. A file move already started on the server can still finish."
  }

  func reconcile() async {
    guard canReconcile, let session else { return }
    let operation = beginChecking()
    preview = nil
    do {
      let current = try await checkedBook(session: session, requireMovePermission: false)
      guard await accepts(operation) else { return }
      book = current
      phase = summary == nil ? .uncertain : .finished
      if current.libraryId == target?.id {
        message =
          summary == nil
          ? "This book is currently in \(current.libraryName). The earlier move has no completion acknowledgement."
          : "Current library: \(current.libraryName). \(completionMessage)"
      } else {
        message =
          "Current library: \(current.libraryName). \(summary == nil ? "The earlier move is still unconfirmed and may be finishing." : completionMessage)"
      }
    } catch { await fail(error, operation: operation) }
  }

  func prepareAnotherMove() async {
    guard !isBusy, didAttemptMove, isAttached else { return }
    didAttemptMove = false
    summary = nil
    progress = nil
    preview = nil
    target = nil
    folder = nil
    collisionPolicy = ""
    destinations = []
    folders = []
    message = "A new move needs a fresh preview and confirmation."
    await prepare()
  }

  func belongsToCurrentSession() async -> Bool {
    guard let session else { return false }
    return (try? await api.authenticatedSessionGeneration()) == session
  }

  func detach() {
    isAttached = false
    operation = UUID()
    execution?.cancel()
    execution = nil
    book = nil
    preview = nil
    destinations = []
    folders = []
    target = nil
    folder = nil
    progress = nil
    message = nil
  }

  private var completionMessage: String {
    guard let summary else { return "The move outcome is unknown." }
    if summary.succeeded == 1 { return "Book moved." }
    if summary.merged == 1 { return "Book moved and the identical destination copy was merged." }
    if summary.failed == 1 {
      return "The server reported a failed move. Reload the book before trying again."
    }
    if summary.cancelled {
      return "The server stopped the move. Reload the book to check its current library."
    }
    return "No book was moved."
  }

  private func execute() async {
    guard canConfirm, let session, let target, let folder, let preview else {
      execution = nil
      return
    }
    let policy = preview.collisions.isEmpty ? "keep_both" : collisionPolicy
    let operation = beginChecking()
    defer { execution = nil }
    do {
      let current = try await checkedBook(session: session)
      guard await accepts(operation) else { return }
      guard current.libraryId == sourceLibraryID else {
        resetDestination(current)
        return
      }
      let fresh = try await fetchPreview(targetID: target.id, folderID: folder.id, session: session)
      guard await accepts(operation) else { return }
      guard fresh == preview else {
        self.preview = fresh
        collisionPolicy = ""
        phase = .review
        message =
          "The destination or warnings changed. Review this fresh preview and confirm again."
        return
      }
      try Task.checkCancellation()
      didAttemptMove = true
      needsStatusRefresh = true
      phase = .moving
      self.preview = nil
      let result = try await api.moveBook(
        BookMoveExplicitExecuteRequest(
          selection: BookIdsSelection(bookIds: [bookID]), targetLibraryId: target.id,
          targetFolderId: folder.id, collisionPolicy: policy, overrides: nil), session: session
      ) { [weak self] item in
        guard let self, self.isAttached, self.operation == operation else { return }
        self.progress = item
      }
      guard await accepts(operation) else { return }
      summary = result
      phase = .finished
      message = completionMessage
    } catch { await fail(error, operation: operation) }
  }

  private func checkedBook(session: UUID, requireMovePermission: Bool = true) async throws
    -> BookDetail
  {
    let user: AuthUser = try await api.boundedJSON("auth/me", session: session, expectedStatus: 200)
    guard user.id == userID else { throw ConnectionError.expiredSession }
    if requireMovePermission, !user.hasPermission(.libraryEditMetadata) {
      throw ConnectionError.denied
    }
    let current: BookDetail = try await api.boundedJSON(
      "books/\(bookID)", session: session, expectedStatus: 200)
    guard current.id == bookID else { throw ConnectionError.invalidResponse }
    return current
  }

  private func fetchPreview(targetID: Int, folderID: Int, session: UUID) async throws
    -> BookMovePreviewResult
  {
    let payload = BookMoveExplicitPreviewRequest(
      selection: BookIdsSelection(bookIds: [bookID]), targetLibraryId: targetID,
      targetFolderId: folderID)
    let result: BookMovePreviewResult = try await api.boundedJSON(
      "books/move/preview", method: "POST", body: JSONEncoder().encode(payload),
      byteLimit: 1024 * 1024, session: session, expectedStatus: 201)
    let counts = [
      result.readyCount, result.collisionCount, result.ineligibleCount, result.alreadyInTargetCount,
    ]
    guard result.targetLibraryId == targetID, result.targetFolderId == folderID,
      result.totalSelected == 1, counts.allSatisfy({ (0...1).contains($0) }),
      counts.reduce(0, +) == 1,
      result.ready.count == result.readyCount, result.collisions.count == result.collisionCount,
      result.ineligible.count == result.ineligibleCount, !result.collisionsTruncated,
      !result.ineligibleTruncated,
      result.ready.allSatisfy({ $0.bookId == bookID }),
      result.collisions.allSatisfy({
        $0.bookId == bookID
          && ["folder_path", "file_path", "hash_duplicate"].contains($0.kind)
          && ["keep_both", "merge", "skip"].contains($0.suggestedPolicy)
      }),
      result.ineligible.allSatisfy({ $0.bookId == bookID })
    else { throw ConnectionError.invalidResponse }
    return result
  }

  private func resetDestination(_ current: BookDetail) {
    book = current
    sourceLibraryID = current.libraryId
    target = nil
    folder = nil
    preview = nil
    destinations = []
    folders = []
    phase = .failed
    message = "This book changed libraries. Reload destinations and prepare a fresh move."
  }

  private func beginChecking() -> UUID {
    let operation = UUID()
    self.operation = operation
    phase = .checking
    message = nil
    return operation
  }

  private func accepts(_ operation: UUID) async -> Bool {
    guard isAttached, self.operation == operation else { return false }
    guard let session, (try? await api.authenticatedSessionGeneration()) == session else {
      detach()
      phase = .denied
      message = "Your session changed. Close this dialog and sign in again."
      return false
    }
    return isAttached && self.operation == operation
  }

  private func fail(_ error: any Error, operation: UUID) async {
    guard await accepts(operation) else { return }
    preview = nil
    if let rejection = error as? BookMoveRejection {
      didAttemptMove = false
      phase = .failed
      message = rejection.localizedDescription
    } else if case ConnectionError.expiredSession = error {
      detach()
      phase = .denied
      message = "Your session changed. Close this dialog and sign in again."
    } else if case ConnectionError.denied = error {
      book = nil
      destinations = []
      folders = []
      target = nil
      folder = nil
      phase = .denied
      message =
        didAttemptMove
        ? "Access changed. The move may have finished. Reload the book's current status."
        : "Editor access and permission to edit metadata are required for both libraries."
    } else {
      if didAttemptMove { hasUnconfirmedMove = true }
      phase = didAttemptMove ? .uncertain : .failed
      message =
        didAttemptMove
        ? "The move was not confirmed. The server may still finish it. Reload this book before preparing another move."
        : error.localizedDescription
    }
  }
}
