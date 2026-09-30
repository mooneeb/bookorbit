import Foundation
import os

public enum AppIdentity {
    /// Also the logger subsystem and the Keychain service prefix, so every identifier the app
    /// leaves on the device follows the bundle identifier set in the xcconfig.
    public static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "dev.mooneeb.bookorbit"
}

/// Logs in the project's format: `[event] [start|end|fail] key=value ... - message`. Messages are
/// built by the caller and logged as public, so they must never contain tokens or passwords.
public struct EventLog: Sendable {
    private let logger: Logger

    public init(category: String) {
        logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: category)
    }

    public func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    public func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }

    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}

/// `errorClass=... error="..."`, the fields every `[fail]` line ends with.
public func failureFields(_ error: any Error) -> String {
    "errorClass=\(type(of: error)) error=\"\(sanitizeLogValue(String(describing: error)))\""
}

/// Same rules as the server's `sanitizeLogValue`: one line, at most `maxLength` characters, then
/// backslashes and quotes escaped, so the value cannot end its quoted field early.
public func sanitizeLogValue(_ value: String, maxLength: Int = 200) -> String {
    let singleLine = value.map { $0.isNewline || $0 == "\t" ? " " : $0 }
    return String(singleLine.prefix(maxLength))
        .replacing("\\", with: "\\\\")
        .replacing("\"", with: "\\\"")
}

extension ContinuousClock.Instant {
    public var millisecondsElapsed: Int64 {
        let elapsed = ContinuousClock.now - self
        return elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
    }
}
