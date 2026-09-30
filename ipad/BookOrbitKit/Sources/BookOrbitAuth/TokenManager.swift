import BookOrbitAPI
import BookOrbitCore
import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Concurrent callers share a single refresh, because the server rotates the refresh token on each
/// use and a second refresh with the old token would race the first.
actor TokenManager {
    private static let refreshMargin: TimeInterval = 30
    private static let log = EventLog(category: "auth")

    private var stored: StoredSession?
    private var refreshTask: Task<String, any Error>?
    private let sessionStore: any SessionStore
    private let refreshClient: Client
    private let onSessionExpired: @Sendable () async -> Void

    init(stored: StoredSession, sessionStore: any SessionStore, refreshClient: Client, onSessionExpired: @escaping @Sendable () async -> Void) {
        self.stored = stored
        self.sessionStore = sessionStore
        self.refreshClient = refreshClient
        self.onSessionExpired = onSessionExpired
    }

    var refreshToken: String? { stored?.credentials.refreshToken }

    func validAccessToken() async throws -> String {
        guard let credentials = stored?.credentials else { throw SessionError.signedOut }
        if credentials.accessTokenExpiresAt.timeIntervalSinceNow > Self.refreshMargin {
            return credentials.accessToken
        }
        return try await refresh()
    }

    /// Another request may already have refreshed the rejected token; its replacement is reused
    /// instead of refreshing twice.
    func accessToken(replacing rejectedToken: String) async throws -> String {
        guard let credentials = stored?.credentials else { throw SessionError.signedOut }
        if credentials.accessToken != rejectedToken { return credentials.accessToken }
        return try await refresh()
    }

    /// Sends with a valid access token and, if the server rejects it, once more with a refreshed one.
    nonisolated func sendAuthorized<Response: Sendable>(
        _ send: @Sendable (String) async throws -> Response,
        isRejected: @Sendable (Response) -> Bool
    ) async throws -> Response {
        let token = try await validAccessToken()
        let response = try await send(token)
        guard isRejected(response) else { return response }
        return try await send(try await accessToken(replacing: token))
    }

    func end() {
        stored = nil
        refreshTask?.cancel()
    }

    private func refresh() async throws -> String {
        if let refreshTask { return try await refreshTask.value }
        let task = Task { try await performRefresh() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefresh() async throws -> String {
        guard let current = stored else { throw SessionError.signedOut }
        let sessionId = current.credentials.sessionId
        let started = ContinuousClock.now
        Self.log.info("[auth.refresh] [start] sessionId=\(sessionId) - refresh started")

        let output: Operations.AuthControllerRefresh.Output
        do {
            output = try await refreshClient.authControllerRefresh(body: .json(.init(refreshToken: current.credentials.refreshToken)))
        } catch {
            Self.log.error("[auth.refresh] [fail] sessionId=\(sessionId) durationMs=\(started.millisecondsElapsed) \(failureFields(error)) - refresh failed")
            throw Reachability.sessionError(forTransportError: error)
        }

        switch output {
        case .ok(let ok):
            guard let refreshed = try? ok.body.json else {
                Self.log.error("[auth.refresh] [fail] sessionId=\(sessionId) durationMs=\(started.millisecondsElapsed) errorClass=DecodingError error=\"unreadable body\" - refresh failed")
                throw SessionError.invalidResponse
            }
            guard var next = stored else { throw SessionError.signedOut }
            next.credentials = Credentials(
                accessToken: refreshed.accessToken,
                accessTokenExpiresAt: refreshed.accessTokenExpiresAt,
                refreshToken: refreshed.refreshToken,
                refreshTokenExpiresAt: refreshed.refreshTokenExpiresAt,
                sessionId: refreshed.sessionId
            )
            stored = next
            try sessionStore.save(next)
            Self.log.info("[auth.refresh] [end] sessionId=\(sessionId) durationMs=\(started.millisecondsElapsed) - refresh completed")
            return refreshed.accessToken
        case .default(let statusCode, _) where statusCode == 400 || statusCode == 401 || statusCode == 403:
            Self.log.notice("[auth.refresh] [fail] sessionId=\(sessionId) durationMs=\(started.millisecondsElapsed) status=\(statusCode) errorClass=SessionError error=\"session expired\" - refresh rejected")
            stored = nil
            try? sessionStore.clear()
            await onSessionExpired()
            throw SessionError.sessionExpired
        case .default(let statusCode, _):
            Self.log.error("[auth.refresh] [fail] sessionId=\(sessionId) durationMs=\(started.millisecondsElapsed) status=\(statusCode) errorClass=SessionError error=\"unexpected status\" - refresh failed")
            throw SessionError.unexpectedResponse(statusCode: statusCode)
        }
    }
}

struct BearerAuthMiddleware: ClientMiddleware {
    let tokens: TokenManager

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        try await tokens.sendAuthorized(
            { token in try await next(request.authorized(with: token), body, baseURL) },
            isRejected: { $0.0.status == .unauthorized }
        )
    }
}

extension HTTPRequest {
    func authorized(with token: String) -> HTTPRequest {
        var request = self
        request.headerFields[.authorization] = "Bearer \(token)"
        return request
    }
}
