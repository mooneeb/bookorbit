import Foundation
import Observation

enum StoryGraphOperationError: LocalizedError {
  case message(String)
  var errorDescription: String? { if case .message(let value) = self { value } else { nil } }
}

@MainActor @Observable
final class StoryGraphSettingsModel {
  let api: BookOrbitAPI
  var sessionCookie = ""
  var rememberToken = ""
  var enabled = true
  var selectedOnly = true
  var autoStatus = false
  var autoProgress = false
  private(set) var settings: StorygraphSettings?
  private(set) var status: StorygraphActiveSyncStatus?
  private(set) var pending: StorygraphSyncPendingSummary?
  private(set) var failures: [StorygraphSyncFailure] = []
  private(set) var page: StorygraphLinkedBooksPage?
  private(set) var isBusy = false
  private(set) var isLoading = false
  private(set) var error: String?
  private(set) var message: String?
  private var cursors: [Int?] = [nil]

  init(api: BookOrbitAPI) { self.api = api }

  var pageNumber: Int { cursors.count }
  var isRunning: Bool { status?.status == "running" }
  var canSave: Bool {
    let cookie = sessionCookie.trimmingCharacters(in: .whitespacesAndNewlines)
    let token = rememberToken.trimmingCharacters(in: .whitespacesAndNewlines)
    return !isBusy && !isLoading && cookie.count <= 4096 && token.count <= 4096
      && ((!cookie.isEmpty && !token.isEmpty)
        || (settings?.cookiesConfigured == true && cookie.isEmpty && token.isEmpty))
  }

  func load() async {
    guard !isLoading else { return }
    isLoading = true
    error = nil
    defer { isLoading = false }
    do {
      let saved = try await api.storyGraphSettings()
      settings = saved
      enabled = saved.enabled
      selectedOnly = !saved.cookiesConfigured || saved.bookSyncMode == "selected_only"
      autoStatus = saved.cookiesConfigured && saved.autoSyncOnStatusChange
      autoProgress = saved.cookiesConfigured && saved.autoSyncOnProgressUpdate
      try await refreshResults()
      page = try await api.storyGraphBooks(after: cursors.last ?? nil)
    } catch {
      if !Task.isCancelled { self.error = error.localizedDescription }
    }
  }

  func observe() async {
    await load()
    while !Task.isCancelled {
      do { try await Task.sleep(for: .seconds(isRunning ? 2 : 15)) } catch { return }
      guard !isBusy else { continue }
      do { try await refreshResults() } catch {
        if !Task.isCancelled {
          self.error =
            "Could not refresh StoryGraph results. Reconnect and refresh. \(error.localizedDescription)"
        }
      }
    }
  }

  private func refreshResults() async throws {
    async let freshStatus = api.storyGraphStatus()
    async let freshPending: StorygraphSyncPendingSummary = api.boundedJSON(
      "storygraph/sync/pending", byteLimit: 32 * 1024)
    async let freshFailures: [StorygraphSyncFailure] = api.boundedJSON(
      "storygraph/sync/failures", byteLimit: 256 * 1024)
    let (job, summary, failed) = try await (freshStatus, freshPending, freshFailures)
    guard failed.count <= 100 else { throw ConnectionError.invalidResponse }
    status = job
    pending = summary
    failures = failed
  }

  func save() async {
    guard canSave else { return }
    await perform {
      let cookie = self.sessionCookie.trimmingCharacters(in: .whitespacesAndNewlines)
      let token = self.rememberToken.trimmingCharacters(in: .whitespacesAndNewlines)
      self.settings = try await self.api.saveStoryGraphSettings(
        UpsertStorygraphSettingsPayload(
          sessionCookie: cookie.isEmpty ? nil : cookie,
          rememberToken: token.isEmpty ? nil : token, enabled: self.enabled,
          bookSyncMode: self.selectedOnly ? "selected_only" : "all_eligible",
          autoSyncOnStatusChange: self.autoStatus, autoSyncOnProgressUpdate: self.autoProgress))
      self.sessionCookie = ""
      self.rememberToken = ""
      self.message = "StoryGraph settings saved. Validate the connection before syncing."
      try await self.refreshResults()
    }
  }

  func validate() async {
    await perform {
      let cookie = self.sessionCookie.trimmingCharacters(in: .whitespacesAndNewlines)
      let token = self.rememberToken.trimmingCharacters(in: .whitespacesAndNewlines)
      let payload = UpsertStorygraphSettingsPayload(
        sessionCookie: cookie.isEmpty ? nil : cookie, rememberToken: token.isEmpty ? nil : token,
        enabled: nil, bookSyncMode: nil, autoSyncOnStatusChange: nil, autoSyncOnProgressUpdate: nil)
      let result: StorygraphCookieValidationResult = try await self.api.boundedJSON(
        "storygraph/validate-cookies", method: "POST", body: JSONEncoder().encode(payload),
        byteLimit: 32 * 1024)
      if result.valid {
        self.message = "StoryGraph accepted the connection."
      } else {
        self.error =
          "StoryGraph could not validate these cookies. Check the connection or replace expired cookies, then try again."
      }
    }
  }

  func sync() async {
    await perform {
      let result: StorygraphSyncStartResult = try await self.api.boundedJSON(
        "storygraph/sync", method: "POST", byteLimit: 32 * 1024)
      guard result.runId > 0 else {
        throw StoryGraphOperationError.message(
          "StoryGraph sync is disabled. Save credentials and enable sync first.")
      }
      self.message = "Sync requested. Confirm the provider results below."
      try await self.refreshResults()
    }
  }

  func cancel() async {
    await perform {
      try await self.api.sendEmpty("storygraph/sync", method: "DELETE")
      self.message = "Cancellation requested. A provider request already in progress may finish."
      try await self.refreshResults()
    }
  }

  func disconnect() async {
    await perform {
      if self.isRunning { try await self.api.sendEmpty("storygraph/sync", method: "DELETE") }
      try await self.api.sendEmpty("storygraph/settings", method: "DELETE")
      self.sessionCookie = ""
      self.rememberToken = ""
      self.status = nil
      self.settings = try await self.api.storyGraphSettings()
      self.message = "StoryGraph credentials removed from the server."
      try await self.refreshResults()
    }
  }

  func nextPage() async {
    guard let cursor = page?.nextCursor else { return }
    await perform {
      let next = try await self.api.storyGraphBooks(after: cursor)
      self.cursors.append(cursor)
      self.page = next
    }
  }

  func previousPage() async {
    guard cursors.count > 1 else { return }
    await perform {
      let previous = try await self.api.storyGraphBooks(after: self.cursors[self.cursors.count - 2])
      self.cursors.removeLast()
      self.page = previous
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
