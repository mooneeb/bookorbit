import BookOrbitAuth
import Foundation

extension StubServer {
    /// Signs in against this stub server and returns the session, for tests of features that need
    /// an authenticated client. The access token is `access-1`.
    public func signedInSession(storageRoot: URL = FileManager.default.temporaryDirectory.appending(path: "bookorbit-tests-\(UUID().uuidString)")) async throws -> AuthenticatedSession {
        route("POST", "/api/v1/auth/login") { _ in
            .json(200, [
                "accessToken": "access-1",
                "accessTokenExpiresAt": "2999-01-01T00:00:00.000Z",
                "refreshToken": String(repeating: "a", count: 64),
                "refreshTokenExpiresAt": "2999-01-01T00:00:00.000Z",
                "sessionId": 1,
                "user": ["id": 42, "username": "moon", "name": "Moon"],
            ])
        }
        let auth = AuthManager(
            sessionStore: InMemorySessionStore(),
            accountStorage: AccountStorage(root: storageRoot),
            urlSessionConfiguration: StubServer.sessionConfiguration,
            deviceLabel: "Tests"
        )
        return try await auth.signIn(to: ServerAddress(baseURL.absoluteString), username: "moon", password: "secret")
    }
}
