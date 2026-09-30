import Foundation
import Observation

/// Drives the app between choosing a server, signing in, and being signed in.
@MainActor @Observable
public final class SessionModel {
    public enum Phase {
        case launching
        case choosingServer
        case signingIn(ServerAddress, LoginOptions)
        case signedIn(AuthenticatedSession)
    }

    public private(set) var phase: Phase = .launching
    /// Set when the server ended the session (for example, it was revoked from the web).
    public private(set) var sessionEndedByServer = false
    public let auth: AuthManager
    private let defaults: UserDefaults
    private var started = false
    private static let serverKey = "lastServerAddress"

    public init(auth: AuthManager, defaults: UserDefaults = .standard) {
        self.auth = auth
        self.defaults = defaults
    }

    /// The address typed last time, kept after sign-out so signing back in is quick.
    public var lastServerAddress: String {
        defaults.string(forKey: Self.serverKey) ?? ""
    }

    /// Restores the saved session, then follows session events. Safe to call from every window;
    /// only the first call does anything.
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

    /// Keeps the session alive while the app is in the background by refreshing its access token.
    public func refreshInBackground() async {
        guard let session = await auth.restoredSession() else { return }
        _ = try? await session.client.authControllerMe()
    }
}
