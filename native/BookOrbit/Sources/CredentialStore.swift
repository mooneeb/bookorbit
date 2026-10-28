import Foundation
import Security

struct CredentialStore {
    private func key(_ scope: SessionReference) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.mooneeb.bookorbit.reader.session",
         kSecAttrAccount as String: "\(scope.origin.absoluteString)|\(scope.identity.uuidString)|\(scope.account)"]
    }

    func save(_ value: Credentials, scope: SessionReference) throws {
        var query = key(scope)
        let data = try JSONEncoder().encode(value)
        let result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw ReaderFailure.message("Credentials could not be saved securely.") }
        } else if result != errSecSuccess { throw ReaderFailure.message("Credentials could not be saved securely.") }
    }

    func load(scope: SessionReference) throws -> Credentials {
        var query = key(scope)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            throw ReaderFailure.message("Sign in again to reconnect this account.")
        }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }

    func remove(scope: SessionReference) {
        SecItemDelete(key(scope) as CFDictionary)
    }
}

struct SessionReference: Codable {
    let origin: URL
    let identity: UUID
    let account: Int
}
