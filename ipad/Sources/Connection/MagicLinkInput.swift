import Foundation

enum MagicLinkInput {
  static func token(from input: String, profile: ServerProfile) throws -> String {
    let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.utf8.count <= 4096 else { throw InputError.invalidToken }
    let token: String
    if value.contains("://") {
      guard let link = URLComponents(string: value),
        let server = URLComponents(url: profile.url, resolvingAgainstBaseURL: false),
        link.user == nil, link.password == nil, link.fragment == nil,
        link.scheme?.lowercased() == server.scheme,
        link.host?.lowercased() == server.host?.lowercased(),
        port(link) == port(server), link.path == server.path + "/magic"
      else { throw InputError.differentServer }
      let tokens = (link.queryItems ?? []).filter { $0.name == "token" }
      guard tokens.count == 1, let parsed = tokens.first?.value else {
        throw InputError.invalidToken
      }
      token = parsed
    } else {
      token = value
    }
    guard !token.isEmpty, token.unicodeScalars.count <= 512,
      token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    else { throw InputError.invalidToken }
    return token
  }

  private static func port(_ components: URLComponents) -> Int {
    components.port ?? (components.scheme?.lowercased() == "https" ? 443 : 80)
  }

  private enum InputError: LocalizedError {
    case invalidToken
    case differentServer

    var errorDescription: String? {
      switch self {
      case .invalidToken: "Paste a magic-link token of no more than 512 characters."
      case .differentServer: "Connect to the server that issued this magic link before signing in."
      }
    }
  }
}
