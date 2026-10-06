import Foundation
import Observation

@MainActor @Observable
final class OrganizationDetailModel {
  let api: BookOrbitAPI
  let kind: OrganizationKind
  let selection: OrganizationSelection
  let libraryID: Int?
  private(set) var author: AuthorDetail?
  private(set) var series: SeriesDetail?
  private(set) var books: [BookCard] = []
  private(set) var total = 0
  private(set) var page = 0
  private(set) var isBusy = false
  var sort: String
  var descending = false
  var error: String?
  private var requestID = UUID()
  private let pageSize = 40

  init(api: BookOrbitAPI, kind: OrganizationKind, selection: OrganizationSelection, libraryID: Int?)
  {
    self.api = api
    self.kind = kind
    self.selection = selection
    self.libraryID = libraryID
    sort = kind == .authors ? "title" : "seriesIndex"
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
      URLQueryItem(name: "sort", value: sort),
      URLQueryItem(name: "order", value: descending ? "desc" : "asc"),
    ]
    if let libraryID {
      parameters.append(URLQueryItem(name: "libraryId", value: String(libraryID)))
    }
    do {
      if kind == .authors {
        if author == nil {
          let result: AuthorDetail = try await api.send("authors/\(selection.id)")
          guard requestID == id else { return }
          author = result
        }
        parameters.append(URLQueryItem(name: "collapseSeries", value: "false"))
        let result: AuthorBooksPage = try await api.send(
          "authors/\(selection.id)/books", query: parameters)
        guard requestID == id else { return }
        books = result.items
        total = result.total
        self.page = result.page
      } else {
        let result: SeriesBooksPage = try await api.send(
          "series/\(selection.id)/books", query: parameters)
        guard requestID == id else { return }
        books = result.items
        series = result.seriesInfo
        total = result.total
        self.page = result.page
      }
    } catch {
      guard requestID == id else { return }
      self.error = error.localizedDescription
    }
  }
}
