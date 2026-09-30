import BookOrbitAuth
import BookOrbitTestSupport
import Foundation
import Testing

@Suite struct SignOutTests {
    private func writeOfflineBook(_ harness: Harness) throws -> URL {
        let downloads = try AccountStorage(root: harness.storageRoot).directory(named: "Downloads")
        let file = downloads.appending(path: "book-7.epub")
        try Data("offline book".utf8).write(to: file)
        return file
    }

    private func routeLogout(_ harness: Harness) {
        harness.server.route("POST", "/api/v1/auth/logout") { _ in .json(200, [:]) }
    }

    @Test func signingOutRevokesTheSessionOnTheServer() async throws {
        let harness = Harness()
        routeLogout(harness)
        let auth = harness.makeAuth()
        harness.routeLogin(refresh: Fixtures.refreshToken1)
        _ = try await auth.signIn(to: harness.address, username: "moon", password: "secret")

        let outcome = await auth.signOut()

        #expect(outcome == .revoked)
        let logout = try #require(harness.server.requests("POST", "/api/v1/auth/logout").first)
        #expect(logout.jsonBody()["refreshToken"] as? String == Fixtures.refreshToken1)
    }

    @Test func signingOutWipesLocalDataAndForgetsTheSession() async throws {
        let harness = Harness()
        routeLogout(harness)
        let auth = harness.makeAuth()
        harness.routeLogin()
        _ = try await auth.signIn(to: harness.address, username: "moon", password: "secret")
        let offlineBook = try writeOfflineBook(harness)

        _ = await auth.signOut()

        #expect(!FileManager.default.fileExists(atPath: offlineBook.path()))
        #expect(await auth.restoredSession() == nil)
        #expect(await harness.makeAuth().restoredSession() == nil)
    }

    @Test func signingOutWhileOfflineStillWipesLocalData() async throws {
        let harness = Harness()
        let auth = harness.makeAuth()
        harness.routeLogin()
        _ = try await auth.signIn(to: harness.address, username: "moon", password: "secret")
        let offlineBook = try writeOfflineBook(harness)
        harness.server.goOffline()

        let outcome = await auth.signOut()

        #expect(outcome == .revokedOnThisDeviceOnly)
        #expect(!FileManager.default.fileExists(atPath: offlineBook.path()))
        #expect(await harness.makeAuth().restoredSession() == nil)
    }

    @Test func aSignedOutSessionCanNoLongerMakeRequests() async throws {
        let harness = Harness()
        routeLogout(harness)
        harness.routeMe()
        let auth = harness.makeAuth()
        harness.routeLogin()
        let session = try await auth.signIn(to: harness.address, username: "moon", password: "secret")

        _ = await auth.signOut()

        let error = await #expect(throws: (any Error).self) {
            _ = try await session.client.authControllerMe()
        }
        #expect(error.flatMap(SessionError.init) == .signedOut)
        #expect(harness.server.requests("GET", "/api/v1/auth/me").isEmpty)
    }
}

@Suite struct AccountSwitchTests {
    private func signInAfterExpiry(_ harness: Harness, userId: Int) async throws {
        harness.server.route("POST", "/api/v1/auth/login") { _ in
            var body = Fixtures.loginResponse()
            body["user"] = ["id": userId, "username": "user\(userId)", "name": "User \(userId)"]
            return .json(200, body)
        }
        _ = try await harness.makeAuth().signIn(to: harness.address, username: "user\(userId)", password: "secret")
    }

    private func leftoverFile(_ harness: Harness) throws -> URL {
        let file = try AccountStorage(root: harness.storageRoot).directory(named: "Outbox").appending(path: "pending.json")
        try Data("[]".utf8).write(to: file)
        return file
    }

    @Test func signingInAsAnotherAccountStartsFromNothing() async throws {
        let harness = Harness()
        try await signInAfterExpiry(harness, userId: 42)
        let file = try leftoverFile(harness)

        try await signInAfterExpiry(harness, userId: 7)

        #expect(!FileManager.default.fileExists(atPath: file.path()))
    }

    @Test func signingInAgainAsTheSameAccountKeepsItsData() async throws {
        let harness = Harness()
        try await signInAfterExpiry(harness, userId: 42)
        let file = try leftoverFile(harness)

        try await signInAfterExpiry(harness, userId: 42)

        #expect(FileManager.default.fileExists(atPath: file.path()))
    }
}
