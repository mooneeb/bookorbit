import Foundation
import Observation
import UIKit

@MainActor @Observable
final class SessionModel {
  private(set) var api: BookOrbitAPI?
  private(set) var user: AuthUser?
  private(set) var options: LoginOptionsResponse?
  private(set) var isBusy = false
  var error: String?
  var serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
  private let oidc = OIDCSignIn()

  func connect() async {
    await perform {
      let profile = try ServerProfile(self.serverURL)
      let api = try BookOrbitAPI(profile: profile)
      let options = try await api.loginOptions()
      self.api = api
      self.options = options
      self.serverURL = profile.url.absoluteString
      UserDefaults.standard.set(self.serverURL, forKey: "serverURL")
      self.user = try await api.resume()
    }
  }

  func restore() async {
    guard !serverURL.isEmpty, api == nil, !isBusy else { return }
    await connect()
  }

  func returnToForeground() async {
    guard let api, user != nil, !isBusy else { return }
    do { user = try await api.resume() } catch ConnectionError.expiredSession {
      user = nil
      error = ConnectionError.expiredSession.localizedDescription
    } catch { self.error = error.localizedDescription }
  }

  func signIn(username: String, password: String) async {
    guard let api else { return }
    await perform { self.user = try await api.login(username: username, password: password) }
  }

  func signOut() async {
    guard let api else { return }
    await perform {
      try await api.logout()
      self.user = nil
      self.api = nil
      self.options = nil
    }
  }

  func changePassword(current: String, new: String) async {
    guard let api else { return }
    await perform {
      try await api.changePassword(current: current, new: new)
      self.user = nil
    }
  }

  func signIn(provider: OidcProviderPublic, window: UIWindow) async {
    guard let api else { return }
    await perform {
      self.user = try await self.oidc.signIn(provider: provider, api: api, window: window)
    }
  }

  func changeServer() {
    guard user == nil, !isBusy else { return }
    api = nil
    options = nil
    error = nil
  }

  private func perform(_ work: () async throws -> Void) async {
    guard !isBusy else { return }
    isBusy = true
    error = nil
    defer { isBusy = false }
    do { try await work() } catch { self.error = error.localizedDescription }
  }
}
