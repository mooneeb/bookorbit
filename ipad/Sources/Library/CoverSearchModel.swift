import Foundation
import Observation

struct CoverSearchMatch: Identifiable {
  let result: CoverSearchResult
  var id: String { url }
  var url: String {
    switch result.url {
    case .string(let value): value
    case .number(let value): String(value)
    }
  }
  var isDownloadable: Bool {
    guard let url = URL(string: url) else { return false }
    return ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
  }
}

@MainActor @Observable
final class CoverSearchModel {
  let api: BookOrbitAPI
  var title: String
  var author: String
  var provider = "all"
  var isAudiobook: Bool
  private(set) var results: [CoverSearchMatch] = []
  private(set) var isSearching = false
  private(set) var hasSearched = false
  var error: String?
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var operation = UUID()

  init(api: BookOrbitAPI, book: BookDetail, medium: CoverMedium) {
    self.api = api
    title = book.title ?? ""
    author = book.authors.first?.name ?? ""
    isAudiobook = medium == .audio
  }

  func search() {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty, title.count <= 500, author.count <= 255 else {
      error = "Enter a title up to 500 characters and author up to 255 characters."
      return
    }
    cancel()
    let current = operation
    isSearching = true
    hasSearched = true
    error = nil
    results = []
    let query = [
      URLQueryItem(name: "title", value: title), URLQueryItem(name: "author", value: author),
      URLQueryItem(name: "isAudiobook", value: String(isAudiobook)),
      URLQueryItem(name: "provider", value: provider),
    ]
    task = Task { [weak self, api] in
      do {
        let matches: [CoverSearchResult] = try await api.send("books/cover/search", query: query)
        guard let self, self.operation == current else { return }
        var seen = Set<String>()
        self.results = matches.prefix(100).map(CoverSearchMatch.init).filter {
          seen.insert($0.id).inserted
        }
      } catch {
        if !Task.isCancelled, self?.operation == current {
          self?.error = error.localizedDescription
        }
      }
      if self?.operation == current {
        self?.isSearching = false
        self?.task = nil
      }
    }
  }

  func cancel() {
    operation = UUID()
    task?.cancel()
    task = nil
    isSearching = false
  }
}
