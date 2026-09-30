import BookOrbitAuth
import BookOrbitTestSupport
import Foundation
import Testing

@Suite struct ServerCheckTests {
    @Test func aBookOrbitServerReportsHowItAcceptsSignIns() async throws {
        let harness = Harness()
        harness.server.route("GET", "/api/v1/auth/login-options") { _ in
            .json(200, [
                "passwordLoginEnabled": true, "allowRegistration": false,
                "oidcProviders": [["slug": "authentik", "displayName": "Authentik", "enabled": true, "clientId": "x", "scopes": "openid"]],
            ])
        }

        let options = try await harness.makeAuth().checkServer(harness.address)

        #expect(options.passwordLoginEnabled)
        #expect(options.singleSignOnProviders == ["Authentik"])
    }

    @Test func anUnreachableServerIsReportedAsSuch() async {
        let harness = Harness()
        harness.server.goOffline()

        await #expect(throws: ServerCheckError.serverUnreachable) {
            try await harness.makeAuth().checkServer(harness.address)
        }
    }

    @Test func aReachableHostThatIsNotBookOrbitIsRejected() async {
        let harness = Harness()

        await #expect(throws: ServerCheckError.notABookOrbitServer) {
            try await harness.makeAuth().checkServer(harness.address)
        }
    }

    @Test(arguments: [
        ("books.mooneeb.dev", "https://books.mooneeb.dev"),
        ("  http://192.168.1.10:6262/ ", "http://192.168.1.10:6262"),
        ("https://home.example/bookorbit", "https://home.example/bookorbit"),
    ])
    func serverAddressesAcceptWhatPeopleType(input: String, expected: String) throws {
        #expect(try ServerAddress(input).baseURL.absoluteString == expected)
    }

    @Test func aServerAddressNeedsAHost() {
        #expect(throws: ServerAddressError.invalid) { try ServerAddress("https://") }
        #expect(throws: ServerAddressError.empty) { try ServerAddress("   ") }
    }
}
