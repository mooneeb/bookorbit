import Foundation
import Observation

@MainActor @Observable
final class LibraryModel {
  let api: BookOrbitAPI
  let collections: CollectionModel
  let seriesCollapse: SeriesCollapsePreferenceModel
  private(set) var libraries: [Library] = []
  private(set) var customFields: [CustomMetadataFieldSummary] = []
  private(set) var isLoadingCustomFields = false
  private(set) var customFieldsError: String?
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
  private var queriedCollapseSeries: Bool?
  let pageSize = 40
  private var randomSeed = Int.random(in: 0...Int(Int32.max))

  init(api: BookOrbitAPI, seriesCollapse: SeriesCollapsePreferenceModel? = nil) {
    self.api = api
    collections = CollectionModel(api: api)
    self.seriesCollapse = seriesCollapse ?? SeriesCollapsePreferenceModel(api: api)
  }

  var collapseSeries: Bool { seriesCollapse.effective(in: location.seriesCollapseScope) }

  func seriesCollapseChanged() async {
    if queriedCollapseSeries != collapseSeries { await query(page: 0) }
  }

  var canGoNext: Bool { (page + 1) * pageSize < total && !isBusy }
  var canGoBack: Bool { page > 0 && !isBusy }

  var tableCustomFields: [CustomMetadataFieldSummary] {
    if case .library(let id, _) = location {
      return customFields.filter { $0.enabledLibraryIds.contains(id) }
    }
    return customFields
  }

  func loadCustomFields() async {
    guard !isLoadingCustomFields else { return }
    isLoadingCustomFields = true
    customFieldsError = nil
    defer { isLoadingCustomFields = false }
    do {
      let fields: [CustomMetadataFieldSummary] = try await api.boundedJSON(
        "custom-metadata/fields/active")
      guard fields.count <= 1000 else { throw ConnectionError.responseTooLarge }
      let accessibleLibraries = Set(libraries.map(\.id))
      customFields = fields.filter {
        $0.archivedAt == nil
          && !$0.enabledLibraryIds.allSatisfy { !accessibleLibraries.contains($0) }
      }.sorted {
        $0.displayOrder == $1.displayOrder ? $0.id < $1.id : $0.displayOrder < $1.displayOrder
      }
    } catch { customFieldsError = error.localizedDescription }
  }

  func load() async {
    do {
      let result: [Library] = try await api.send("libraries")
      libraries = result.filter { $0.type == "books" }
      await loadCustomFields()
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
  func discardUnavailableBook(_ bookID: Int) {
    requestID = UUID()
    books.removeAll { $0.id == bookID }
  }
  func refreshAfterMove(bookID: Int, session: UUID) async {
    discardUnavailableBook(bookID)
    await refreshAfterTableMutation(session: session)
  }
  func refreshAfterTableMutation(session: UUID? = nil) async {
    await query(page: page, session: session)
    if error == nil, books.isEmpty, page > 0 {
      let lastPage = max(0, (total - 1) / pageSize)
      if page > lastPage { await query(page: lastPage, session: session) }
    }
  }
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
  func applyPresetSort(_ sorts: [SortSpec]?) async throws {
    guard let sorts, !sorts.isEmpty else { return }
    if sorts.contains(where: { $0.field == "collectionOrder" }) {
      guard case .collection = location else { throw TablePresetError.collectionSort }
    }
    await apply(filter: filter, sort: sorts)
  }
  func nextPage() async { if canGoNext { await query(page: page + 1) } }
  func previousPage() async { if canGoBack { await query(page: page - 1) } }

  private func query(page: Int, session: UUID? = nil) async {
    let id = UUID()
    requestID = id
    isBusy = true
    error = nil
    defer { if requestID == id { isBusy = false } }
    do {
      if !seriesCollapse.isLoaded { await seriesCollapse.reconcile() }
      let capturedSession: UUID
      if let session {
        capturedSession = session
      } else {
        capturedSession = try await api.authenticatedSessionGeneration()
      }
      try Task.checkCancellation()
      guard requestID == id else { return }
      let collapseSeries = self.collapseSeries
      let query = BookQuery(
        filter: filter,
        sort: [SortSpec(field: sort, dir: descending ? "desc" : "asc")] + secondarySort,
        pagination: BookQueryPagination(page: page, size: pageSize), q: search,
        collapseSeries: collapseSeries,
        randomSeed: sort == "random" || secondarySort.contains { $0.field == "random" }
          ? randomSeed : nil)
      let path = location.queryPath
      let result: BooksPage = try await api.boundedJSON(
        path, method: "POST", body: JSONEncoder().encode(query), session: capturedSession)
      try Task.checkCancellation()
      guard requestID == id else { return }
      guard result.items.count <= pageSize, result.page == page, result.total >= 0 else {
        throw ConnectionError.invalidResponse
      }
      books = result.items
      total = result.total
      self.page = result.page
      queriedCollapseSeries = collapseSeries
    } catch {
      guard requestID == id, !Task.isCancelled else { return }
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
