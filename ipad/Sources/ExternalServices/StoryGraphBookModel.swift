import Foundation
import Observation

@MainActor @Observable
final class StoryGraphBookModel {
  let api: BookOrbitAPI
  let bookID: Int
  let title: String
  var input = ""
  var selected = false
  private(set) var state: StorygraphBookSyncState?
  private(set) var editions: [StorygraphEdition] = []
  private(set) var isBusy = false
  private(set) var isLoading = false
  private(set) var error: String?
  private(set) var message: String?

  init(api: BookOrbitAPI, bookID: Int, title: String) {
    self.api = api
    self.bookID = bookID
    self.title = title
  }

  var canLink: Bool {
    !isBusy && input.trimmingCharacters(in: .whitespacesAndNewlines).count > 0
      && input.count <= 2048
  }

  func load() async {
    guard !isLoading else { return }
    isLoading = true
    error = nil
    defer { isLoading = false }
    do {
      let settings = try await api.storyGraphSettings()
      let fresh = try await api.storyGraphBookState(bookID)
      state = fresh
      selected =
        fresh.syncOverride == "included"
        || (settings.bookSyncMode == "all_eligible" && fresh.syncOverride != "excluded")
    } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
  }

  func saveSelection() async {
    await perform {
      let saved: StorygraphBookSyncState = try await self.api.boundedJSON(
        "storygraph/books/\(self.bookID)/sync-state", method: "PATCH",
        body: JSONEncoder().encode(UpdateStorygraphBookSyncPayload(syncEnabled: self.selected)),
        byteLimit: 32 * 1024)
      guard saved.bookId == self.bookID else { throw ConnectionError.invalidResponse }
      self.state = saved
      self.message =
        self.selected
        ? "Book included in StoryGraph sync."
        : "Book excluded from StoryGraph sync. Existing StoryGraph entries remain there."
    }
  }

  func sync() async {
    await perform {
      let outcome: StorygraphBookSyncNowResult = try await self.api.boundedJSON(
        "storygraph/books/\(self.bookID)/sync", method: "POST", byteLimit: 32 * 1024)
      guard outcome.state.bookId == self.bookID else { throw ConnectionError.invalidResponse }
      self.state = outcome.state
      self.report(outcome.result)
    }
  }

  func rematch() async {
    await perform {
      let outcome: StorygraphRematchResult = try await self.api.boundedJSON(
        "storygraph/books/\(self.bookID)/rematch", method: "POST", byteLimit: 32 * 1024)
      self.state = try await self.api.storyGraphBookState(self.bookID)
      self.report(outcome.result)
    }
  }

  func link() async {
    guard canLink else { return }
    await perform {
      let result: StorygraphLinkResult = try await self.api.boundedJSON(
        "storygraph/books/\(self.bookID)/link", method: "PATCH",
        body: JSONEncoder().encode(
          StorygraphLinkPayload(input: self.input.trimmingCharacters(in: .whitespacesAndNewlines))),
        byteLimit: 32 * 1024)
      guard result.success else {
        throw StoryGraphOperationError.message(
          "The StoryGraph book could not be linked. Check the URL, connection, and saved cookies.")
      }
      self.state = try await self.api.storyGraphBookState(self.bookID)
      self.message = "StoryGraph match saved. Review the sync outcome below."
      self.editions = []
    }
  }

  func loadEditions() async {
    await perform {
      let results: [StorygraphEdition] = try await self.api.boundedJSON(
        "storygraph/books/\(self.bookID)/editions", byteLimit: 512 * 1024)
      guard results.count <= 200 else { throw ConnectionError.responseTooLarge }
      self.editions = results
      if results.isEmpty {
        self.message =
          "No editions are available. Link a StoryGraph book and check the connection first."
      }
    }
  }

  func chooseEdition(_ edition: StorygraphEdition) async {
    await perform {
      let result: StorygraphActionResult = try await self.api.boundedJSON(
        "storygraph/books/\(self.bookID)/edition", method: "PATCH",
        body: JSONEncoder().encode(StorygraphEditionPayload(editionId: edition.id)),
        byteLimit: 32 * 1024)
      guard result.success else {
        throw StoryGraphOperationError.message(
          "StoryGraph did not confirm the edition change. Try again after checking the connection.")
      }
      self.state = try await self.api.storyGraphBookState(self.bookID)
      self.message = "StoryGraph edition selected. Review the sync outcome below."
    }
  }

  private func report(_ result: String) {
    switch result {
    case "synced": message = "StoryGraph accepted the reading status and supported progress."
    case "skipped":
      message =
        "No record transferred. The book is unchanged, excluded, unread, or could not be matched."
    default:
      error =
        "StoryGraph did not confirm this transfer. Check the sync error and connection, then retry."
    }
  }

  private func perform(_ operation: () async throws -> Void) async {
    guard !isBusy else { return }
    isBusy = true
    error = nil
    message = nil
    defer { isBusy = false }
    do { try await operation() } catch {
      if !Task.isCancelled { self.error = error.localizedDescription }
    }
  }
}
