import BookOrbitAuth
import BookOrbitTestSupport
import Foundation
import Testing

@Suite struct TokenRefreshTests {
    @Test func anExpiredAccessTokenRefreshesSilentlyBeforeTheRequest() async throws {
        let harness = Harness()
        harness.routeMe()
        harness.routeRefresh([("access-2", Fixtures.refreshToken2)])
        let session = try await harness.signIn(accessExpiresIn: -60)

        _ = try await session.client.authControllerMe().ok

        #expect(harness.presentedRefreshTokens() == [Fixtures.refreshToken1])
        #expect(harness.bearerTokens("GET", "/api/v1/auth/me") == ["Bearer access-2"])
    }

    @Test func theRotatedRefreshTokenIsKeptForTheNextLaunch() async throws {
        let harness = Harness()
        harness.routeMe()
        harness.routeRefresh([("access-2", Fixtures.refreshToken2), ("access-3", Fixtures.refreshToken3)])
        let session = try await harness.signIn(accessExpiresIn: -60)
        _ = try await session.client.authControllerMe()

        harness.server.route("GET", "/api/v1/auth/me") { request in
            request.header("Authorization") == "Bearer access-3"
                ? .json(200, ["id": 42, "username": "moon", "name": "Moon"])
                : .json(401, ["statusCode": 401, "message": "Unauthorized"])
        }
        let relaunched = try #require(await harness.makeAuth().restoredSession())
        _ = try await relaunched.client.authControllerMe().ok

        #expect(harness.presentedRefreshTokens() == [Fixtures.refreshToken1, Fixtures.refreshToken2])
    }

    @Test func aRejectedAccessTokenIsRefreshedAndTheRequestRetriedOnce() async throws {
        let harness = Harness()
        harness.routeRefresh([("access-2", Fixtures.refreshToken2)])
        harness.server.route("GET", "/api/v1/auth/me") { request in
            request.header("Authorization") == "Bearer access-2"
                ? .json(200, ["id": 42, "username": "moon", "name": "Moon"])
                : .json(401, ["statusCode": 401, "message": "Unauthorized"])
        }
        let session = try await harness.signIn()

        _ = try await session.client.authControllerMe().ok

        #expect(harness.bearerTokens("GET", "/api/v1/auth/me") == ["Bearer access-1", "Bearer access-2"])
        #expect(harness.presentedRefreshTokens().count == 1)
    }

    @Test func concurrentRequestsShareOneRefresh() async throws {
        let harness = Harness()
        harness.routeMe()
        harness.routeRefresh([("access-2", Fixtures.refreshToken2), ("access-3", Fixtures.refreshToken3)])
        let session = try await harness.signIn(accessExpiresIn: -60)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { _ = try await session.client.authControllerMe().ok }
            }
            try await group.waitForAll()
        }

        #expect(harness.presentedRefreshTokens() == [Fixtures.refreshToken1])
        #expect(Set(harness.bearerTokens("GET", "/api/v1/auth/me")) == ["Bearer access-2"])
    }

    @Test func aRevokedSessionEndsAndIsNotRestored() async throws {
        let harness = Harness()
        harness.routeMe()
        harness.routeRefresh([])
        let auth = harness.makeAuth()
        harness.routeLogin(access: "access-1", refresh: Fixtures.refreshToken1, accessExpiresIn: -60)
        let session = try await auth.signIn(to: harness.address, username: "moon", password: "secret")
        let events = auth.sessionEvents

        let error = await #expect(throws: (any Error).self) {
            _ = try await session.client.authControllerMe()
        }
        #expect(error.flatMap(SessionError.init) == .sessionExpired)

        #expect(await auth.restoredSession() == nil)
        #expect(await harness.makeAuth().restoredSession() == nil)
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == .sessionExpired)
    }

    @Test func aRefreshWhileOfflineKeepsTheSession() async throws {
        let harness = Harness()
        harness.routeRefresh([("access-2", Fixtures.refreshToken2)])
        let session = try await harness.signIn(accessExpiresIn: -60)
        harness.server.goOffline()

        let error = await #expect(throws: (any Error).self) {
            _ = try await session.client.authControllerMe()
        }
        #expect(error.flatMap(SessionError.init) == .serverUnreachable)

        #expect(await harness.makeAuth().restoredSession() != nil)
    }
}
