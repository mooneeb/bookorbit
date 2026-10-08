import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

@MainActor
final class OIDCSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
  static let callback = "bookorbit-private://oauth2-callback"
  private var session: ASWebAuthenticationSession?
  private weak var window: UIWindow?

  func signIn(provider: OidcProviderPublic, api: BookOrbitAPI, window: UIWindow) async throws
    -> AuthUser
  {
    self.window = window
    let state = try await api.oidcState(slug: provider.slug)
    let verifier = try randomValue()
    let nonce = try randomValue()
    let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    guard var url = URLComponents(string: state.authorizationEndpoint),
      ["https", "http"].contains(url.scheme), url.host != nil
    else { throw ConnectionError.invalidResponse }
    url.queryItems =
      (url.queryItems ?? []) + [
        URLQueryItem(name: "client_id", value: provider.clientId),
        URLQueryItem(name: "redirect_uri", value: Self.callback),
        URLQueryItem(name: "response_type", value: "code"),
        URLQueryItem(name: "scope", value: provider.scopes),
        URLQueryItem(name: "state", value: state.state),
        URLQueryItem(name: "nonce", value: nonce),
        URLQueryItem(name: "code_challenge", value: challenge),
        URLQueryItem(name: "code_challenge_method", value: "S256"),
      ]
    guard let authorizationURL = url.url else { throw ConnectionError.invalidResponse }
    defer { session = nil }
    let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
      let session = ASWebAuthenticationSession(
        url: authorizationURL, callbackURLScheme: "bookorbit-private"
      ) { url, error in
        if let url {
          continuation.resume(returning: url)
        } else {
          continuation.resume(throwing: error ?? ConnectionError.invalidResponse)
        }
      }
      session.presentationContextProvider = self
      session.prefersEphemeralWebBrowserSession = true
      self.session = session
      if !session.start() { continuation.resume(throwing: ConnectionError.invalidResponse) }
    }
    guard callbackURL.scheme == "bookorbit-private", callbackURL.host == "oauth2-callback",
      callbackURL.path.isEmpty,
      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
    else { throw ConnectionError.invalidResponse }
    let items = components.queryItems ?? []
    func value(_ name: String) -> String? {
      let matching = items.filter { $0.name == name }
      return matching.count == 1 ? matching.first?.value : nil
    }
    guard value("state") == state.state, let code = value("code"), !code.isEmpty,
      value("error") == nil
    else {
      throw ConnectionError.invalidResponse
    }
    return try await api.completeOIDC(
      OidcCallbackRequest(
        code: code, codeVerifier: verifier, redirectUri: Self.callback,
        nonce: nonce, state: state.state, clientKind: "native",
        deviceLabel: "BookOrbit private iPad"))
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    window ?? ASPresentationAnchor()
  }

  private func randomValue() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else { throw ConnectionError.keychain(status) }
    return Data(bytes).base64URLEncoded
  }
}

extension Data {
  fileprivate var base64URLEncoded: String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
}
