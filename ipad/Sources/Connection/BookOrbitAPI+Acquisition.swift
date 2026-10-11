import Foundation

extension BookOrbitAPI {
  func acquisitionCapabilities(session: UUID) async throws -> UploadCapabilitiesResponse {
    try await boundedJSON(
      "uploads/capabilities", byteLimit: 1024 * 1024, session: session, expectedStatus: 200)
  }

  func uploadSession(_ id: String, session: UUID) async throws -> UploadSessionResponse {
    try await boundedJSON("uploads/\(id)", session: session, expectedStatus: 200)
  }

  func uploadChunk(_ id: String, offset: Int, data: Data, session: UUID) async throws
    -> UploadSessionResponse
  {
    try await boundedMultipart(
      "uploads/\(id)/chunks", filename: "chunk", data: data,
      headers: ["Upload-Offset": String(offset)], session: session)
  }

  func dockPage(page: Int, search: String, session: UUID) async throws -> BookDockFilesPage {
    try await boundedJSON(
      "book-dock/files",
      query: [
        URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "limit", value: "20"),
        URLQueryItem(name: "search", value: search),
      ], byteLimit: 1024 * 1024, session: session, expectedStatus: 200)
  }
  func startFinalizeJob(_ request: BookDockFinalizeJobRequest, session: UUID) async throws
    -> BookDockFinalizeJob
  {
    try await boundedJSON(
      "book-dock/finalize-jobs", method: "POST", body: JSONEncoder().encode(request),
      byteLimit: 1024 * 1024, session: session, expectedStatus: 202)
  }
  func finalizeJob(_ id: Int, session: UUID) async throws -> BookDockFinalizeJob {
    try await boundedJSON(
      "book-dock/finalize-jobs/\(id)", byteLimit: 1024 * 1024,
      session: session, expectedStatus: 200)
  }
  func retryFinalizeJob(_ id: Int, session: UUID) async throws -> BookDockFinalizeJob {
    try await boundedJSON(
      "book-dock/finalize-jobs/\(id)/retry", method: "POST", body: Data("{}".utf8),
      byteLimit: 1024 * 1024, session: session, expectedStatus: 202)
  }

}
