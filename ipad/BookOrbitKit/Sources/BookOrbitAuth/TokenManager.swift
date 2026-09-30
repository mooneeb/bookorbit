import BookOrbitAPI
import Foundation
import HTTPTypes
import OpenAPIRuntime
import os

/// Owns one session's tokens: hands out a valid access token, refreshes it when it expires or the
/// server rejects it, and persists every rotated refresh token. Concurrent callers share a single
/// refresh, because the server rotates the refresh token on each use.
actor TokenManager {
    private static let refreshMargin: TimeInterval = 30
    private static let logger = Logger(subsystem: "app.bookorbit.ipad", category: "auth")

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

    /// Called after the server answered 401 to `rejectedToken`. Another request may already have
    /// refreshed it, in which case the newer token is returned without refreshing again.
    func accessToken(replacing rejectedToken: String) async throws -> String {
        guard let credentials = stored?.credentials else { throw SessionError.signedOut }
        if credentials.accessToken != rejectedToken { return credentials.accessToken }
        return try await refresh()
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
        let started = ContinuousClock.now
        let output: Operations.AuthControllerRefresh.Output
        do {
            output = try await refreshClient.authControllerRefresh(body: .json(.init(refreshToken: current.credentials.refreshToken)))
        } catch {
            Self.logger.error("[auth.refresh] [fail] sessionId=\(current.credentials.sessionId) durationMs=\(started.millisecondsElapsed) errorClass=\(type(of: error)) - refresh failed")
            throw Reachability.isUnreachable(error) ? SessionError.serverUnreachable : SessionError.unexpectedResponse(statusCode: 0)
        }

        switch output {
        case .ok(let ok):
            let refreshed = try ok.body.json
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
            return refreshed.accessToken
        case .default(let statusCode, _) where statusCode == 400 || statusCode == 401 || statusCode == 403:
            Self.logger.notice("[auth.refresh] [fail] sessionId=\(current.credentials.sessionId) durationMs=\(started.millisecondsElapsed) status=\(statusCode) - session expired")
            stored = nil
            try? sessionStore.clear()
            await onSessionExpired()
            throw SessionError.sessionExpired
        case .default(let statusCode, _):
            throw SessionError.unexpectedResponse(statusCode: statusCode)
        }
    }
}

extension ContinuousClock.Instant {
    var millisecondsElapsed: Int64 {
        let elapsed = ContinuousClock.now - self
        return elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
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
        let token = try await tokens.validAccessToken()
        let (response, responseBody) = try await next(request.authorized(with: token), body, baseURL)
        guard response.status == .unauthorized else { return (response, responseBody) }

        let replacement = try await tokens.accessToken(replacing: token)
        return try await next(request.authorized(with: replacement), body, baseURL)
    }
}

extension HTTPRequest {
    func authorized(with token: String) -> HTTPRequest {
        var request = self
        request.headerFields[.authorization] = "Bearer \(token)"
        return request
    }
}
