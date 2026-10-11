import Foundation

extension BookOrbitAPI {
  func storyGraphSettings() async throws -> StorygraphSettings {
    try await boundedJSON("storygraph/settings", byteLimit: 32 * 1024)
  }

  func saveStoryGraphSettings(_ payload: UpsertStorygraphSettingsPayload) async throws
    -> StorygraphSettings
  {
    try await boundedJSON(
      "storygraph/settings", method: "PATCH", body: JSONEncoder().encode(payload),
      byteLimit: 32 * 1024)
  }

  func storyGraphStatus() async throws -> StorygraphActiveSyncStatus? {
    try await boundedJSON("storygraph/sync/status", byteLimit: 32 * 1024)
  }

  func storyGraphBooks(after cursor: Int? = nil) async throws -> StorygraphLinkedBooksPage {
    let query = cursor.map { [URLQueryItem(name: "afterBookId", value: String($0))] } ?? []
    let page: StorygraphLinkedBooksPage = try await boundedJSON(
      "storygraph/books/page", query: query, byteLimit: 256 * 1024)
    guard page.items.count <= 40,
      cursor.map({ previous in page.items.allSatisfy { $0.bookId > previous } }) ?? true,
      page.nextCursor == nil || page.nextCursor == page.items.last?.bookId
    else { throw ConnectionError.invalidResponse }
    return page
  }

  func storyGraphBookState(_ bookID: Int) async throws -> StorygraphBookSyncState {
    let state: StorygraphBookSyncState = try await boundedJSON(
      "storygraph/books/\(bookID)/sync-state", byteLimit: 32 * 1024)
    guard state.bookId == bookID else { throw ConnectionError.invalidResponse }
    return state
  }
}
