import Foundation
import Security

struct SavedSession: Codable, Sendable {
  var credentials: NativeCredentials
  var user: AuthUser
}

struct CredentialStore: Sendable {
  let account: String
  private var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.mooneeb.bookorbit.private.session",
      kSecAttrAccount as String: account,
    ]
  }

  func read() throws -> SavedSession? {
    var lookup = query
    lookup[kSecReturnData as String] = true
    lookup[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw ConnectionError.keychain(status)
    }
    var archiveData = data
    if var archive = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      var user = archive["user"] as? [String: Any], user["settings"] == nil
    {
      user["settings"] = [String: Any]()
      archive["user"] = user
      archiveData = try JSONSerialization.data(withJSONObject: archive)
    }
    return try JSONDecoder().decode(SavedSession.self, from: archiveData)
  }

  func write(_ session: SavedSession) throws {
    let attributes: [String: Any] = [
      kSecValueData as String: try JSONEncoder().encode(session),
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      let addStatus = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
      guard addStatus == errSecSuccess else { throw ConnectionError.keychain(addStatus) }
    } else if status != errSecSuccess {
      throw ConnectionError.keychain(status)
    }
  }

  func remove() throws {
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw ConnectionError.keychain(status)
    }
  }
}
