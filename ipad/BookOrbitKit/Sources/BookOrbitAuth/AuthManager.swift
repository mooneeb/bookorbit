import BookOrbitAPI
import BookOrbitCore
import Foundation
import OpenAPIRuntime

/// Uses the server's native client kind, so tokens come back in response bodies instead of cookies.
public actor AuthManager {
    private static let log = EventLog(category: "auth")
    private let sessionStore: any SessionStore
    private let accountStorage: AccountStorage
    private let urlSession: URLSession
    private let deviceLabel: String
    private var current: AuthenticatedSession?
    private let events: AsyncStream<SessionEvent>.Continuation

    /// Session changes the reader did not ask for, such as the session being revoked on the server.
    public nonisolated let sessionEvents: AsyncStream<SessionEvent>

    public init(
        sessionStore: any SessionStore,
        accountStorage: AccountStorage,
        urlSessionConfiguration: URLSessionConfiguration = .default,
        deviceLabel: String = DeviceLabel.current
    ) {
        self.sessionStore = sessionStore
        self.accountStorage = accountStorage
        self.urlSession = URLSession(configuration: urlSessionConfiguration)
        self.deviceLabel = deviceLabel
        (sessionEvents, events) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
    }

    public func restoredSession() -> AuthenticatedSession? {
        if let current { return current }
        guard let stored = try? sessionStore.load() else { return nil }
        return makeSession(stored)
    }

    public func checkServer(_ server: ServerAddress) async throws(ServerCheckError) -> LoginOptions {
        let client = BookOrbitClient.make(serverURL: server.baseURL, session: urlSession)
        do {
            let options = try await client.authControllerLoginOptions().ok.body.json
            return LoginOptions(
                passwordLoginEnabled: options.passwordLoginEnabled,
                singleSignOnProviders: options.oidcProviders.map(\.displayName)
            )
        } catch {
            throw Reachability.isUnreachable(error) ? .serverUnreachable : .notABookOrbitServer
        }
    }

    public func signIn(to server: ServerAddress, username: String, password: String) async throws -> AuthenticatedSession {
        let started = ContinuousClock.now
        Self.log.info("[auth.sign_in] [start] method=password - sign in started")
        do {
            let session = try await performSignIn(to: server, username: username, password: password)
            Self.log.info("[auth.sign_in] [end] userId=\(session.user.id) sessionId=\(session.sessionId) durationMs=\(started.millisecondsElapsed) - sign in completed")
            return session
        } catch {
            Self.log.notice("[auth.sign_in] [fail] method=password durationMs=\(started.millisecondsElapsed) \(failureFields(error)) - sign in failed")
            throw error
        }
    }

    private func performSignIn(to server: ServerAddress, username: String, password: String) async throws -> AuthenticatedSession {
        let client = BookOrbitClient.make(serverURL: server.baseURL, session: urlSession)
        let output: Operations.AuthControllerLogin.Output
        do {
            output = try await client.authControllerLogin(
                body: .json(.init(username: username, password: password, clientKind: .native, deviceLabel: deviceLabel))
            )
        } catch {
            throw Reachability.isUnreachable(error) ? SignInError.serverUnreachable : SignInError.noResponse
        }

        let response: Components.Schemas.NativeAuthResponse
        switch output {
        case .ok(let ok):
            response = try ok.body.json
        case .default(let statusCode, let failure):
            throw Self.signInError(statusCode: statusCode, body: try? failure.body.json)
        }

        let stored = StoredSession(
            server: server,
            user: AccountUser(id: response.user.id, username: response.user.username, name: response.user.name),
            credentials: Credentials(
                accessToken: response.accessToken,
                accessTokenExpiresAt: response.accessTokenExpiresAt,
                refreshToken: response.refreshToken,
                refreshTokenExpiresAt: response.refreshTokenExpiresAt,
                sessionId: response.sessionId
            )
        )
        await current?.tokens.end()
        try accountStorage.claim(server: server, userId: stored.user.id)
        try sessionStore.save(stored)
        return makeSession(stored)
    }

    /// Local data is wiped before the server is told, so an unreachable server never leaves an
    /// account's data behind.
    public func signOut() async -> SignOutOutcome {
        let started = ContinuousClock.now
        let session = restoredSession()
        let sessionId = session.map { String($0.sessionId) } ?? "none"
        Self.log.info("[auth.sign_out] [start] sessionId=\(sessionId) - sign out started")
        let server = session?.server
        let refreshToken = await session?.tokens.refreshToken
        await session?.tokens.end()
        current = nil
        wipeLocalData()

        guard let server, let refreshToken else {
            Self.log.info("[auth.sign_out] [end] sessionId=\(sessionId) durationMs=\(started.millisecondsElapsed) revoked=false - no session to revoke")
            return .revokedOnThisDeviceOnly
        }
        let client = BookOrbitClient.make(serverURL: server.baseURL, session: urlSession)
        do {
            _ = try await client.authControllerLogout(body: .json(.init(refreshToken: refreshToken))).ok
            Self.log.info("[auth.sign_out] [end] sessionId=\(sessionId) durationMs=\(started.millisecondsElapsed) revoked=true - sign out completed")
            return .revoked
        } catch {
            Self.log.notice("[auth.sign_out] [fail] sessionId=\(sessionId) durationMs=\(started.millisecondsElapsed) revoked=false \(failureFields(error)) - server revoke failed, local data wiped")
            return .revokedOnThisDeviceOnly
        }
    }

    private func wipeLocalData() {
        do {
            try sessionStore.clear()
        } catch {
            Self.log.error("[auth.wipe] [fail] target=sessionStore \(failureFields(error)) - could not clear tokens")
        }
        urlSession.configuration.urlCache?.removeAllCachedResponses()
        do {
            try accountStorage.wipe()
        } catch {
            Self.log.error("[auth.wipe] [fail] target=accountStorage \(failureFields(error)) - could not wipe account data")
        }
    }

    private static func signInError(statusCode: Int, body: Components.Schemas.ApiError?) -> SignInError {
        switch (statusCode, body?.errorCode) {
        case (_, "account_locked"): .accountLocked(retryAfterSeconds: body?.retryAfterSeconds)
        case (_, "password_auth_disabled"): .passwordLoginDisabled
        case (401, _): .invalidCredentials
        case (429, _): .tooManyAttempts
        default: .unexpectedResponse(statusCode: statusCode)
        }
    }

    private func makeSession(_ stored: StoredSession) -> AuthenticatedSession {
        let sessionId = stored.credentials.sessionId
        let tokens = TokenManager(
            stored: stored,
            sessionStore: sessionStore,
            refreshClient: BookOrbitClient.make(serverURL: stored.server.baseURL, session: urlSession),
            onSessionExpired: { [weak self, events] in
                await self?.forget(sessionId: sessionId)
                events.yield(.sessionExpired)
            }
        )
        let client = BookOrbitClient.make(
            serverURL: stored.server.baseURL,
            session: urlSession,
            middlewares: [BearerAuthMiddleware(tokens: tokens)]
        )
        let session = AuthenticatedSession(stored: stored, client: client, tokens: tokens, urlSession: urlSession)
        current = session
        return session
    }

    private func forget(sessionId: Int) {
        if current?.sessionId == sessionId { current = nil }
    }
}

public final class AuthenticatedSession: Sendable {
    public let server: ServerAddress
    public let user: AccountUser
    let sessionId: Int
    /// Requests carry the access token, which refreshes silently.
    public let client: Client
    let tokens: TokenManager
    private let urlSession: URLSession

    init(stored: StoredSession, client: Client, tokens: TokenManager, urlSession: URLSession) {
        server = stored.server
        user = stored.user
        sessionId = stored.credentials.sessionId
        self.client = client
        self.tokens = tokens
        self.urlSession = urlSession
    }

    /// For responses the generated client cannot model, such as images and book files. Throws
    /// `SessionError`.
    public func data(path: String, queryItems: [URLQueryItem] = []) async throws -> Data {
        var url = server.baseURL.appending(path: path)
        if !queryItems.isEmpty { url.append(queryItems: queryItems) }

        let token = try await tokens.validAccessToken()
        var (data, status) = try await get(url, token: token)
        if status == 401 {
            (data, status) = try await get(url, token: try await tokens.accessToken(replacing: token))
        }
        guard (200..<300).contains(status) else { throw SessionError.unexpectedResponse(statusCode: status) }
        return data
    }

    private func get(_ url: URL, token: String) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await urlSession.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw Reachability.sessionError(forTransportError: error)
        }
    }
}
