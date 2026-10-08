import Foundation
import Observation

@MainActor @Observable
final class OrganizationDetailModel {
  let api: BookOrbitAPI
  let kind: OrganizationKind
  let selection: OrganizationSelection
  let libraryID: Int?
  let seriesCollapse: SeriesCollapsePreferenceModel
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
  private var queriedCollapseSeries: Bool?
  private let pageSize = 40

  init(
    api: BookOrbitAPI, kind: OrganizationKind, selection: OrganizationSelection, libraryID: Int?,
    seriesCollapse: SeriesCollapsePreferenceModel? = nil
  ) {
    self.api = api
    self.kind = kind
    self.selection = selection
    self.libraryID = libraryID
    self.seriesCollapse = seriesCollapse ?? SeriesCollapsePreferenceModel(api: api)
    sort = kind == .authors ? "title" : "seriesIndex"
  }

  var canGoBack: Bool { page > 0 && !isBusy }
  var canGoNext: Bool { (page + 1) * pageSize < total && !isBusy }
  var collapseSeries: Bool { kind == .authors && seriesCollapse.effective(in: .authors) }
  func seriesCollapseChanged() async {
    if kind == .authors && queriedCollapseSeries != collapseSeries { await query(page: 0) }
  }
  func refreshBooks() async { await query(page: page) }
  func load() async { await query(page: 0) }
  func discardUnavailableBook(_ bookID: Int) {
    requestID = UUID()
    books.removeAll { $0.id == bookID }
  }
  func refreshAfterBookMutation() async {
    await query(page: page)
    if error == nil, books.isEmpty, page > 0 {
      let lastPage = max(0, (total - 1) / pageSize)
      if page > lastPage { await query(page: lastPage) }
    }
  }
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
      if kind == .authors && !seriesCollapse.isLoaded { await seriesCollapse.reconcile() }
      let session = try await api.authenticatedSessionGeneration()
      try Task.checkCancellation()
      guard requestID == id else { return }
      let collapseSeries = self.collapseSeries
      if kind == .authors {
        if author == nil {
          let result: AuthorDetail = try await api.boundedJSON(
            "authors/\(selection.id)", session: session)
          guard requestID == id else { return }
          author = result
        }
        parameters.append(
          URLQueryItem(name: "collapseSeries", value: collapseSeries ? "true" : "false"))
        let result: AuthorBooksPage = try await api.boundedJSON(
          "authors/\(selection.id)/books", query: parameters, session: session)
        try Task.checkCancellation()
        guard requestID == id else { return }
        guard result.items.count <= pageSize, result.page == page, result.total >= 0 else {
          throw ConnectionError.invalidResponse
        }
        books = result.items
        total = result.total
        self.page = result.page
        queriedCollapseSeries = collapseSeries
      } else {
        let result: SeriesBooksPage = try await api.boundedJSON(
          "series/\(selection.id)/books", query: parameters, session: session)
        try Task.checkCancellation()
        guard requestID == id else { return }
        guard result.items.count <= pageSize, result.page == page, result.total >= 0,
          result.seriesInfo.id == selection.id
        else { throw ConnectionError.invalidResponse }
        books = result.items
        series = result.seriesInfo
        total = result.total
        self.page = result.page
      }
    } catch {
      guard requestID == id, !Task.isCancelled else { return }
      self.error = error.localizedDescription
    }
  }
}
