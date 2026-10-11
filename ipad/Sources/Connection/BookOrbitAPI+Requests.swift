import Foundation

extension BookOrbitAPI {
  func requests(page: Int, status: String?) async throws -> BookRequestPage {
    var query = [
      URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "limit", value: "20"),
    ]
    if let status, !status.isEmpty { query.append(URLQueryItem(name: "status", value: status)) }
    return try await send("book-requests", query: query)
  }

  func request(_ id: Int) async throws -> BookRequestItem {
    try await send("book-requests/\(id)")
  }

  func submitRequest(_ body: CreateBookRequestPayload) async throws -> BookRequestSubmitResult {
    try await send("book-requests", method: "POST", body: JSONEncoder().encode(body))
  }

  func requestAvailability(_ body: BookRequestAvailabilityQuery) async throws
    -> [BookRequestAvailability]
  {
    let item = try JSONEncoder().encode(body)
    let object = try JSONSerialization.jsonObject(with: item)
    return try await send(
      "book-requests/availability", method: "POST",
      body: JSONSerialization.data(withJSONObject: ["items": [object]]))
  }

  func cancelRequest(_ id: Int, downloadID: Int? = nil) async throws -> BookRequestItem {
    let suffix = downloadID.map { "downloads/\($0)/cancel" } ?? "cancel"
    return try await send("book-requests/\(id)/\(suffix)", method: "POST")
  }

  func unsubscribeRequest(_ id: Int) async throws {
    try await sendEmpty("book-requests/\(id)/subscription", method: "DELETE", expectedStatus: 204)
  }

  func requestReleases(_ id: Int) async throws -> ReleaseSearchResult {
    try await send(
      "book-request-fulfilment/\(id)/releases",
      query: [URLQueryItem(name: "refresh", value: "true")])
  }

  func grabRequest(_ id: Int, body: GrabBookRequestPayload) async throws -> BookRequestItem {
    try await send(
      "book-request-fulfilment/\(id)/grab", method: "POST", body: JSONEncoder().encode(body))
  }

  func requestReview(_ id: Int) async throws -> BookRequestReview {
    try await send("book-request-fulfilment/\(id)/review")
  }

  func resolveRequestReview(_ id: Int, discard: Bool) async throws -> BookRequestItem {
    try await send(
      "book-request-fulfilment/\(id)/\(discard ? "discard-import" : "force-file")", method: "POST")
  }
}
