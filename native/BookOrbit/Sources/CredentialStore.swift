import Foundation
import Security

struct CredentialStore {
    private func key(origin: URL, identity: UUID, account: Int) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.mooneeb.bookorbit.reader.session",
         kSecAttrAccount as String: "\(origin.absoluteString)|\(identity.uuidString)|\(account)"]
    }

    func save(_ value: Credentials, origin: URL, identity: UUID, account: Int) throws {
        var query = key(origin: origin, identity: identity, account: account)
        let data = try JSONEncoder().encode(value)
        let result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw ReaderFailure.message("Credentials could not be saved securely.") }
        } else if result != errSecSuccess { throw ReaderFailure.message("Credentials could not be saved securely.") }
    }

    func load(origin: URL, identity: UUID, account: Int) throws -> Credentials {
        var query = key(origin: origin, identity: identity, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            throw ReaderFailure.message("Sign in again to reconnect this account.")
        }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }

    func remove(origin: URL, identity: UUID, account: Int) {
        SecItemDelete(key(origin: origin, identity: identity, account: account) as CFDictionary)
    }
}

struct SessionReference: Codable {
    let origin: URL
    let identity: UUID
    let account: Int
}
