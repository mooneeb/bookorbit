import Foundation
import Observation

@MainActor @Observable
final class LibraryModel {
  let api: BookOrbitAPI
  private(set) var libraries: [Library] = []
  private(set) var books: [BookCard] = []
  private(set) var total = 0
  private(set) var page = 0
  private(set) var isBusy = false
  var error: String?
  var search = ""
  var sort = "title"
  var libraryID: Int?
  private var requestID = UUID()
  let pageSize = 40

  init(api: BookOrbitAPI) { self.api = api }

  var canGoNext: Bool { (page + 1) * pageSize < total && !isBusy }
  var canGoBack: Bool { page > 0 && !isBusy }

  func load() async {
    do {
      let result: [Library] = try await api.send("libraries")
      libraries = result.filter { $0.type == "books" }
      await query(page: 0)
    } catch { self.error = error.localizedDescription }
  }

  func searchBooks() async { await query(page: 0) }
  func nextPage() async { if canGoNext { await query(page: page + 1) } }
  func previousPage() async { if canGoBack { await query(page: page - 1) } }

  private func query(page: Int) async {
    let id = UUID()
    requestID = id
    isBusy = true
    error = nil
    defer { if requestID == id { isBusy = false } }
    do {
      let query = BookQuery(
        sort: [SortSpec(field: sort, dir: sort == "addedAt" ? "desc" : "asc")],
        pagination: BookQueryPagination(page: page, size: pageSize), q: search,
        collapseSeries: false)
      let path = libraryID.map { "libraries/\($0)/books" } ?? "books/query"
      let result: BooksPage = try await api.send(
        path, method: "POST", body: JSONEncoder().encode(query))
      guard requestID == id else { return }
      books = result.items
      total = result.total
      self.page = result.page
    } catch {
      guard requestID == id else { return }
      self.error = error.localizedDescription
    }
  }
}
