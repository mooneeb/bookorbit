import Foundation
import Synchronization

public struct StoredSession: Codable, Sendable, Equatable {
    public var server: ServerAddress
    public var user: AccountUser
    public var credentials: Credentials
}

public struct AccountUser: Codable, Sendable, Equatable {
    public let id: Int
    public let username: String
    public let name: String
}

public struct Credentials: Codable, Sendable, Equatable {
    public var accessToken: String
    public var accessTokenExpiresAt: Date
    public var refreshToken: String
    public var refreshTokenExpiresAt: Date
    public var sessionId: Int
}

public protocol SessionStore: Sendable {
    func load() throws -> StoredSession?
    func save(_ session: StoredSession) throws
    func clear() throws
}

public final class InMemorySessionStore: SessionStore {
    private let stored = Mutex<StoredSession?>(nil)

    public init() {}

    public func load() throws -> StoredSession? { stored.withLock { $0 } }
    public func save(_ session: StoredSession) throws { stored.withLock { $0 = session } }
    public func clear() throws { stored.withLock { $0 = nil } }
}
