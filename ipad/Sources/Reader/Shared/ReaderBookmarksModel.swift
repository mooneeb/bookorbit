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

  init(api: BookOrbitAPI, bookID: Int, fileID: Int, currentPage: Int, pageCount: Int) {
    self.api = api
    self.bookID = bookID
    self.fileID = fileID
    self.currentPage = currentPage
    self.pageCount = pageCount
    title = "Page \(currentPage)"
  }

  var isBusy: Bool { isLoading || isSaving }
  var hasPrevious: Bool { !previousCursors.isEmpty }
  var canSave: Bool {
    !isBusy && hasLoaded && pageCount > 0 && (1...max(1, pageCount)).contains(currentPage)
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
    guard canSave, !isClosed else { return }
    isSaving = true
    error = nil
    status = ""
    do {
      let payload = CreateFixedPageBookmarkPayload(
        fileId: fileID, pageNumber: currentPage,
        title: title.trimmingCharacters(in: .whitespacesAndNewlines))
      let saved: BookmarkResponse = try await api.send(
        "books/\(bookID)/bookmarks/fixed-page", method: "POST", body: JSONEncoder().encode(payload))
      guard !isClosed else {
        isSaving = false
        return
      }
      guard saved.bookId == bookID, saved.fileId == fileID, saved.pageNumber == currentPage else {
        throw ConnectionError.invalidResponse
      }
      title = saved.title
      status = "Bookmarked page \(currentPage)."
      isSaving = false
      if await loadPage(nil) { previousCursors.removeAll() }
    } catch {
      if !isClosed { self.error = error.localizedDescription }
      isSaving = false
    }
  }

  func remove(_ bookmark: BookmarkResponse) async {
    guard !isBusy, !isClosed, items.contains(where: { $0.id == bookmark.id }) else { return }
    isSaving = true
    error = nil
    status = ""
    do {
      try await api.sendEmpty("books/\(bookID)/bookmarks/\(bookmark.id)", method: "DELETE")
      guard !isClosed else {
        isSaving = false
        return
      }
      items.removeAll { $0.id == bookmark.id }
      status = "Bookmark removed."
      isSaving = false
      if await loadPage(cursor), items.isEmpty, hasPrevious { await previousPage() }
    } catch {
      if !isClosed { self.error = error.localizedDescription }
      isSaving = false
    }
  }

  func close() { isClosed = true }

  @discardableResult
  private func loadPage(_ requested: Int?) async -> Bool {
    guard !isBusy, !isClosed else { return false }
    isLoading = true
    error = nil
    defer { isLoading = false }
    do {
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
      items = page.items
      nextCursor = page.nextCursor
      cursor = requested
      hasLoaded = true
      return true
    } catch is CancellationError {
      return false
    } catch {
      if !isClosed { self.error = error.localizedDescription }
      return false
    }
  }
}
