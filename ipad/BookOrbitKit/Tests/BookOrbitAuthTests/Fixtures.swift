import BookOrbitAuth
import BookOrbitTestSupport
import Foundation
import Synchronization

enum Fixtures {
    static let refreshToken1 = String(repeating: "a", count: 64)
    static let refreshToken2 = String(repeating: "b", count: 64)
    static let refreshToken3 = String(repeating: "c", count: 64)

    static func iso(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
    }

    static func credentials(access: String, refresh: String, accessExpiresIn: TimeInterval = 900) -> [String: Any] {
        [
            "accessToken": access,
            "accessTokenExpiresAt": iso(Date().addingTimeInterval(accessExpiresIn)),
            "refreshToken": refresh,
            "refreshTokenExpiresAt": iso(Date().addingTimeInterval(7 * 86_400)),
            "sessionId": 17,
        ]
    }

    static func loginResponse(access: String = "access-1", refresh: String = refreshToken1, accessExpiresIn: TimeInterval = 900) -> [String: Any] {
        var body = credentials(access: access, refresh: refresh, accessExpiresIn: accessExpiresIn)
        body["user"] = [
            "id": 42, "username": "moon", "name": "Moon", "active": true, "isSuperuser": false,
            "isDefaultPassword": false, "settings": [:], "provisioningMethod": "local", "permissions": [],
        ] as [String: Any]
        return body
    }

    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "bookorbit-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}

/// An AuthManager wired to a stub server, with storage that outlives the manager so tests can
/// simulate an app relaunch by building a second manager over the same stores.
struct Harness {
    let server = StubServer()
    let sessionStore = InMemorySessionStore()
    let storageRoot = Fixtures.temporaryDirectory()

    var address: ServerAddress { try! ServerAddress(server.baseURL.absoluteString) }

    func makeAuth() -> AuthManager {
        AuthManager(
            sessionStore: sessionStore,
            accountStorage: AccountStorage(root: storageRoot),
            urlSessionConfiguration: StubServer.sessionConfiguration,
            deviceLabel: "BookOrbit iPad App on iPad"
        )
    }

    func routeLogin(access: String = "access-1", refresh: String = Fixtures.refreshToken1, accessExpiresIn: TimeInterval = 900) {
        server.route("POST", "/api/v1/auth/login") { _ in
            .json(200, Fixtures.loginResponse(access: access, refresh: refresh, accessExpiresIn: accessExpiresIn))
        }
    }
}

extension Harness {
    func routeMe() {
        server.route("GET", "/api/v1/auth/me") { _ in
            .json(200, ["id": 42, "username": "moon", "name": "Moon"])
        }
    }

    func bearerTokens(_ method: String, _ path: String) -> [String?] {
        server.requests(method, path).map { $0.header("Authorization") }
    }
}

extension Harness {
    /// Answers refreshes by rotating through the given tokens, and records each refresh token presented.
    func routeRefresh(_ rotations: [(access: String, refresh: String)]) {
        let remaining = Mutex(rotations)
        server.route("POST", "/api/v1/auth/refresh") { _ in
            guard let next = remaining.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else {
                return .json(401, ["statusCode": 401, "message": "Unauthorized"])
            }
            return .json(200, Fixtures.credentials(access: next.access, refresh: next.refresh))
        }
    }

    func presentedRefreshTokens() -> [String?] {
        server.requests("POST", "/api/v1/auth/refresh").map { $0.jsonBody()["refreshToken"] as? String }
    }

    func signIn(accessExpiresIn: TimeInterval = 900) async throws -> AuthenticatedSession {
        routeLogin(access: "access-1", refresh: Fixtures.refreshToken1, accessExpiresIn: accessExpiresIn)
        return try await makeAuth().signIn(to: address, username: "moon", password: "secret")
    }
}
