import Foundation

private final class SameOriginRedirects: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    let origin = task.originalRequest?.url
    let target = request.url
    let matches =
      origin?.scheme == target?.scheme && origin?.host == target?.host
      && origin?.port == target?.port
    completionHandler(matches ? request : nil)
  }
}

actor BookOrbitAPI {
  let profile: ServerProfile
  private let transport: URLSession
  private let store: CredentialStore
  private var saved: SavedSession?
  private var refreshTask: Task<NativeCredentials, Error>?
  private var sessionGeneration = UUID()

  init(profile: ServerProfile) throws {
    self.profile = profile
    store = CredentialStore(account: profile.url.absoluteString)
    saved = try store.read()
    let config = URLSessionConfiguration.ephemeral
    config.httpShouldSetCookies = false
    config.httpCookieStorage = nil
    config.timeoutIntervalForRequest = 20
    transport = URLSession(
      configuration: config, delegate: SameOriginRedirects(), delegateQueue: nil)
  }

  func loginOptions() async throws -> LoginOptionsResponse {
    try await send("auth/login-options", authenticated: false)
  }

  func login(username: String, password: String) async throws -> AuthUser {
    let body = LoginRequest(
      username: username, password: password, clientKind: "native",
      deviceLabel: "BookOrbit private iPad")
    let response: NativeAuthResponse = try await send(
      "auth/login", method: "POST", body: JSONEncoder().encode(body), authenticated: false)
    return try accept(response)
  }

  func oidcState(slug: String) async throws -> OidcStateResponse {
    try await send(
      "auth/oidc/\(slug)/state", method: "POST", body: Data("{}".utf8), authenticated: false)
  }

  func completeOIDC(_ callback: OidcCallbackRequest) async throws -> AuthUser {
    let response: NativeAuthResponse = try await send(
      "auth/oidc/callback", method: "POST", body: JSONEncoder().encode(callback),
      authenticated: false)
    return try accept(response)
  }

  private func accept(_ response: NativeAuthResponse) throws -> AuthUser {
    let session = SavedSession(
      credentials: NativeCredentials(
        accessToken: response.accessToken, accessTokenExpiresAt: response.accessTokenExpiresAt,
        refreshToken: response.refreshToken, refreshTokenExpiresAt: response.refreshTokenExpiresAt,
        sessionId: response.sessionId), user: response.user)
    try store.write(session)
    sessionGeneration = UUID()
    saved = session
    return response.user
  }

  func resume() async throws -> AuthUser? {
    guard saved != nil else { return nil }
    do {
      let user: AuthUser = try await send("auth/me")
      guard var session = saved else { throw ConnectionError.expiredSession }
      session.user = user
      try store.write(session)
      saved = session
      return user
    } catch ConnectionError.expiredSession {
      try store.remove()
      saved = nil
      throw ConnectionError.expiredSession
    }
  }

  func logout() async throws {
    guard let saved else { return }
    let body = try JSONEncoder().encode(
      RefreshRequest(refreshToken: saved.credentials.refreshToken))
    let (_, response) = try await raw("auth/logout", method: "POST", body: body)
    try validate(response)
    try store.remove()
    sessionGeneration = UUID()
    refreshTask?.cancel()
    self.saved = nil
  }

  func changePassword(current: String, new: String) async throws {
    let body = try JSONEncoder().encode(
      ChangePasswordRequest(currentPassword: current, newPassword: new))
    let (_, response) = try await raw(
      "auth/change-password", method: "POST", body: body, token: accessToken())
    try validate(response)
    try store.remove()
    sessionGeneration = UUID()
    saved = nil
  }

  func send<T: Decodable & Sendable>(
    _ path: String, method: String = "GET", body: Data? = nil,
    authenticated: Bool = true
  ) async throws -> T {
    let token = authenticated ? try await accessToken() : nil
    var (data, response) = try await raw(path, method: method, body: body, token: token)
    if response.statusCode == 401 && authenticated {
      let credentials = try await refresh()
      (data, response) = try await raw(
        path, method: method, body: body, token: credentials.accessToken)
      if response.statusCode == 401 { throw ConnectionError.expiredSession }
    }
    try validate(response)
    do { return try JSONDecoder().decode(T.self, from: data) } catch {
      throw ConnectionError.invalidResponse
    }
  }

  private func accessToken() async throws -> String {
    guard let saved else { throw ConnectionError.expiredSession }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let expiry = formatter.date(from: saved.credentials.accessTokenExpiresAt)
    if let expiry, expiry.timeIntervalSinceNow > 30 { return saved.credentials.accessToken }
    return try await refresh().accessToken
  }

  private func refresh() async throws -> NativeCredentials {
    if let refreshTask { return try await refreshTask.value }
    guard var saved else { throw ConnectionError.expiredSession }
    let generation = sessionGeneration
    let body = try JSONEncoder().encode(
      RefreshRequest(refreshToken: saved.credentials.refreshToken))
    let task = Task<NativeCredentials, Error> {
      let (data, response) = try await self.raw("auth/refresh", method: "POST", body: body)
      if response.statusCode == 401 { throw ConnectionError.expiredSession }
      try self.validate(response)
      return try JSONDecoder().decode(NativeCredentials.self, from: data)
    }
    refreshTask = task
    defer { refreshTask = nil }
    let credentials = try await task.value
    guard generation == sessionGeneration else { throw ConnectionError.expiredSession }
    saved.credentials = credentials
    try store.write(saved)
    self.saved = saved
    return credentials
  }

  private func raw(_ path: String, method: String, body: Data?, token: String? = nil) async throws
    -> (Data, HTTPURLResponse)
  {
    var request = URLRequest(url: profile.endpoint(path))
    request.httpMethod = method
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    let (data, response) = try await transport.data(for: request)
    guard let response = response as? HTTPURLResponse else { throw ConnectionError.invalidResponse }
    return (data, response)
  }

  private func validate(_ response: HTTPURLResponse) throws {
    if response.statusCode == 403 { throw ConnectionError.denied }
    guard (200..<300).contains(response.statusCode) else {
      throw ConnectionError.http(response.statusCode)
    }
  }
}
