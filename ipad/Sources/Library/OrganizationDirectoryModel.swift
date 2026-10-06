import Foundation
import Observation

enum OrganizationKind: String, Identifiable {
  case authors, series
  var id: String { rawValue }
  var title: String { self == .authors ? "Authors" : "Series" }
  var sorts: [(value: String, title: String)] {
    if self == .authors {
      return [
        ("name", "Name"), ("sortName", "Sort name"), ("bookCount", "Book count"),
        ("lastAddedAt", "Recently added"), ("lastEnrichedAt", "Recently enriched"),
      ]
    }
    return [
      ("name", "Name"), ("bookCount", "Book count"),
      ("lastAddedAt", "Recently added"), ("readProgress", "Reading progress"),
    ]
  }
}

struct OrganizationSelection: Identifiable, Hashable {
  let id: Int
  let name: String
}

struct OrganizationFilters {
  var libraryID: Int?
  var completion = ""
  var author = ""
  var photo = ""
  var sortName = ""
  var multipleBooks = false
  var recent = false
}

@MainActor @Observable
final class OrganizationDirectoryModel {
  let api: BookOrbitAPI
  let kind: OrganizationKind
  private(set) var authors: [AuthorSummary] = []
  private(set) var series: [SeriesSummary] = []
  private(set) var total = 0
  private(set) var page = 0
  private(set) var isBusy = false
  var search = ""
  var sort = "name"
  var descending = false
  var filters = OrganizationFilters()
  var error: String?
  private var requestID = UUID()
  private let pageSize = 40

  init(api: BookOrbitAPI, kind: OrganizationKind) {
    self.api = api
    self.kind = kind
  }

  var canGoBack: Bool { page > 0 && !isBusy }
  var canGoNext: Bool { (page + 1) * pageSize < total && !isBusy }
  func load() async { await query(page: 0) }
  func previousPage() async { if canGoBack { await query(page: page - 1) } }
  func nextPage() async { if canGoNext { await query(page: page + 1) } }

  private func query(page: Int) async {
    let id = UUID()
    requestID = id
    isBusy = true
    error = nil
    defer { if requestID == id { isBusy = false } }
    var parameters = [
      URLQueryItem(name: "page", value: String(page)),
      URLQueryItem(name: "size", value: String(pageSize)),
      URLQueryItem(name: "q", value: search),
      URLQueryItem(name: "sort", value: sort),
      URLQueryItem(name: "order", value: descending ? "desc" : "asc"),
    ]
    if let libraryID = filters.libraryID {
      parameters.append(URLQueryItem(name: "libraryId", value: String(libraryID)))
    }
    if kind == .authors {
      if !filters.photo.isEmpty {
        parameters.append(URLQueryItem(name: "hasPhoto", value: filters.photo))
      }
      if !filters.sortName.isEmpty {
        parameters.append(URLQueryItem(name: "hasSortName", value: filters.sortName))
      }
      if filters.multipleBooks { parameters.append(URLQueryItem(name: "minBookCount", value: "2")) }
      if filters.recent { parameters.append(URLQueryItem(name: "addedWithinDays", value: "30")) }
    } else {
      if !filters.completion.isEmpty {
        parameters.append(URLQueryItem(name: "completionStatus", value: filters.completion))
      }
      if !filters.author.isEmpty {
        parameters.append(URLQueryItem(name: "author", value: filters.author))
      }
    }
    do {
      if kind == .authors {
        let result: AuthorsPage = try await api.send("authors", query: parameters)
        guard requestID == id else { return }
        authors = result.items
        total = result.total
        self.page = result.page
      } else {
        let result: SeriesPage = try await api.send("series", query: parameters)
        guard requestID == id else { return }
        series = result.items
        total = result.total
        self.page = result.page
      }
    } catch {
      guard requestID == id else { return }
      self.error = error.localizedDescription
    }
  }
}
