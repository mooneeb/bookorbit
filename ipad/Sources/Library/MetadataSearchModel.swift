import Foundation
import Observation

enum MetadataSearchEvent: Sendable {
  case candidate(MetadataCandidate)
  case status(MetadataProviderSearchStatus)
}

enum MetadataSearchError: LocalizedError {
  case limit, interrupted
  var errorDescription: String? {
    switch self {
    case .limit: "The search returned too much data. Narrow the title or choose fewer providers."
    case .interrupted: "The metadata search was interrupted. Retry to finish searching."
    }
  }
}

struct MetadataMatch: Identifiable {
  let candidate: MetadataCandidate
  var id: String { candidate.provider + ":" + candidate.providerId }
}

@MainActor @Observable
final class MetadataSearchModel {
  let api: BookOrbitAPI
  let bookID: Int
  var title: String
  var author: String
  var isbn: String
  var medium: String
  var providerID = ""
  var lookupProvider = ""
  var selectedProviders: Set<String> = []
  private(set) var providers: [MetadataProviderInfo] = []
  private(set) var matches: [MetadataMatch] = []
  private(set) var statuses: [String: String] = [:]
  private(set) var isSearching = false
  private(set) var isLoadingProviders = false
  private(set) var hasSearched = false
  var error: String?
  @ObservationIgnored private var searchTask: Task<Void, Never>?
  @ObservationIgnored private var operation = UUID()

  init(api: BookOrbitAPI, book: BookDetail) {
    self.api = api
    bookID = book.id
    title = book.title ?? ""
    author = book.authors.first?.name ?? ""
    isbn = book.isbn13 ?? book.isbn10 ?? ""
    medium = book.coverMedia == [.audio] ? "audiobook" : "ebook"
    if book.files.contains(where: { ["cbz", "cbr", "cb7"].contains($0.format ?? "") }) {
      medium = "comic"
    }
  }

  func loadProviders() async {
    guard !isLoadingProviders else { return }
    isLoadingProviders = true
    error = nil
    defer { isLoadingProviders = false }
    do {
      let available: [MetadataProviderInfo] = try await api.send(
        "metadata-fetch/providers", query: [URLQueryItem(name: "bookId", value: String(bookID))])
      providers = available
      selectedProviders = Set(available.filter { $0.selectedByFieldRules != false }.map(\.key))
      lookupProvider = available.first(where: \.identifiable)?.key ?? ""
    } catch { self.error = error.localizedDescription }
  }

  func search(only provider: String? = nil) {
    let requested = provider.map { [$0] } ?? selectedProviders.sorted()
    guard !requested.isEmpty else {
      error = "Choose at least one provider."
      return
    }
    guard title.count <= 500, author.count <= 255, isbn.count <= 30 else {
      error = "Use a title up to 500 characters, author up to 255, and ISBN up to 30."
      return
    }
    cancel()
    let current = operation
    hasSearched = true
    isSearching = true
    error = nil
    if let provider {
      statuses[provider] = nil
    } else {
      matches = []
      statuses = [:]
    }
    let query = [
      URLQueryItem(name: "bookId", value: String(bookID)),
      URLQueryItem(name: "title", value: title), URLQueryItem(name: "author", value: author),
      URLQueryItem(name: "isbn", value: isbn), URLQueryItem(name: "mediaKind", value: medium),
      URLQueryItem(name: "providers", value: requested.joined(separator: ",")),
    ]
    searchTask = Task { [weak self, api] in
      do {
        try await api.streamMetadata(query: query) { [weak self] event in
          guard let self, self.operation == current else { return }
          switch event {
          case .candidate(let candidate):
            let match = MetadataMatch(candidate: candidate)
            if let index = self.matches.firstIndex(where: { $0.id == match.id }) {
              self.matches[index] = match
            } else if self.matches.count < 100 {
              self.matches.append(match)
            }
          case .status(let status): self.statuses[status.provider] = status.outcome
          }
        }
      } catch {
        if !Task.isCancelled, self?.operation == current {
          self?.error = error.localizedDescription
        }
      }
      if self?.operation == current {
        self?.isSearching = false
        self?.searchTask = nil
      }
    }
  }

  func identify() {
    let identifier = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !lookupProvider.isEmpty, !identifier.isEmpty, identifier.count <= 255 else {
      error = "Choose a provider and enter its identifier, up to 255 characters."
      return
    }
    cancel()
    let current = operation
    isSearching = true
    hasSearched = true
    error = nil
    searchTask = Task { [weak self, api, lookupProvider] in
      do {
        let candidate: MetadataCandidate? = try await api.send(
          "metadata-fetch/lookup",
          query: [
            URLQueryItem(name: "provider", value: lookupProvider),
            URLQueryItem(name: "id", value: identifier),
          ])
        guard let self, self.operation == current else { return }
        self.matches = candidate.map { [MetadataMatch(candidate: $0)] } ?? []
      } catch {
        if !Task.isCancelled, self?.operation == current {
          self?.error = error.localizedDescription
        }
      }
      if self?.operation == current {
        self?.isSearching = false
        self?.searchTask = nil
      }
    }
  }

  func cancel() {
    operation = UUID()
    searchTask?.cancel()
    searchTask = nil
    isSearching = false
  }
}
