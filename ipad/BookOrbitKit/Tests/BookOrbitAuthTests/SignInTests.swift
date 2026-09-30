import BookOrbitAuth
import BookOrbitTestSupport
import Foundation
import Testing

@Suite struct SignInTests {
    @Test func passwordSignInUsesTheNativeClientKindAndDeviceLabel() async throws {
        let harness = Harness()
        harness.routeLogin()

        let session = try await harness.makeAuth().signIn(to: harness.address, username: "moon", password: "secret")

        #expect(session.user.username == "moon")
        let body = try #require(harness.server.requests("POST", "/api/v1/auth/login").first).jsonBody()
        #expect(body["username"] as? String == "moon")
        #expect(body["password"] as? String == "secret")
        #expect(body["clientKind"] as? String == "native")
        #expect(body["deviceLabel"] as? String == "BookOrbit iPad App on iPad")
    }
}

@Suite struct RestoredSessionTests {
    @Test func aSignedInSessionSurvivesARelaunchAndAuthenticatesRequests() async throws {
        let harness = Harness()
        harness.routeLogin(access: "access-1")
        harness.routeMe()
        _ = try await harness.makeAuth().signIn(to: harness.address, username: "moon", password: "secret")

        let relaunched = harness.makeAuth()
        let session = try #require(await relaunched.restoredSession())
        _ = try await session.client.authControllerMe()

        #expect(session.user.username == "moon")
        #expect(harness.bearerTokens("GET", "/api/v1/auth/me") == ["Bearer access-1"])
    }

    @Test func nothingIsRestoredBeforeTheFirstSignIn() async {
        #expect(await Harness().makeAuth().restoredSession() == nil)
    }
}

@Suite struct SignInFailureTests {
    @Test func wrongPasswordIsALoginFailure() async throws {
        let harness = Harness()
        harness.server.route("POST", "/api/v1/auth/login") { _ in
            .json(401, ["statusCode": 401, "message": "Invalid credentials"])
        }

        await #expect(throws: SignInError.invalidCredentials) {
            try await harness.makeAuth().signIn(to: harness.address, username: "moon", password: "wrong")
        }
        #expect(await harness.makeAuth().restoredSession() == nil)
    }

    @Test func anUnreachableServerIsNotALoginFailure() async throws {
        let harness = Harness()
        harness.routeLogin()
        harness.server.goOffline()

        await #expect(throws: SignInError.serverUnreachable) {
            try await harness.makeAuth().signIn(to: harness.address, username: "moon", password: "secret")
        }
    }

    @Test func aLockedAccountReportsWhenToRetry() async throws {
        let harness = Harness()
        harness.server.route("POST", "/api/v1/auth/login") { _ in
            .json(401, ["statusCode": 401, "message": "Locked", "errorCode": "account_locked", "retryAfterSeconds": 120])
        }

        await #expect(throws: SignInError.accountLocked(retryAfterSeconds: 120)) {
            try await harness.makeAuth().signIn(to: harness.address, username: "moon", password: "secret")
        }
    }
}
