import Foundation
import Observation

@MainActor @Observable
final class CollectionModel {
  private let api: BookOrbitAPI
  private let ownedOnly: Bool
  private let bookID: Int?
  private(set) var items: [BookCollection] = []
  private(set) var total = 0
  private(set) var page = 0
  private(set) var isBusy = false
  private(set) var isMutating = false
  var search = ""
  var error: String?
  private var requestID = UUID()
  private let pageSize = 40

  init(api: BookOrbitAPI, ownedOnly: Bool = false, bookID: Int? = nil) {
    self.api = api
    self.ownedOnly = ownedOnly
    self.bookID = bookID
  }

  var canGoBack: Bool { page > 0 && !isBusy && !isMutating }
  var canGoNext: Bool { (page + 1) * pageSize < total && !isBusy && !isMutating }

  func load() async { if !isMutating { await query(page: 0) } }
  func refresh() async { if !isMutating { await query(page: page) } }
  func previousPage() async { if canGoBack { await query(page: page - 1) } }
  func nextPage() async { if canGoNext { await query(page: page + 1) } }

  func create(name: String, icon: String = "Folder", isPublic: Bool = false) async throws
    -> BookCollection
  {
    let fields = try validatedFields(name: name, icon: icon)
    try beginMutation()
    defer { isMutating = false }
    let payload = CreateCollectionPayload(
      name: fields.name, icon: fields.icon, mediaType: "books", isPublic: isPublic)
    let result: BookCollection
    do {
      result = try await api.send(
        "collections", method: "POST", body: JSONEncoder().encode(payload))
    } catch ConnectionError.http(409) {
      throw CollectionError.nameExists
    }
    search = result.name
    await query(page: 0)
    return result
  }

  func update(_ collection: BookCollection, name: String, icon: String, isPublic: Bool)
    async throws -> BookCollection
  {
    try requireOwner(collection)
    let fields = try validatedFields(name: name, icon: icon)
    try beginMutation()
    defer { isMutating = false }
    let payload = UpdateCollectionPayload(name: fields.name, icon: fields.icon, isPublic: isPublic)
    let result: BookCollection
    do {
      result = try await api.send(
        "collections/\(collection.id)", method: "PATCH", body: JSONEncoder().encode(payload))
    } catch ConnectionError.http(409) {
      throw CollectionError.nameExists
    }
    acknowledge(result)
    await query(page: page)
    return result
  }

  func remove(_ collection: BookCollection) async throws {
    try requireOwner(collection)
    try beginMutation()
    defer { isMutating = false }
    try await api.sendEmpty("collections/\(collection.id)", method: "DELETE")
    items.removeAll { $0.id == collection.id }
    total = max(0, total - 1)
    await query(page: min(page, max(0, (total - 1) / pageSize)))
  }

  func addBook(_ bookID: Int, to collection: BookCollection) async throws -> BookCollection {
    try await setMembership(bookID, in: collection, included: true)
  }

  func removeBook(_ bookID: Int, from collection: BookCollection) async throws -> BookCollection {
    try await setMembership(bookID, in: collection, included: false)
  }

  private func setMembership(_ bookID: Int, in collection: BookCollection, included: Bool)
    async throws -> BookCollection
  {
    try requireOwner(collection)
    try beginMutation()
    defer { isMutating = false }
    let selection = BookIdsSelection(bookIds: [bookID])
    var result: BookCollection = try await api.send(
      "collections/\(collection.id)/books", method: included ? "POST" : "DELETE",
      body: JSONEncoder().encode(selection))
    if self.bookID == bookID { result.memberCount = included ? 1 : 0 }
    acknowledge(result)
    return result
  }

  private func requireOwner(_ collection: BookCollection) throws {
    guard collection.isOwner else { throw ConnectionError.denied }
  }

  private func validatedFields(name: String, icon: String) throws -> (name: String, icon: String) {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let icon = icon.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 255 else { throw CollectionError.invalidName }
    guard !icon.isEmpty, icon.count <= CollectionVocabulary.iconMaximum else {
      throw CollectionError.invalidIcon
    }
    return (name, icon)
  }

  private func beginMutation() throws {
    guard !isMutating else { throw CollectionError.busy }
    requestID = UUID()
    isBusy = false
    isMutating = true
  }

  private func acknowledge(_ collection: BookCollection) {
    if let index = items.firstIndex(where: { $0.id == collection.id }) { items[index] = collection }
  }

  private func query(page: Int) async {
    let id = UUID()
    requestID = id
    isBusy = true
    error = nil
    defer { if requestID == id { isBusy = false } }
    let query = CollectionPageQuery(
      page: page, size: pageSize, q: search, mediaType: "books", owned: ownedOnly, bookId: bookID)
    do {
      let result: CollectionsPage = try await api.send(
        "collections/page",
        query: [
          URLQueryItem(name: "page", value: String(query.page ?? 0)),
          URLQueryItem(name: "size", value: String(query.size ?? pageSize)),
          URLQueryItem(name: "q", value: query.q),
          URLQueryItem(name: "mediaType", value: query.mediaType),
          URLQueryItem(name: "owned", value: query.owned.map(String.init)),
        ] + (query.bookId.map { [URLQueryItem(name: "bookId", value: String($0))] } ?? []))
      guard requestID == id else { return }
      items = result.items
      total = result.total
      self.page = result.page
      if items.isEmpty && total > 0 && result.page > 0 {
        await self.query(page: (total - 1) / pageSize)
      }
    } catch {
      guard requestID == id else { return }
      self.error = error.localizedDescription
    }
  }
}

enum CollectionError: LocalizedError {
  case nameExists
  case invalidName
  case invalidIcon
  case busy

  var errorDescription: String? {
    switch self {
    case .nameExists: "A collection with this name already exists. Choose another name."
    case .invalidName: "Enter a collection name with at most 255 characters."
    case .invalidIcon:
      "Choose a collection icon with at most \(CollectionVocabulary.iconMaximum) characters."
    case .busy: "Wait for the collection change to finish, then try again."
    }
  }
}
