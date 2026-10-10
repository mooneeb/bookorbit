import Foundation
import Observation

@MainActor @Observable
final class ReaderBookmarksModel {
  let api: BookOrbitAPI
  let bookID: Int
  let fileID: Int
  let pageCount: Int
  let currentPage: Int
  var title: String
  private(set) var items: [BookmarkResponse] = []
  private(set) var nextCursor: Int?
  private(set) var isLoading = false
  private(set) var isSaving = false
  private(set) var hasLoaded = false
  private(set) var status = ""
  var error: String?
  private var cursor: Int?
  private var previousCursors: [Int?] = []
  private var isClosed = false
  private var outbox: OfflineBookmarkOutbox?
  private var generation: UUID?

  init(api: BookOrbitAPI, bookID: Int, fileID: Int, currentPage: Int, pageCount: Int) {
    self.api = api
    self.bookID = bookID
    self.fileID = fileID
    self.currentPage = currentPage
    self.pageCount = pageCount
    title = "Page \(currentPage)"
  }

  var isBusy: Bool { isLoading || isSaving }
  var canRemove: Bool { !isBusy && outbox?.canWrite == true }
  var hasPrevious: Bool { !previousCursors.isEmpty }
  var hasAcknowledgedBookmark: Bool { !hasLoaded && !items.isEmpty }
  var canSave: Bool {
    !isBusy && hasLoaded && outbox?.canWrite == true && pageCount > 0
      && (1...max(1, pageCount)).contains(currentPage)
      && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && title.utf16.count <= 500
  }

  func load() async { await loadPage(cursor) }

  func firstPage() async {
    guard !isBusy else { return }
    if await loadPage(nil) { previousCursors.removeAll() }
  }

  func nextPage() async {
    guard !isBusy, let nextCursor else { return }
    let old = cursor
    if await loadPage(nextCursor) {
      previousCursors.append(old)
      if previousCursors.count > 32 { previousCursors.removeFirst() }
    }
  }

  func previousPage() async {
    guard !isBusy, let previous = previousCursors.last else { return }
    if await loadPage(previous) { previousCursors.removeLast() }
  }

  func save() async {
    guard canSave, !isClosed, let outbox, let generation else { return }
    isSaving = true
    error = nil
    status = ""
    defer { isSaving = false }
    do {
      try await outbox.checkSession(generation)
      let id = UUID()
      let localID = OfflineBookmarkOutbox.temporaryID(id)
      let payload = CreateFixedPageBookmarkPayload(
        fileId: fileID, pageNumber: currentPage,
        title: title.trimmingCharacters(in: .whitespacesAndNewlines))
      let body = try JSONEncoder().encode(
        OfflineIdentifiedBookmark(payload: payload, clientId: id.uuidString))
      let local = BookmarkResponse(
        id: localID, bookId: bookID, cfi: nil,
        title: payload.title, positionSeconds: nil, fileId: fileID, pageNumber: currentPage,
        createdAt: ISO8601DateFormatter().string(from: Date()))
      try outbox.update { state in
        state.operations.append(
          OfflineBookmarkOperation(
            id: id,
            path: "books/\(bookID)/bookmarks/fixed-page", method: "POST", body: body,
            localID: localID, audioID: nil))
        state.items.insert(local, at: 0)
        state.items = Array(state.items.prefix(40))
      }
      items = outbox.state.items
      do {
        try await outbox.flush(session: generation)
        items = outbox.state.items
        status = "Bookmarked page \(currentPage)."
      } catch is URLError {
        status = "Bookmark saved on this iPad. It will sync when connected."
      }
    } catch { if !isClosed { self.error = error.localizedDescription } }
  }

  func remove(_ bookmark: BookmarkResponse) async {
    guard !isBusy, !isClosed, let outbox, outbox.canWrite, let generation,
      items.contains(where: { $0.id == bookmark.id })
    else { return }
    isSaving = true
    error = nil
    defer { isSaving = false }
    do {
      try await outbox.checkSession(generation)
      try outbox.update { state in
        if bookmark.id < 0 {
          if let index = state.operations.firstIndex(where: { $0.localID == bookmark.id }),
            state.operations[index].transmitted
          {
            state.operations[index].cancelAfterCreate = true
          } else {
            state.operations.removeAll { $0.localID == bookmark.id }
          }
        } else {
          state.operations.append(
            OfflineBookmarkOperation(
              id: UUID(),
              path: "books/\(bookID)/bookmarks/\(bookmark.id)", method: "DELETE", body: nil,
              localID: bookmark.id, audioID: nil))
        }
        state.recoveryOperations.removeAll { $0.localID == bookmark.id }
        state.items.removeAll { $0.id == bookmark.id }
      }
      items = outbox.state.items
      do {
        try await outbox.flush(session: generation)
        status = "Bookmark removed."
      } catch is URLError {
        status = "Removal saved on this iPad. It will sync when connected."
      }
    } catch { if !isClosed { self.error = error.localizedDescription } }
  }

  func close() { isClosed = true }

  @discardableResult
  private func loadPage(_ requested: Int?) async -> Bool {
    guard !isBusy, !isClosed else { return false }
    isLoading = true
    error = nil
    defer { isLoading = false }
    do {
      let session = try await api.authenticatedSessionGeneration()
      if let generation, generation != session { throw ConnectionError.expiredSession }
      generation = session
      if outbox == nil {
        outbox = try await OfflineBookmarkOutbox.open(
          api: api, bookID: bookID, fileID: fileID, channel: "fixed")
      }
      if let outbox {
        try await outbox.checkSession(session)
        do { try await outbox.flush(session: session) } catch is URLError {}
      }
      var query = [
        URLQueryItem(name: "fileId", value: String(fileID)),
        URLQueryItem(name: "limit", value: "40"),
      ]
      if let requested { query.append(URLQueryItem(name: "beforeId", value: String(requested))) }
      let page: BookmarksPage = try await api.send("books/\(bookID)/bookmarks/page", query: query)
      guard !isClosed else { return false }
      guard page.items.count <= 40,
        page.items.allSatisfy({
          $0.bookId == bookID && $0.fileId == fileID && $0.id > 0 && ($0.pageNumber ?? 0) > 0
            && $0.cfi == nil && $0.positionSeconds == nil
        }), page.nextCursor == nil || page.nextCursor == page.items.last?.id
      else { throw ConnectionError.invalidResponse }
      let pendingItems = outbox?.state.items.filter { $0.id < 0 } ?? []
      let deleted = Set(
        (outbox?.state.deletedIDs ?? [])
          + (outbox?.state.operations.filter { $0.method == "DELETE" }.compactMap(\.localID) ?? []))
      items = pendingItems + page.items.filter { !deleted.contains($0.id) }
      try outbox?.update { $0.items = Array(items.prefix(40)) }
      nextCursor = page.nextCursor
      cursor = requested
      hasLoaded = true
      return true
    } catch is CancellationError {
      return false
    } catch {
      if !isClosed, let outbox {
        items = outbox.state.items
        hasLoaded = true
        if error is URLError {
          status = "Bookmarks saved on this iPad. Connect to sync pending changes."
        } else {
          self.error =
            "Pending bookmarks remain on this iPad for review. \(error.localizedDescription)"
        }
        return true
      }
      if !isClosed { self.error = error.localizedDescription }
      return false
    }
  }
}
