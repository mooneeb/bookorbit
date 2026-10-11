import Foundation
import Observation
import UIKit

@MainActor @Observable
final class AccountAccessModel {
  let session: SessionModel
  let api: BookOrbitAPI
  private let userID: Int
  private(set) var sessions: [Session] = []
  private(set) var identities: [OidcLinkedIdentity] = []
  private(set) var providers: [OidcProviderPublic] = []
  private(set) var currentSessionID: Int?
  private(set) var passwordLoginEnabled = false
  private(set) var isBusy = false
  private(set) var error: String?
  private(set) var notice: String?
  private var active = true

  init(session: SessionModel, api: BookOrbitAPI) {
    self.session = session
    self.api = api
    userID = session.user?.id ?? 0
  }

  var isAvailable: Bool {
    active && session.api === api && session.user?.id == userID
  }

  var canEditIdentity: Bool {
    isAvailable && session.user?.permissions.contains(Permission.demoRestricted.rawValue) != true
  }

  var needsPasswordConfirmation: Bool {
    passwordLoginEnabled && session.user?.authenticationMethod != "oidc"
  }

  var unlinkedProviders: [OidcProviderPublic] {
    providers.filter { provider in !identities.contains { $0.providerSlug == provider.slug } }
  }

  func load() async {
    guard isAvailable, !isBusy else { return }
    isBusy = true
    error = nil
    defer { isBusy = false }
    do {
      let generation = try await api.authenticatedSessionGeneration()
      let current = try await api.currentSessionID()
      async let sessions = api.accountSessions()
      async let identities = api.linkedIdentities()
      async let options = api.loginOptions()
      let result = try await (sessions, identities, options)
      try Task.checkCancellation()
      guard isAvailable, try await api.authenticatedSessionGeneration() == generation else {
        return
      }
      self.sessions = result.0
      self.identities = result.1
      providers = result.2.oidcProviders.filter(\.enabled)
      passwordLoginEnabled = result.2.passwordLoginEnabled
      currentSessionID = current
    } catch {
      guard isAvailable, !Task.isCancelled else { return }
      if case ConnectionError.expiredSession = error {
        await session.refreshCurrentUser()
      }
      self.error = error.localizedDescription
    }
  }

  func revoke(_ target: Session) async {
    guard isAvailable, !isBusy else { return }
    isBusy = true
    error = nil
    notice = nil
    defer { isBusy = false }
    do {
      try await session.revokeSession(target.id, using: api)
      guard isAvailable else { return }
      sessions.removeAll { $0.id == target.id }
      notice = "The session was revoked. That device must sign in again."
    } catch {
      guard isAvailable else { return }
      self.error = error.localizedDescription
    }
  }

  func link(_ provider: OidcProviderPublic, window: UIWindow) async {
    guard canEditIdentity, !isBusy else { return }
    isBusy = true
    error = nil
    notice = nil
    do {
      try await session.link(provider: provider, window: window)
      if isAvailable { notice = "The sign-in provider was linked to your account." }
    } catch {
      if isAvailable { self.error = error.localizedDescription }
      isBusy = false
      return
    }
    isBusy = false
    await load()
  }

  func unlink(_ target: OidcLinkedIdentity, password: String) async -> Bool {
    guard canEditIdentity, !isBusy else { return false }
    guard !needsPasswordConfirmation || !password.isEmpty else {
      error = "Enter your current password to unlink this provider."
      return false
    }
    isBusy = true
    error = nil
    notice = nil
    defer { isBusy = false }
    do {
      try await api.unlinkIdentity(
        providerID: target.providerId, password: needsPasswordConfirmation ? password : nil)
      guard isAvailable else { return false }
      identities.removeAll { $0.providerId == target.providerId }
      await session.refreshCurrentUser()
      notice = "The sign-in provider was unlinked."
      return true
    } catch {
      guard isAvailable else { return false }
      if case ConnectionError.http(409) = error {
        self.error =
          "This is your last available sign-in provider. Add another sign-in method before unlinking it."
      } else if case ConnectionError.http(400) = error {
        self.error =
          "The provider could not be unlinked. Check your current password and try again."
      } else {
        self.error = error.localizedDescription
      }
      return false
    }
  }

  func close() {
    active = false
    sessions = []
    identities = []
    providers = []
  }
}
