import Foundation
import Observation

@MainActor @Observable
final class BookRequestsModel {
  let api: BookOrbitAPI
  private(set) var items: [BookRequestItem] = []
  private(set) var total = 0
  private(set) var page = 1
  private(set) var isBusy = false
  var status = ""
  var error: String?
  var selectedID: Int?
  var title = ""
  var author = ""
  var isbn = ""
  var medium = "ebook"
  var selfServe = false
  var libraryID = 0
  var libraries: [Library] = []
  var availability: BookRequestAvailability?
  var matches: [MetadataMatch] = []
  var isDiscovering = false
  private var chosenMetadata: MetadataCandidate?
  var providerStatuses: [String: String] = [:]
  private var revision = UUID()
  @ObservationIgnored private var discovery: Task<Void, Never>?

  init(api: BookOrbitAPI) { self.api = api }

  func load(page: Int = 1) async {
    guard !isBusy else { return }
    await perform {
      let response = try await self.api.requests(page: page, status: self.status)
      self.items = response.items
      self.total = response.total
      self.page = page
    }
  }

  func loadDestinations() async {
    do { libraries = try await api.send("libraries") } catch {
      self.error = error.localizedDescription
    }
  }

  func checkAvailability() async {
    await perform {
      let result = try await self.api.requestAvailability(
        BookRequestAvailabilityQuery(
          isbn13: self.isbn.isEmpty ? nil : self.isbn, title: self.title,
          author: self.author.isEmpty ? nil : self.author, mediaKind: self.medium, providerKey: nil,
          providerId: nil))
      self.availability = result.first
    }
  }

  func submit() async {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      error = "Enter a book title."
      return
    }
    guard title.count <= 500, author.count <= 255, isbn.count <= 20 else {
      error = "Shorten the title, author, or ISBN before submitting."
      return
    }
    await perform {
      var body = CreateBookRequestPayload(
        title: self.title.trimmingCharacters(in: .whitespacesAndNewlines), mediaKind: self.medium)
      body.targetLibraryId = self.libraryID > 0 ? self.libraryID : nil
      body.authors = self.author.isEmpty ? nil : [self.author]
      body.isbn13 = self.isbn.isEmpty ? nil : self.isbn
      body.selfServe = self.selfServe
      if let candidate = self.chosenMetadata, candidate.title == self.title {
        body.providerKey = candidate.provider
        body.providerId = candidate.providerId
        body.isbn10 = candidate.isbn10
        body.coverUrl = candidate.coverUrl
        body.language = candidate.language
        body.publishedYear = candidate.publishedYear
        body.subtitle = candidate.subtitle
        body.seriesName = candidate.seriesName
      }
      let result = try await self.api.submitRequest(body)
      self.selectedID = result.request.id
    }
  }

  func discover() {
    guard !title.isEmpty || !isbn.isEmpty else {
      error = "Enter a title or ISBN to discover a book."
      return
    }
    stopDiscovery()
    matches = []
    isDiscovering = true
    providerStatuses = [:]
    error = nil
    let current = revision
    discovery = Task {
      do {
        try await api.streamMetadata(query: [
          URLQueryItem(name: "title", value: title), URLQueryItem(name: "author", value: author),
          URLQueryItem(name: "isbn", value: isbn), URLQueryItem(name: "mediaKind", value: medium),
        ]) { [weak self] event in
          guard let self, self.revision == current else { return }
          switch event {
          case .candidate(let candidate):
            let match = MetadataMatch(candidate: candidate)
            if self.matches.count < 100 && !self.matches.contains(where: { $0.id == match.id }) {
              self.matches.append(match)
            }
          case .status(let status): self.providerStatuses[status.provider] = status.outcome
          }
        }
      } catch {
        if revision == current, !Task.isCancelled { self.error = error.localizedDescription }
      }
      if revision == current {
        discovery = nil
        isDiscovering = false
      }
    }
  }

  func choose(_ match: MetadataMatch) {
    stopDiscovery()
    chosenMetadata = match.candidate
    title = match.candidate.title ?? title
    author = match.candidate.authors?.first ?? author
    isbn = match.candidate.isbn13 ?? ""
    availability = nil
  }

  func stopDiscovery() {
    revision = UUID()
    discovery?.cancel()
    discovery = nil
    isDiscovering = false
  }

  private func perform(_ work: () async throws -> Void) async {
    guard !isBusy else { return }
    isBusy = true
    error = nil
    defer { isBusy = false }
    do { try await work() } catch { self.error = error.localizedDescription }
  }
}
