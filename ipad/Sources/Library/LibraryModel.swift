import Foundation
import Observation

@MainActor @Observable
final class LibraryModel {
  let api: BookOrbitAPI
  let collections: CollectionModel
  private(set) var libraries: [Library] = []
  private(set) var books: [BookCard] = []
  private(set) var total = 0
  private(set) var page = 0
  private(set) var isBusy = false
  var error: String?
  var search = ""
  var sort = "title"
  var descending = false
  var secondarySort: [SortSpec] = []
  private(set) var filter: GroupRule?
  private(set) var location = BookLocation.all
  private var requestID = UUID()
  let pageSize = 40
  private var randomSeed = Int.random(in: 0...Int(Int32.max))

  init(api: BookOrbitAPI) {
    self.api = api
    collections = CollectionModel(api: api)
  }

  var canGoNext: Bool { (page + 1) * pageSize < total && !isBusy }
  var canGoBack: Bool { page > 0 && !isBusy }

  func load() async {
    do {
      let result: [Library] = try await api.send("libraries")
      libraries = result.filter { $0.type == "books" }
      await collections.load()
      await query(page: 0)
    } catch { self.error = error.localizedDescription }
  }

  func searchBooks() async { await query(page: 0) }
  func chooseSort(_ field: String) async {
    sort = field
    descending = field == "addedAt"
    secondarySort = []
    randomSeed = Int.random(in: 0...Int(Int32.max))
    await query(page: 0)
  }
  func refreshBooks() async { await query(page: page) }
  func collectionUpdated(_ collection: BookCollection) {
    if case .collection(let id, _) = location, id == collection.id {
      location = .collection(id: collection.id, name: collection.name)
    }
  }
  func collectionDeleted(_ collectionID: Int) async {
    if case .collection(let id, _) = location, id == collectionID { await select(.all) }
  }
  func select(_ location: BookLocation) async {
    self.location = location
    search = ""
    filter = nil
    secondarySort = []
    if case .scope(_, _, let defaultSort) = location, let first = defaultSort.first {
      sort = first.field
      descending = first.dir == "desc"
      secondarySort = Array(defaultSort.dropFirst().prefix(4))
    } else {
      sort = "title"
      descending = false
    }
    randomSeed = Int.random(in: 0...Int(Int32.max))
    await query(page: 0)
  }
  func apply(filter: GroupRule?, sort: [SortSpec]) async {
    self.filter = filter
    if let first = sort.first {
      self.sort = first.field
      descending = first.dir == "desc"
    }
    secondarySort = Array(sort.dropFirst().prefix(4))
    randomSeed = Int.random(in: 0...Int(Int32.max))
    await query(page: 0)
  }
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
        filter: filter,
        sort: [SortSpec(field: sort, dir: descending ? "desc" : "asc")] + secondarySort,
        pagination: BookQueryPagination(page: page, size: pageSize), q: search,
        collapseSeries: false,
        randomSeed: sort == "random" || secondarySort.contains { $0.field == "random" }
          ? randomSeed : nil)
      let path = location.queryPath
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

enum BookLocation {
  case all
  case library(id: Int, name: String)
  case collection(id: Int, name: String)
  case scope(id: Int, name: String, sort: [SortSpec])

  var title: String {
    switch self {
    case .all: "Books"
    case .library(_, let name), .collection(_, let name), .scope(_, let name, _): name
    }
  }

  var queryPath: String {
    switch self {
    case .all: "books/query"
    case .library(let id, _): "libraries/\(id)/books"
    case .collection(let id, _): "collections/\(id)/books/query"
    case .scope(let id, _, _): "smart-scopes/\(id)/books/query"
    }
  }

  var storageKey: String {
    switch self {
    case .all: "all"
    case .library(let id, _): "library:\(id)"
    case .collection(let id, _): "collection:\(id)"
    case .scope(let id, _, _): "scope:\(id)"
    }
  }
}
