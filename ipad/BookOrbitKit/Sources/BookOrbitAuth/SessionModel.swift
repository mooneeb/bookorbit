import Foundation
import Observation

@MainActor @Observable
public final class SessionModel {
    public enum Phase {
        case launching
        case choosingServer
        case signingIn(ServerAddress, LoginOptions)
        case signedIn(AuthenticatedSession)
    }

    public private(set) var phase: Phase = .launching
    public private(set) var sessionEndedByServer = false
    public let auth: AuthManager
    private let defaults: UserDefaults
    private var started = false
    private static let serverKey = "lastServerAddress"

    public init(auth: AuthManager, defaults: UserDefaults = .standard) {
        self.auth = auth
        self.defaults = defaults
    }

    /// Kept after sign-out so signing back in is quick.
    public var lastServerAddress: String {
        defaults.string(forKey: Self.serverKey) ?? ""
    }

    /// Call once per app launch, not per window: it keeps following session events until the app
    /// quits. Later calls return immediately.
    public func start() async {
        guard !started else { return }
        started = true
        if let session = await auth.restoredSession() {
            phase = .signedIn(session)
        } else {
            phase = .choosingServer
        }
        for await event in auth.sessionEvents {
            switch event {
            case .sessionExpired:
                sessionEndedByServer = true
                phase = .choosingServer
            }
        }
    }

    public func connect(to address: String) async throws {
        let server = try ServerAddress(address)
        let options = try await auth.checkServer(server)
        defaults.set(server.description, forKey: Self.serverKey)
        phase = .signingIn(server, options)
    }

    public func signIn(username: String, password: String) async throws {
        guard case .signingIn(let server, _) = phase else { return }
        let session = try await auth.signIn(to: server, username: username, password: password)
        sessionEndedByServer = false
        phase = .signedIn(session)
    }

    public func changeServer() {
        phase = .choosingServer
    }

    @discardableResult
    public func signOut() async -> SignOutOutcome {
        let outcome = await auth.signOut()
        phase = .choosingServer
        return outcome
    }

    /// Refreshing while in the background keeps the refresh token from expiring during long breaks.
    public func refreshInBackground() async {
        guard let session = await auth.restoredSession() else { return }
        _ = try? await session.client.authControllerMe()
    }
}
