import Foundation
import OpenAPIRuntime

public enum SignInError: Error, Equatable {
    case serverUnreachable
    case invalidCredentials
    case accountLocked(retryAfterSeconds: Int?)
    case passwordLoginDisabled
    case tooManyAttempts
    /// The request failed without an HTTP answer, for a reason other than the server being unreachable.
    case noResponse
    case unexpectedResponse(statusCode: Int)
}

public enum ServerCheckError: Error, Equatable {
    case serverUnreachable
    case notABookOrbitServer
}

public enum SessionError: Error, Equatable {
    /// The server refused the refresh token (revoked, expired, or the password changed), so the
    /// reader has to sign in again.
    case sessionExpired
    case signedOut
    case serverUnreachable
    case noResponse
    case invalidResponse
    case unexpectedResponse(statusCode: Int)

    /// Finds the session error behind an error thrown by the generated client, which wraps
    /// middleware and transport errors in `ClientError`.
    public init?(_ error: any Error) {
        if Reachability.isUnreachable(error) {
            self = .serverUnreachable
            return
        }
        guard let sessionError = underlyingErrors(of: error).lazy.compactMap({ $0 as? SessionError }).first else { return nil }
        self = sessionError
    }
}

public enum SessionEvent: Sendable, Equatable {
    case sessionExpired
}

public enum SignOutOutcome: Sendable, Equatable {
    case revoked
    /// Local data was wiped, but the server could not be told, so the session stays listed on the
    /// server until it expires or is revoked there.
    case revokedOnThisDeviceOnly
}

/// The error followed by every error it wraps, since the generated client wraps middleware and
/// transport errors in `ClientError`.
func underlyingErrors(of error: any Error) -> [any Error] {
    var chain: [any Error] = [error]
    while let wrapped = (chain.last as? ClientError)?.underlyingError {
        chain.append(wrapped)
    }
    return chain
}

enum Reachability {
    private static let unreachableCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
        .timedOut, .networkConnectionLost, .internationalRoamingOff, .dataNotAllowed,
        .secureConnectionFailed, .cannotLoadFromNetwork,
    ]

    static func isUnreachable(_ error: any Error) -> Bool {
        underlyingErrors(of: error).contains { ($0 as? URLError).map { unreachableCodes.contains($0.code) } ?? false }
    }

    static func sessionError(forTransportError error: any Error) -> SessionError {
        isUnreachable(error) ? .serverUnreachable : .noResponse
    }
}
