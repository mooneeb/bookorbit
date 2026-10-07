import Foundation

struct ServerProfile: Equatable, Sendable {
  let url: URL

  init(_ input: String) throws {
    guard
      var components = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
      ["http", "https"].contains(components.scheme?.lowercased()),
      let host = components.host, !host.isEmpty,
      components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil
    else {
      throw ConnectionError.invalidServer
    }
    components.scheme = components.scheme?.lowercased()
    components.host = host.lowercased()
    components.path = components.path.replacingOccurrences(
      of: #"/+$"#, with: "", options: .regularExpression)
    guard let url = components.url else { throw ConnectionError.invalidServer }
    self.url = url
  }

  func endpoint(_ path: String, query: [URLQueryItem] = []) -> URL {
    url.appendingPathComponent("api/v1/\(path)").appending(queryItems: query)
  }
}

enum ConnectionError: LocalizedError {
  case invalidServer
  case invalidResponse
  case expiredSession
  case denied
  case fileChanged
  case insufficientStorage
  case resourceTooLarge
  case responseTooLarge
  case comicPageTooLarge
  case http(Int)
  case keychain(OSStatus)

  var errorDescription: String? {
    switch self {
    case .invalidServer: "Enter a server URL beginning with http:// or https://."
    case .invalidResponse: "The server returned an incompatible response."
    case .expiredSession: "Your session expired. Sign in again."
    case .denied: "Your account does not have access to this action."
    case .fileChanged: "The book file changed. Close the reader and reopen the book."
    case .insufficientStorage: "There is not enough free space to open this book file."
    case .resourceTooLarge: "This EPUB resource is too large to open safely."
    case .responseTooLarge:
      "The server response is too large to open safely."
    case .comicPageTooLarge: "This comic page exceeds the reader's 20 MB image limit."
    case .http(401): "The username or password is incorrect."
    case .http(let status): "The server could not complete the request (\(status)). Try again."
    case .keychain: "Your credentials could not be saved securely. Unlock your iPad and try again."
    }
  }
}
