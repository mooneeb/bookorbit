import Foundation

extension BookOrbitAPI {
  func accountSessions() async throws -> [Session] {
    try await boundedJSONOnline("auth/sessions", byteLimit: 128 * 1024)
  }

  func revokeAccountSession(_ id: Int) async throws {
    guard id > 0 else { throw ConnectionError.invalidResponse }
    try await sendEmpty("auth/sessions/\(id)", method: "DELETE")
  }

  func linkedIdentities() async throws -> [OidcLinkedIdentity] {
    try await boundedJSONOnline("auth/oidc/identities", byteLimit: 128 * 1024)
  }

  func oidcLinkState(slug: String) async throws -> OidcStateResponse {
    try await boundedJSON("auth/oidc/\(slug)/link-state", method: "POST", body: Data("{}".utf8))
  }

  func completeOIDCLink(_ callback: OidcCallbackRequest, session: UUID) async throws {
    let result: OidcLinkResult = try await boundedJSON(
      "auth/oidc/callback", method: "POST", body: JSONEncoder().encode(callback), session: session)
    guard result.mode == "link", result.linked else { throw ConnectionError.invalidResponse }
  }

  func unlinkIdentity(providerID: Int, password: String?) async throws {
    guard providerID > 0 else { throw ConnectionError.invalidResponse }
    try await sendEmpty(
      "auth/oidc/identities/\(providerID)", method: "DELETE",
      body: JSONEncoder().encode(OidcUnlinkRequest(password: password)))
  }

  func loginWithMagicLink(token: String) async throws -> AuthUser {
    let response: NativeAuthResponse = try await send(
      "auth/magic-links/login", method: "POST",
      body: JSONEncoder().encode(
        MagicLinkLoginRequest(
          token: token, clientKind: "native", deviceLabel: "BookOrbit private iPad")),
      authenticated: false)
    return try accept(response)
  }
}
