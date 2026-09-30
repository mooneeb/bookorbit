import Foundation
import OpenAPIRuntime

public enum SignInError: Error, Equatable {
    /// The server could not be reached at all, for example because Tailscale is off.
    case serverUnreachable
    case invalidCredentials
    case accountLocked(retryAfterSeconds: Int?)
    case passwordLoginDisabled
    case tooManyAttempts
    case unexpectedResponse(statusCode: Int)
}

enum Reachability {
    private static let unreachableCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
        .timedOut, .networkConnectionLost, .internationalRoamingOff, .dataNotAllowed,
        .secureConnectionFailed, .cannotLoadFromNetwork,
    ]

    /// True when the request never got an HTTP answer from the server.
    static func isUnreachable(_ error: any Error) -> Bool {
        var current: (any Error)? = error
        while let error = current {
            if let urlError = error as? URLError { return unreachableCodes.contains(urlError.code) }
            current = (error as? ClientError)?.underlyingError
        }
        return false
    }
}

public enum ServerCheckError: Error, Equatable {
    /// The server could not be reached at all, for example because Tailscale is off.
    case serverUnreachable
    /// Something answered, but not a BookOrbit server.
    case notABookOrbitServer
}

/// Why an authenticated request could not be made.
public enum SessionError: Error, Equatable {
    /// The server refused the refresh token (revoked from the web, expired, or the password
    /// changed). The reader has to sign in again.
    case sessionExpired
    case signedOut
    case serverUnreachable
    case unexpectedResponse(statusCode: Int)

    /// Finds the session error behind an error thrown by the generated client, which wraps
    /// middleware and transport errors in `ClientError`.
    public init?(_ error: any Error) {
        if Reachability.isUnreachable(error) {
            self = .serverUnreachable
            return
        }
        var current: (any Error)? = error
        while let error = current {
            if let sessionError = error as? SessionError {
                self = sessionError
                return
            }
            current = (error as? ClientError)?.underlyingError
        }
        return nil
    }
}

public enum SessionEvent: Sendable, Equatable {
    case sessionExpired
}

public enum SignOutOutcome: Sendable, Equatable {
    case revoked
    /// Local data was wiped, but the server could not be told, so the session stays listed on the
    /// web until it expires or is revoked there.
    case revokedOnThisDeviceOnly
}
