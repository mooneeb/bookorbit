import Foundation
import Observation

@MainActor @Observable
final class MetadataDraftSuggestionsModel {
  private let api: BookOrbitAPI
  private let scope: MetadataDraftSuggestionScope
  private let isCurrent: @MainActor () -> Bool
  private var session: UUID?
  private var requestID = UUID()
  private var searchQuery = ""
  private var requestTask: Task<Void, Never>?
  private var isClosed = false
  private(set) var results: [String] = []
  private(set) var isLoading = false
  private(set) var isChoosing = false
  private(set) var hasSearched = false
  private(set) var error: String?

  init(
    api: BookOrbitAPI, scope: MetadataDraftSuggestionScope,
    isCurrent: @escaping @MainActor () -> Bool
  ) {
    self.api = api
    self.scope = scope
    self.isCurrent = isCurrent
  }

  func search(query: String, immediately: Bool = false) {
    let previous = requestTask
    previous?.cancel()
    let id = UUID()
    requestID = id
    results = []
    error = nil
    isLoading = false
    hasSearched = false
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    searchQuery = query
    guard !isClosed, isCurrent(), !query.isEmpty else { return }
    guard query.utf16.count <= 500 else {
      error = "Search accepts at most 500 characters."
      return
    }
    isLoading = true
    requestTask = Task {
      await previous?.value
      await load(query: query, id: id, immediately: immediately)
    }
  }

  func selectedValue(_ name: String, query: String) async -> String? {
    guard !isClosed, !isLoading, !isChoosing, isCurrent(), results.contains(name),
      query.trimmingCharacters(in: .whitespacesAndNewlines) == searchQuery, let session
    else { return nil }
    let id = requestID
    isChoosing = true
    defer { isChoosing = false }
    do {
      try Task.checkCancellation()
      guard try await api.authenticatedSessionGeneration() == session else {
        throw ConnectionError.expiredSession
      }
      try Task.checkCancellation()
      guard !isClosed, requestID == id, isCurrent(), results.contains(name) else { return nil }
      return name
    } catch {
      guard !isClosed, requestID == id, !Task.isCancelled, isCurrent() else { return nil }
      results = []
      self.error = "This value could not be selected. \(error.localizedDescription)"
      return nil
    }
  }

  func close() {
    isClosed = true
    requestID = UUID()
    requestTask?.cancel()
    requestTask = nil
    results = []
    error = nil
    isLoading = false
  }

  private func load(query: String, id: UUID, immediately: Bool) async {
    do {
      try Task.checkCancellation()
      if !immediately { try await Task.sleep(for: .milliseconds(250)) }
      try Task.checkCancellation()
      guard !isClosed, requestID == id, isCurrent(), scope.bookID > 0 else { return }
      let generation = try await api.authenticatedSessionGeneration()
      try Task.checkCancellation()
      guard !isClosed, requestID == id, isCurrent() else { return }
      if let session, generation != session { throw ConnectionError.expiredSession }
      session = generation
      let response: [CatalogSearchResult] = try await api.boundedJSON(
        "metadata/\(scope.field.endpoint)", query: [URLQueryItem(name: "q", value: query)],
        byteLimit: 64 * 1024, session: generation, expectedStatus: 200)
      try Task.checkCancellation()
      guard try await api.authenticatedSessionGeneration() == generation else {
        throw ConnectionError.expiredSession
      }
      try Task.checkCancellation()
      guard !isClosed, requestID == id, isCurrent() else { return }
      guard response.count <= 15 else { throw ConnectionError.invalidResponse }
      var seen = Set<String>()
      var names: [String] = []
      for result in response {
        let name = result.name
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          name.unicodeScalars.count <= scope.field.maximumNameLength,
          !name.contains(where: { $0.isNewline })
        else { throw ConnectionError.invalidResponse }
        if seen.insert(name).inserted { names.append(name) }
      }
      results = names
      hasSearched = true
    } catch {
      guard !isClosed, requestID == id, !Task.isCancelled, isCurrent() else { return }
      self.error = "Existing values could not be loaded. \(error.localizedDescription)"
    }
    if !isClosed, requestID == id { isLoading = false }
  }
}
