import Foundation
import Observation

@MainActor @Observable
final class EPUBBookmarksModel {
  let api: BookOrbitAPI
  let bookID: Int
  let cfi: String
  var title: String
  private(set) var items: [BookmarkResponse] = []
  private(set) var nextCursor: Int?
  private(set) var hasLoaded = false
  private(set) var isLoading = false
  private(set) var isSaving = false
  private(set) var error: String?
  private(set) var status: String?
  private var generation: UUID?
  private var cursor: Int?
  private var previousCursors: [Int?] = []
  private var pendingTitle: String?
  private var isClosed = false

  init(api: BookOrbitAPI, bookID: Int, cfi: String, title: String) {
    self.api = api
    self.bookID = bookID
    self.cfi = cfi
    self.title = title
  }
  var isBusy: Bool { isLoading || isSaving }
  var hasPendingSave: Bool { pendingTitle != nil }
  var hasPrevious: Bool { !previousCursors.isEmpty }
  var canSave: Bool {
    hasLoaded && !isBusy && !isClosed && cfi.hasPrefix("epubcfi(") && cfi.utf16.count <= 2000
      && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.utf16.count <= 500
  }

  func load() async { await loadPage(cursor) }
  func nextPage() async {
    guard !isBusy, !hasPendingSave, let nextCursor else { return }
    let old = cursor
    if await loadPage(nextCursor) {
      previousCursors.append(old)
      if previousCursors.count > 32 { previousCursors.removeFirst() }
    }
  }
  func previousPage() async {
    guard !isBusy, !hasPendingSave, let previous = previousCursors.last else { return }
    if await loadPage(previous) { previousCursors.removeLast() }
  }
  func firstPage() async {
    guard !isBusy, !hasPendingSave else { return }
    if await loadPage(nil) { previousCursors = [] }
  }
  func save() async {
    guard canSave, let generation else { return }
    isSaving = true
    error = nil
    status = nil
    defer { isSaving = false }
    do {
      let frozen = pendingTitle ?? title.trimmingCharacters(in: .whitespacesAndNewlines)
      pendingTitle = frozen
      let payload = CreateEpubBookmarkPayload(cfi: cfi, title: frozen)
      let saved: BookmarkResponse = try await api.boundedJSON(
        "books/\(bookID)/bookmarks", method: "POST",
        body: JSONEncoder().encode(payload), session: generation)
      guard !isClosed, saved.bookId == bookID, saved.cfi == cfi, saved.id > 0,
        saved.fileId == nil, saved.pageNumber == nil, saved.positionSeconds == nil
      else { throw ConnectionError.invalidResponse }
      title = saved.title
      pendingTitle = nil
      status = "Passage bookmarked."
    } catch {
      if !isClosed {
        self.error =
          "The bookmark could not be confirmed. Retry Save. \(error.localizedDescription)"
      }
    }
    isSaving = false
    if !hasPendingSave, await loadPage(nil) { previousCursors = [] }
  }
  func remove(_ bookmark: BookmarkResponse) async {
    guard !isBusy, !hasPendingSave, !isClosed, let generation,
      items.contains(where: { $0.id == bookmark.id })
    else { return }
    isSaving = true
    error = nil
    defer { isSaving = false }
    do {
      try await api.sendEmpty(
        "books/\(bookID)/bookmarks/\(bookmark.id)", method: "DELETE", session: generation)
      guard !isClosed else { return }
      items.removeAll { $0.id == bookmark.id }
      status = "Bookmark removed."
    } catch { if !isClosed { self.error = error.localizedDescription } }
  }
  func close() { isClosed = true }

  @discardableResult private func loadPage(_ requested: Int?) async -> Bool {
    guard !isBusy, !isClosed else { return false }
    isLoading = true
    error = nil
    defer { isLoading = false }
    do {
      let session = try await api.authenticatedSessionGeneration()
      if let generation, generation != session { throw ConnectionError.expiredSession }
      generation = session
      var query = [URLQueryItem(name: "limit", value: "40")]
      if let requested { query.append(.init(name: "beforeId", value: String(requested))) }
      let page: BookmarksPage = try await api.boundedJSON(
        "books/\(bookID)/bookmarks/epub-page", query: query, session: session)
      guard !isClosed, page.items.count <= 40,
        page.items.allSatisfy({
          $0.bookId == bookID && $0.id > 0 && $0.cfi?.hasPrefix("epubcfi(") == true
            && ($0.cfi?.utf16.count ?? 2001) <= 2000 && $0.fileId == nil && $0.pageNumber == nil
            && $0.positionSeconds == nil
        }),
        page.nextCursor == nil || page.nextCursor == page.items.last?.id,
        requested == nil || page.items.allSatisfy({ $0.id < requested! })
      else { throw ConnectionError.invalidResponse }
      items = page.items
      nextCursor = page.nextCursor
      cursor = requested
      hasLoaded = true
      return true
    } catch {
      if !isClosed { self.error = error.localizedDescription }
      return false
    }
  }
}
