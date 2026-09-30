import Foundation

/// The wording every screen uses for connection and sign-in problems, so "server unreachable" and
/// "login failed" read the same everywhere.
public enum UserMessages {
    public static let serverUnreachable: LocalizedStringResource = "Server unreachable. Check your network or VPN and try again."
    public static let sessionEnded: LocalizedStringResource = "Your session ended. Sign in again."
}

extension ServerCheckError {
    public var userMessage: LocalizedStringResource {
        switch self {
        case .serverUnreachable: UserMessages.serverUnreachable
        case .notABookOrbitServer: "No BookOrbit server answered at that address."
        }
    }
}

extension ServerAddressError {
    public var userMessage: LocalizedStringResource {
        switch self {
        case .empty: "Enter your server's address."
        case .invalid: "That is not a valid server address."
        }
    }
}

extension SignInError {
    public var userMessage: LocalizedStringResource {
        switch self {
        case .serverUnreachable:
            UserMessages.serverUnreachable
        case .invalidCredentials:
            "Login failed: wrong username or password."
        case .accountLocked(let retryAfterSeconds?):
            "Login failed: the account is locked. Try again in \(max(1, retryAfterSeconds / 60)) min."
        case .accountLocked(nil):
            "Login failed: the account is temporarily locked."
        case .passwordLoginDisabled:
            "Login failed: password sign-in is turned off on this server."
        case .tooManyAttempts:
            "Login failed: too many attempts. Wait a minute and try again."
        case .noResponse:
            "Login failed: the server did not answer. Try again."
        case .unexpectedResponse(let statusCode):
            "Login failed: the server answered unexpectedly (\(statusCode))."
        }
    }
}

extension SessionError {
    public var userMessage: LocalizedStringResource {
        switch self {
        case .serverUnreachable: UserMessages.serverUnreachable
        case .sessionExpired, .signedOut: UserMessages.sessionEnded
        case .noResponse: "The server did not answer. Try again."
        case .invalidResponse, .unexpectedResponse: "The server answered unexpectedly. Try again."
        }
    }
}
