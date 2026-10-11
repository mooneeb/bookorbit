import Foundation

extension BookOrbitAPI {
  func catalogURL(_ path: String, query: [URLQueryItem] = []) -> URL {
    profile.endpoint(path, query: query)
  }

  func checkOPDS(username: String, password: String) async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.timeoutIntervalForRequest = 20
    let transport = URLSession(
      configuration: configuration, delegate: CatalogRedirectPolicy(), delegateQueue: nil)
    defer { transport.invalidateAndCancel() }
    var request = URLRequest(
      url: profile.endpoint("opds"), cachePolicy: .reloadIgnoringLocalCacheData)
    let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
    request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
    request.setValue("application/atom+xml", forHTTPHeaderField: "Accept")
    let (bytes, response) = try await transport.bytes(for: request)
    guard let response = response as? HTTPURLResponse else { throw ConnectionError.invalidResponse }
    guard response.statusCode == 200 else { throw ConnectionError.http(response.statusCode) }
    guard response.expectedContentLength <= 512 * 1024 else {
      throw ConnectionError.responseTooLarge
    }
    var data = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      guard data.count < 512 * 1024 else { throw ConnectionError.responseTooLarge }
      data.append(byte)
    }
    guard response.mimeType == "application/atom+xml",
      let document = String(data: data, encoding: .utf8), document.contains("<feed")
    else { throw ConnectionError.invalidResponse }
  }
}

private final class CatalogRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
