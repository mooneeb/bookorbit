import Foundation

enum E04FixtureHTTP {
  static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    return try await session.data(for: request)
  }

  static func data(from url: URL) async throws -> (Data, URLResponse) {
    try await data(for: URLRequest(url: url))
  }
}
