import Foundation
import Observation

@MainActor @Observable
final class CollectionModel {
  private let api: BookOrbitAPI
  private let ownedOnly: Bool
  private(set) var items: [BookCollection] = []
  private(set) var total = 0
  private(set) var page = 0
  private(set) var isBusy = false
  var search = ""
  var error: String?
  private var requestID = UUID()
  private let pageSize = 40

  init(api: BookOrbitAPI, ownedOnly: Bool = false) {
    self.api = api
    self.ownedOnly = ownedOnly
  }

  var canGoBack: Bool { page > 0 && !isBusy }
  var canGoNext: Bool { (page + 1) * pageSize < total && !isBusy }

  func load() async { await query(page: 0) }
  func previousPage() async { if canGoBack { await query(page: page - 1) } }
  func nextPage() async { if canGoNext { await query(page: page + 1) } }

  func create(name: String) async throws -> BookCollection {
    let payload = CreateCollectionPayload(
      name: name.trimmingCharacters(in: .whitespacesAndNewlines), icon: "folder", mediaType: "books"
    )
    let result: BookCollection
    do {
      result = try await api.send(
        "collections", method: "POST", body: JSONEncoder().encode(payload))
    } catch ConnectionError.http(409) {
      throw CollectionError.nameExists
    }
    search = result.name
    await load()
    return result
  }

  func addBook(_ bookID: Int, to collectionID: Int) async throws -> BookCollection {
    let selection = BookIdsSelection(bookIds: [bookID])
    return try await api.send(
      "collections/\(collectionID)/books", method: "POST", body: JSONEncoder().encode(selection))
  }

  private func query(page: Int) async {
    let id = UUID()
    requestID = id
    isBusy = true
    error = nil
    defer { if requestID == id { isBusy = false } }
    let query = CollectionPageQuery(
      page: page, size: pageSize, q: search, mediaType: "books", owned: ownedOnly)
    do {
      let result: CollectionsPage = try await api.send(
        "collections/page",
        query: [
          URLQueryItem(name: "page", value: String(query.page ?? 0)),
          URLQueryItem(name: "size", value: String(query.size ?? pageSize)),
          URLQueryItem(name: "q", value: query.q),
          URLQueryItem(name: "mediaType", value: query.mediaType),
          URLQueryItem(name: "owned", value: query.owned.map(String.init)),
        ])
      guard requestID == id else { return }
      items = result.items
      total = result.total
      self.page = result.page
    } catch {
      guard requestID == id else { return }
      self.error = error.localizedDescription
    }
  }
}

enum CollectionError: LocalizedError {
  case nameExists

  var errorDescription: String? {
    switch self {
    case .nameExists: "A collection with this name already exists. Choose another name."
    }
  }
}
