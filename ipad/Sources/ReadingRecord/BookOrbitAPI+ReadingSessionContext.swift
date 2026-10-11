import Foundation

extension BookOrbitAPI {
  func readingSessionContext(fileID: Int, session: UUID? = nil) async throws
    -> NativeReadingSessionContext
  {
    guard fileID > 0 else { throw ConnectionError.invalidResponse }
    let context: NativeReadingSessionContext = try await boundedJSONOnline(
      "books/files/\(fileID)/session-context", byteLimit: 4 * 1024, session: session,
      expectedStatus: 200, timeoutInterval: 2)
    guard context.bookId > 0, context.attemptId.map({ $0 > 0 }) != false else {
      throw ConnectionError.invalidResponse
    }
    return context
  }

  func saveNativeReadingSession(
    fileID: Int, payload: SaveReadingSessionPayload, attemptID: Int?, session: UUID
  ) async throws {
    guard fileID > 0, attemptID.map({ $0 > 0 }) != false else {
      throw ConnectionError.invalidResponse
    }
    let encoded = try JSONEncoder().encode(payload)
    guard var body = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
      throw ConnectionError.invalidResponse
    }
    body["attemptId"] = attemptID.map { $0 as Any } ?? NSNull()
    try await sendEmpty(
      "books/files/\(fileID)/sessions", body: JSONSerialization.data(withJSONObject: body),
      session: session, expectedStatus: 204)
  }
}
