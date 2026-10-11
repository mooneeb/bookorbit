import Foundation

extension BookOrbitAPI {
  func entityPage(
    kind: EntityKind, search: String, page: Int, sort: String = "name",
    descending: Bool = false, emptyOnly: Bool = false
  ) async throws -> BrowseEntitiesResponse {
    let session = try authenticatedSessionGeneration()
    let result: BrowseEntitiesResponse = try await boundedJSON(
      "entity-manager/\(kind.rawValue)/browse",
      query: [
        URLQueryItem(name: "search", value: search),
        URLQueryItem(name: "page", value: String(page)),
        URLQueryItem(name: "pageSize", value: "40"),
        URLQueryItem(name: "sortBy", value: sort),
        URLQueryItem(name: "sortOrder", value: descending ? "desc" : "asc"),
        URLQueryItem(name: "bookCount", value: emptyOnly && !kind.isInline ? "empty" : "any"),
      ], session: session)
    guard result.items.count <= 40, result.page == page, result.pageSize == 40, result.total >= 0,
      result.items.allSatisfy({ item in
        item.bookCount >= 0 && !item.name.isEmpty
          && (kind.isInline
            ? item.id.entityValue.map { !$0.isEmpty } ?? false
            : item.id.entityNumber.map { $0 > 0 } ?? false)
      })
    else { throw ConnectionError.invalidResponse }
    return result
  }

  func entityInfo(kind: EntityKind, id: StringOrNumber) async throws -> EntityInfo {
    let session = try authenticatedSessionGeneration()
    let result: EntityInfo = try await boundedJSON(
      "entity-manager/\(kind.rawValue)/info",
      query: [URLQueryItem(name: kind.isInline ? "value" : "entityId", value: id.entityPath)],
      session: session)
    guard result.id == id, result.bookCount >= 0, result.bookTitles.count <= 5 else {
      throw ConnectionError.invalidResponse
    }
    return result
  }
}
