import Foundation
import Observation

@MainActor @Observable
final class PasswordRecoveryModel {
  let profile: ServerProfile
  private let session: SessionModel
  private let api: BookOrbitAPI
  var email = ""
  var resetInput = "" {
    didSet {
      if oldValue != resetInput { confirmedLinkOrigin = nil }
    }
  }
  var newPassword = ""
  var confirmation = ""
  private(set) var isBusy = false
  private(set) var requestAccepted = false
  private(set) var resetCompleted = false
  private(set) var error: String?
  private var pending: Task<Void, Never>?
  private var operationID = UUID()
  private var isClosed = false
  private var confirmedLinkOrigin: String?

  init(session: SessionModel, api: BookOrbitAPI, profile: ServerProfile) {
    self.session = session
    self.api = api
    self.profile = profile
  }

  var isAvailable: Bool {
    !isClosed && session.canRecoverPassword(using: api)
      && (try? ServerProfile(session.serverURL)) == profile
  }

  var canRequest: Bool {
    isAvailable && !isBusy && !requestAccepted
      && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var canReset: Bool {
    isAvailable && !isBusy && !resetCompleted && resetToken != nil
      && validPassword && newPassword == confirmation
  }

  var resetInputIssue: String? {
    guard !resetInput.isEmpty, linkConfirmationOrigin == nil else { return nil }
    do {
      _ = try token(from: resetInput)
      return nil
    } catch { return error.localizedDescription }
  }

  var linkConfirmationOrigin: String? {
    guard let link = try? parsedLink(), !link.matchesServer,
      confirmedLinkOrigin != link.origin
    else { return nil }
    return link.origin
  }

  var passwordIssue: String? {
    guard !newPassword.isEmpty else { return nil }
    if !validPassword {
      return "Use 8 to 1024 characters with an uppercase letter, a lowercase letter, and a digit."
    }
    if !confirmation.isEmpty, newPassword != confirmation {
      return "The passwords do not match."
    }
    return nil
  }

  private var resetToken: String? { try? token(from: resetInput) }

  private var validPassword: Bool {
    (8...1024).contains(newPassword.unicodeScalars.count)
      && newPassword.range(
        of: #"^(?=.*[a-z])(?=.*[A-Z])(?=.*[0-9]).+$"#, options: .regularExpression) != nil
  }

  func requestReset() {
    guard canRequest else { return }
    let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
    guard email.unicodeScalars.count <= 320 else {
      error = "Enter a valid email address."
      return
    }
    beginOperation()
    let id = operationID
    pending = Task {
      defer { finishOperation(id) }
      do {
        try await session.requestPasswordReset(ForgotPasswordRequest(email: email), using: api)
        guard isCurrent(id) else { return }
        self.email = ""
        requestAccepted = true
      } catch {
        guard isCurrent(id), !Task.isCancelled else { return }
        self.error = message(for: error, resetting: false)
      }
    }
  }

  func resetPassword() {
    guard canReset, let token = resetToken else { return }
    let password = newPassword
    beginOperation()
    let id = operationID
    pending = Task {
      defer { finishOperation(id) }
      do {
        try await session.resetPassword(
          ResetPasswordRequest(token: token, newPassword: password), using: api)
        guard isCurrent(id) else { return }
        clearDrafts()
        resetCompleted = true
      } catch {
        guard isCurrent(id), !Task.isCancelled else { return }
        newPassword = ""
        confirmation = ""
        if case ConnectionError.http(400) = error { resetInput = "" }
        if case ConnectionError.denied = error { resetInput = "" }
        self.error = message(for: error, resetting: true)
      }
    }
  }

  func prepareAnotherRequest() {
    guard !isBusy, isAvailable else { return }
    requestAccepted = false
    error = nil
  }

  func confirmLinkForConnectedServer() {
    guard !isBusy, isAvailable, let link = try? parsedLink() else { return }
    confirmedLinkOrigin = link.origin
    error = nil
  }

  func clearResetLink() {
    guard !isBusy else { return }
    resetInput = ""
    newPassword = ""
    confirmation = ""
    confirmedLinkOrigin = nil
    error = nil
  }

  func leaveReset() {
    cancelPending()
    clearResetLink()
  }

  func suspend() {
    cancelPending()
    clearDrafts()
  }

  func close() {
    isClosed = true
    cancelPending()
    clearDrafts()
    error = nil
  }

  private func beginOperation() {
    operationID = UUID()
    isBusy = true
    error = nil
  }

  private func isCurrent(_ id: UUID) -> Bool { id == operationID && isAvailable }

  private func finishOperation(_ id: UUID) {
    guard id == operationID else { return }
    isBusy = false
    pending = nil
  }

  private func cancelPending() {
    operationID = UUID()
    pending?.cancel()
    pending = nil
    isBusy = false
  }

  private func clearDrafts() {
    email = ""
    resetInput = ""
    newPassword = ""
    confirmation = ""
    confirmedLinkOrigin = nil
  }

  private func token(from input: String) throws -> String {
    let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !input.isEmpty, input.utf8.count <= 4096 else {
      throw PasswordRecoveryInputError.invalidToken
    }
    if input.contains("://") {
      let link = try parsedLink()
      guard link.matchesServer || confirmedLinkOrigin == link.origin
      else { throw PasswordRecoveryInputError.differentServer }
      return link.token
    }
    guard validToken(input) else { throw PasswordRecoveryInputError.invalidToken }
    return input
  }

  private func parsedLink() throws -> (token: String, origin: String, matchesServer: Bool) {
    let input = resetInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard input.utf8.count <= 4096,
      let link = URLComponents(string: input),
      let server = URLComponents(url: profile.url, resolvingAgainstBaseURL: false),
      ["http", "https"].contains(link.scheme?.lowercased()),
      let host = link.host, !host.isEmpty,
      link.user == nil, link.password == nil, link.fragment == nil,
      link.path.hasSuffix("/reset-password")
    else { throw PasswordRecoveryInputError.invalidLink }
    let tokens = (link.queryItems ?? []).filter { $0.name == "token" }
    guard tokens.count == 1, let token = tokens.first?.value, validToken(token) else {
      throw PasswordRecoveryInputError.invalidToken
    }
    var origin = URLComponents()
    origin.scheme = link.scheme?.lowercased()
    origin.host = host.lowercased()
    origin.port = link.port
    guard let originURL = origin.url else { throw PasswordRecoveryInputError.invalidLink }
    func port(_ components: URLComponents) -> Int {
      components.port ?? (components.scheme?.lowercased() == "https" ? 443 : 80)
    }
    let matches =
      link.scheme?.lowercased() == server.scheme
      && host.lowercased() == server.host?.lowercased() && port(link) == port(server)
      && link.path == server.path + "/reset-password"
    return (token, originURL.absoluteString, matches)
  }

  private func validToken(_ token: String) -> Bool {
    !token.isEmpty && token.unicodeScalars.count <= 512
      && token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
  }

  private func message(for error: Error, resetting: Bool) -> String {
    switch error {
    case ConnectionError.denied:
      "Password sign-in is disabled on this server. Use an available sign-in provider or contact your administrator."
    case ConnectionError.http(400):
      resetting
        ? "This reset token is invalid, expired, or already used. Request a new reset link."
        : "Enter a valid email address."
    case ConnectionError.http(429):
      resetting
        ? "Too many reset attempts. Wait at least a minute before trying again."
        : "Too many reset requests. This server allows three requests per hour. Try again later."
    case ConnectionError.http(503):
      "Self-service password reset is unavailable. Contact your administrator."
    case ConnectionError.invalidResponse:
      "The server returned an incompatible response."
    default:
      resetting
        ? "The password reset could not be confirmed. Check your connection, then try signing in with your new password before retrying."
        : "Could not request a reset link. Check your connection and try again."
    }
  }
}

private enum PasswordRecoveryInputError: LocalizedError {
  case invalidToken
  case invalidLink
  case differentServer

  var errorDescription: String? {
    switch self {
    case .invalidToken:
      "Paste a reset token of no more than 512 characters, or the reset link from your email."
    case .invalidLink: "Paste the reset link from your BookOrbit email, or its reset token."
    case .differentServer:
      "Confirm that this reset email came from the connected BookOrbit server before using the link."
    }
  }
}
