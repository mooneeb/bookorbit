import Foundation

enum EPUBLanguageToolError: Error {
  case invalidResponse, responseTooLarge, busy
  case status(Int)
}

private final class EPUBLanguageToolRedirects: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    let source = task.originalRequest?.url
    let target = request.url
    completionHandler(
      source?.scheme == target?.scheme && source?.host == target?.host
        && source?.port == target?.port ? request : nil)
  }
}

actor EPUBLanguageToolTransport {
  private let session: URLSession
  private var activeRequests = 0
  #if DEBUG
    private let fixtureOrigin: URLComponents?
  #endif

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 12
    configuration.timeoutIntervalForResource = 20
    configuration.httpMaximumConnectionsPerHost = 2
    session = URLSession(
      configuration: configuration, delegate: EPUBLanguageToolRedirects(), delegateQueue: nil)
    #if DEBUG
      let fixture = ProcessInfo.processInfo.environment["BOOKORBIT_LANGUAGE_TOOLS_FIXTURE_URL"]
        .flatMap { URLComponents(string: $0) }
      if let fixture, fixture.scheme == "http", fixture.host == "127.0.0.1",
        fixture.user == nil, fixture.password == nil, fixture.query == nil,
        fixture.fragment == nil, fixture.path.isEmpty || fixture.path == "/",
        let port = fixture.port, (1...65535).contains(port)
      {
        fixtureOrigin = fixture
      } else {
        fixtureOrigin = nil
      }
    #endif
  }

  func bytes(_ request: URLRequest, limit: Int) async throws -> (Data, Int) {
    try Task.checkCancellation()
    guard activeRequests < 2 else { throw EPUBLanguageToolError.busy }
    guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil,
      url.fragment == nil, url.port == nil || url.port == 443,
      (1...(2 * 1024 * 1024)).contains(limit)
    else { throw EPUBLanguageToolError.invalidResponse }
    activeRequests += 1
    defer { activeRequests -= 1 }
    var outgoing = request
    #if DEBUG
      if var fixture = fixtureOrigin,
        let original = URLComponents(url: url, resolvingAgainstBaseURL: false)
      {
        fixture.percentEncodedPath = original.percentEncodedPath
        fixture.percentEncodedQuery = original.percentEncodedQuery
        guard let fixtureURL = fixture.url else { throw EPUBLanguageToolError.invalidResponse }
        outgoing.url = fixtureURL
        outgoing.setValue(url.absoluteString, forHTTPHeaderField: "X-BookOrbit-Provider-URL")
      }
    #endif
    let (stream, response) = try await session.bytes(for: outgoing)
    defer { stream.task.cancel() }
    guard let http = response as? HTTPURLResponse else {
      throw EPUBLanguageToolError.invalidResponse
    }
    guard response.expectedContentLength <= Int64(limit) else {
      throw EPUBLanguageToolError.responseTooLarge
    }
    guard http.statusCode == 200 else { return (Data(), http.statusCode) }
    var result = Data()
    let deadline = Date().addingTimeInterval(20)
    for try await byte in stream {
      try Task.checkCancellation()
      guard result.count < limit else { throw EPUBLanguageToolError.responseTooLarge }
      guard Date() < deadline else { throw URLError(.timedOut) }
      result.append(byte)
    }
    try Task.checkCancellation()
    return (result, http.statusCode)
  }

  func json(_ url: URL) async throws -> Data {
    let (data, status) = try await bytes(URLRequest(url: url), limit: 512 * 1024)
    guard status == 200 else { throw EPUBLanguageToolError.status(status) }
    return data
  }

  static func url(_ origin: String, path: String, query: [URLQueryItem] = []) throws -> URL {
    guard var components = URLComponents(string: origin) else {
      throw EPUBLanguageToolError.invalidResponse
    }
    components.path = path
    components.queryItems = query.isEmpty ? nil : query
    guard let url = components.url else { throw EPUBLanguageToolError.invalidResponse }
    return url
  }

  static func trim(_ value: String) -> String {
    let whitespace = CharacterSet(
      charactersIn:
        "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}\u{00A0}\u{1680}"
        + "\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}"
        + "\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")
    return value.trimmingCharacters(in: whitespace)
  }

  static func wordURL(_ origin: String, prefix: String, word: String) throws -> URL {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/%?#")
    guard let encoded = word.addingPercentEncoding(withAllowedCharacters: allowed),
      var components = URLComponents(string: origin)
    else { throw EPUBLanguageToolError.invalidResponse }
    components.percentEncodedPath = prefix + encoded
    guard let url = components.url else { throw EPUBLanguageToolError.invalidResponse }
    return url
  }
}
