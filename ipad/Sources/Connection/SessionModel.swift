import Foundation
import Observation
import UIKit

@MainActor @Observable
final class SessionModel {
  private(set) var api: BookOrbitAPI?
  private(set) var user: AuthUser? {
    didSet {
      guard let user, let api else {
        seriesCollapse?.receive(user: nil)
        seriesCollapse = nil
        if let api { Task { await NativeAnnotationRepository.disconnect(api: api) } }
        return
      }
      if seriesCollapse?.api !== api { seriesCollapse = SeriesCollapsePreferenceModel(api: api) }
      seriesCollapse?.receive(user: user)
      Task {
        guard self.api === api, self.user?.id == user.id else { return }
        await self.synchronizeAnnotations(api: api)
        await api.reconcileOfflineBooks()
      }
    }
  }
  private(set) var seriesCollapse: SeriesCollapsePreferenceModel?
  private(set) var options: LoginOptionsResponse?
  private(set) var isBusy = false
  var error: String?
  var signOutError: String?
  var serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
  private let oidc = OIDCSignIn()
  private var sessionOperationID = UUID()
  private var isValidating = false

  func connect() async {
    await perform {
      let profile = try ServerProfile(self.serverURL)
      let api = try BookOrbitAPI(profile: profile)
      self.api = api
      self.serverURL = profile.url.absoluteString
      UserDefaults.standard.set(self.serverURL, forKey: "serverURL")
      do {
        self.options = try await api.loginOptions()
        self.user = try await api.resume()
      } catch {
        guard error is URLError, let user = try await api.resumeOfflineUser() else { throw error }
        self.user = user
      }
    }
  }

  func restore() async {
    guard !serverURL.isEmpty, api == nil, !isBusy else { return }
    await connect()
  }

  func returnToForeground() async {
    guard let api, user != nil, !isBusy, !isValidating else { return }
    let operationID = sessionOperationID
    isValidating = true
    defer { isValidating = false }
    do {
      let resumedUser = try await api.resume()
      guard self.api === api, operationID == sessionOperationID else { return }
      user = resumedUser
      await seriesCollapse?.reconcile()
      await synchronizeAnnotations(api: api)
      await api.reconcileOfflineBooks()
    } catch {
      guard self.api === api, operationID == sessionOperationID else { return }
      switch error {
      case ConnectionError.expiredSession: user = nil
      default: break
      }
      self.error = error.localizedDescription
    }
  }

  func signIn(username: String, password: String) async {
    guard let api else { return }
    await perform { self.user = try await api.login(username: username, password: password) }
  }

  func canRecoverPassword(using api: BookOrbitAPI) -> Bool {
    self.api === api && user == nil && options?.passwordLoginEnabled == true && !isBusy
  }

  func requestPasswordReset(_ request: ForgotPasswordRequest, using api: BookOrbitAPI) async throws
  {
    guard canRecoverPassword(using: api) else { throw ConnectionError.denied }
    let operationID = sessionOperationID
    try Task.checkCancellation()
    try await api.sendPublicEmpty(
      "auth/forgot-password", body: JSONEncoder().encode(request), expectedStatus: 200)
    try Task.checkCancellation()
    guard operationID == sessionOperationID, canRecoverPassword(using: api) else {
      throw CancellationError()
    }
  }

  func resetPassword(_ request: ResetPasswordRequest, using api: BookOrbitAPI) async throws {
    guard canRecoverPassword(using: api) else { throw ConnectionError.denied }
    let operationID = sessionOperationID
    try Task.checkCancellation()
    try await api.sendPublicEmpty(
      "auth/reset-password", body: JSONEncoder().encode(request), expectedStatus: 204)
    try Task.checkCancellation()
    guard operationID == sessionOperationID, canRecoverPassword(using: api) else {
      throw CancellationError()
    }
  }

  func signOut() async {
    guard let api, !isBusy else { return }
    await perform {
      do {
        try await api.logout()
      } catch {
        self.signOutError = error.localizedDescription
        throw error
      }
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
    sessionOperationID = UUID()
    api = nil
    options = nil
    error = nil
    signOutError = nil
  }

  private func synchronizeAnnotations(api: BookOrbitAPI) async {
    do {
      let repository = try await NativeAnnotationRepository.shared(api: api)
      guard self.api === api, user != nil else { return }
      await repository.synchronizePending()
    } catch {
      guard self.api === api, user != nil else { return }
      self.error = error.localizedDescription
    }
  }

  private func perform(_ work: () async throws -> Void) async {
    guard !isBusy else { return }
    sessionOperationID = UUID()
    isBusy = true
    error = nil
    signOutError = nil
    defer { isBusy = false }
    do { try await work() } catch { self.error = error.localizedDescription }
  }
}
