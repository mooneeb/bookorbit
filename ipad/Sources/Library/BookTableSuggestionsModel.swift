import Foundation
import Observation

@MainActor @Observable
final class BookTableSuggestionsModel {
  private let api: BookOrbitAPI
  private let endpoint: String
  private var requestID = UUID()
  private(set) var results: [CatalogSearchResult] = []
  private(set) var isLoading = false
  private(set) var error: String?
  private var selectedName: String?

  private init(api: BookOrbitAPI, endpoint: String) {
    self.api = api
    self.endpoint = endpoint
  }

  static func make(api: BookOrbitAPI, column: String) -> BookTableSuggestionsModel? {
    let endpoints = [
      "authors": "authors", "genres": "genres", "tags": "tags", "narrators": "narrators",
      "publisher": "publishers", "seriesName": "series", "language": "languages",
    ]
    guard let endpoint = endpoints[column] else { return nil }
    return .init(api: api, endpoint: endpoint)
  }

  func clear(selected: String? = nil) {
    selectedName = selected
    requestID = UUID()
    results = []
    error = nil
    isLoading = false
  }

  func load(query: String, immediately: Bool = false) async {
    let id = UUID()
    requestID = id
    results = []
    error = nil
    isLoading = false
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      selectedName = nil
      return
    }
    guard query != selectedName else { return }
    selectedName = nil
    guard query.utf16.count <= 500 else {
      error = "Suggestions accept at most 500 characters."
      return
    }
    do {
      if !immediately { try await Task.sleep(for: .milliseconds(250)) }
      try Task.checkCancellation()
      guard requestID == id else { return }
      isLoading = true
      defer { if requestID == id { isLoading = false } }
      let response: [CatalogSearchResult] = try await api.boundedJSON(
        "metadata/\(endpoint)", query: [URLQueryItem(name: "q", value: query)], byteLimit: 64 * 1024
      )
      try Task.checkCancellation()
      guard requestID == id else { return }
      guard response.count <= 15 else { throw ConnectionError.invalidResponse }
      var seen = Set<String>()
      results = response.filter { !$0.name.isEmpty && seen.insert($0.name).inserted }
    } catch {
      guard requestID == id, !Task.isCancelled else { return }
      self.error = "Suggestions could not be loaded. \(error.localizedDescription)"
    }
  }
}
