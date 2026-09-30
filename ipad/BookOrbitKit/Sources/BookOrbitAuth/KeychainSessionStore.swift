import Foundation
import Security

/// Keeps the signed-in session, including both tokens, in the Keychain as one item that never
/// leaves this device. Readable after the first unlock so background refresh can use it.
public struct KeychainSessionStore: SessionStore {
    private let service: String
    private let account = "session"

    public init(service: String = "app.bookorbit.ipad.session") {
        self.service = service
    }

    public func load() throws -> StoredSession? {
        var query = baseQuery()
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = withKeychainFallback(&query) { SecItemCopyMatching($0 as CFDictionary, &result) }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(StoredSession.self, from: data)
    }

    public func save(_ session: StoredSession) throws {
        try clear()
        var query = baseQuery()
        query[kSecValueData] = try JSONEncoder().encode(session)
        query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = withKeychainFallback(&query) { SecItemAdd($0 as CFDictionary, nil) }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func clear() throws {
        var query = baseQuery()
        let status = withKeychainFallback(&query) { SecItemDelete($0 as CFDictionary) }
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private func baseQuery() -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
        ]
    }

    /// A Mac build signed to run locally has no keychain entitlement, which the data protection
    /// keychain requires; it falls back to the login keychain there.
    private func withKeychainFallback(_ query: inout [CFString: Any], _ operation: ([CFString: Any]) -> OSStatus) -> OSStatus {
        let status = operation(query)
        guard status == errSecMissingEntitlement else { return status }
        query[kSecUseDataProtectionKeychain] = false
        return operation(query)
    }
}

public struct KeychainError: Error, Equatable {
    public let status: OSStatus
}
