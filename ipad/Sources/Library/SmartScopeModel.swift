import Foundation
import Observation

@MainActor @Observable
final class SmartScopeModel {
  let api: BookOrbitAPI
  private(set) var items: [BookSmartScope] = []
  private(set) var page = 0
  private(set) var total = 0
  private(set) var isBusy = false
  var search = ""
  var ownedOnly = false
  var error: String?
  private var requestID = UUID()
  let pageSize = 40

  init(api: BookOrbitAPI) { self.api = api }
  var canGoBack: Bool { page > 0 && !isBusy }
  var canGoNext: Bool { (page + 1) * pageSize < total && !isBusy }
  func load() async { await query(page: 0) }
  func previousPage() async { if canGoBack { await query(page: page - 1) } }
  func nextPage() async { if canGoNext { await query(page: page + 1) } }

  func save(
    name: String, filter: GroupRule?, sort: [SortSpec], isPublic: Bool, existing: BookSmartScope?
  ) async throws -> BookSmartScope {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let result: BookSmartScope
    if let existing {
      let payload = UpdateSmartScopePayload(
        name: name, filter: filter, defaultSort: sort, isPublic: isPublic)
      result = try await api.send(
        "smart-scopes/\(existing.id)", method: "PATCH", body: JSONEncoder().encode(payload))
    } else {
      let payload = CreateSmartScopePayload(
        name: name, icon: "filter", mediaType: "books", filter: filter, defaultSort: sort,
        isPublic: isPublic)
      result = try await api.send(
        "smart-scopes", method: "POST", body: JSONEncoder().encode(payload))
    }
    await load()
    return result
  }

  func remove(_ scope: BookSmartScope) async throws {
    try await api.sendEmpty("smart-scopes/\(scope.id)", method: "DELETE")
    await query(page: page)
    if items.isEmpty && page > 0 { await query(page: page - 1) }
  }

  func setKoboSync(_ scope: BookSmartScope, enabled: Bool) async throws {
    let selection = SetSmartScopeKoboSyncPayload(enabled: enabled)
    let _: BookSmartScope = try await api.send(
      "smart-scopes/\(scope.id)/kobo-sync", method: "PUT", body: JSONEncoder().encode(selection))
    await query(page: page)
  }

  private func query(page: Int) async {
    let id = UUID()
    requestID = id
    isBusy = true
    error = nil
    defer { if requestID == id { isBusy = false } }
    do {
      let result: SmartScopesPage = try await api.send(
        "smart-scopes/page",
        query: [
          URLQueryItem(name: "page", value: String(page)),
          URLQueryItem(name: "size", value: String(pageSize)),
          URLQueryItem(name: "q", value: search),
          URLQueryItem(name: "mediaType", value: "books"),
          URLQueryItem(name: "owned", value: String(ownedOnly)),
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
