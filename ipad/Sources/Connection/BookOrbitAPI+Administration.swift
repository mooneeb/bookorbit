import Foundation

extension BookOrbitAPI {
  func administrationUsers(page: Int, search: String) async throws -> AdminUserListPage {
    try await boundedJSONOnline(
      "users",
      query: [
        .init(name: "page", value: String(page)), .init(name: "pageSize", value: "50"),
        .init(name: "search", value: String(search.prefix(100))),
      ], byteLimit: 512 * 1024, expectedStatus: 200)
  }

  func administrationLibraries() async throws -> [Library] {
    try await boundedJSONOnline("libraries", byteLimit: 512 * 1024, expectedStatus: 200)
  }

  func saveAdministrationLibrary(id: Int?, values: [String: JSONValue]) async throws -> Library {
    try await boundedJSONOnline(
      id.map { "libraries/\($0)" } ?? "libraries", method: id == nil ? "POST" : "PATCH",
      body: JSONEncoder().encode(values), expectedStatus: id == nil ? 201 : 200)
  }

  func updateAdministrationUser(id: Int, name: String, email: String, active: Bool) async throws {
    try await sendEmpty(
      "users/\(id)", method: "PATCH",
      body: JSONEncoder().encode(
        AdminUpdateUserRequest(name: name, email: email.isEmpty ? nil : email, active: active)),
      expectedStatus: 200)
  }

  func createAdministrationUser(username: String, name: String, email: String) async throws {
    try await sendEmpty(
      "users", method: "POST",
      body: JSONEncoder().encode(
        AdminCreateUserRequest(username: username, name: name, email: email)),
      expectedStatus: 201)
  }

  func setAdministrationPermissions(id: Int, names: [String]) async throws {
    try await sendEmpty(
      "users/\(id)/permissions", method: "PUT",
      body: JSONEncoder().encode(AdminSetPermissionsRequest(permissionNames: names)),
      expectedStatus: 204)
  }

  func administrationSettings() async throws -> [AppSettingResponse] {
    try await boundedJSONOnline("app-settings", byteLimit: 256 * 1024, expectedStatus: 200)
  }

  func saveAdministrationPolicy(key: String, enabled: Bool) async throws {
    guard ["allow_registration", "opds_enabled", "hardcover_enabled"].contains(key) else {
      throw ConnectionError.invalidResponse
    }
    try await sendEmpty(
      "app-settings/\(key)", method: "PATCH",
      body: JSONEncoder().encode(UpdateAppSettingRequest(value: enabled ? "true" : "false")),
      expectedStatus: 200)
  }

  func administrationOIDC() async throws -> [OidcProviderConfig] {
    try await boundedJSONOnline(
      "app-settings/oidc/providers", byteLimit: 256 * 1024, expectedStatus: 200)
  }

  func saveAdministrationOIDC(slug: String, existing: Bool, values: [String: JSONValue])
    async throws
  {
    var body = values
    if !existing { body["slug"] = .string(slug) }
    try await sendEmpty(
      existing ? "app-settings/oidc/providers/\(slug)" : "app-settings/oidc/providers",
      method: existing ? "PUT" : "POST", body: JSONEncoder().encode(body),
      expectedStatus: existing ? 200 : 201)
  }

  func administrationTTS() async throws -> [AdminTtsProvider] {
    try await boundedJSONOnline("tts/admin/providers", byteLimit: 256 * 1024, expectedStatus: 200)
  }

  func saveAdministrationTTS(id: Int?, values: [String: JSONValue]) async throws {
    try await sendEmpty(
      id.map { "tts/admin/providers/\($0)" } ?? "tts/admin/providers",
      method: id == nil ? "POST" : "PUT", body: JSONEncoder().encode(values),
      expectedStatus: id == nil ? 201 : 200)
  }

  func administrationAudit(page: Int, search: String) async throws -> AuditLogPage {
    try await boundedJSONOnline(
      "audit-log",
      query: [
        .init(name: "page", value: String(page)), .init(name: "pageSize", value: "50"),
        .init(name: "search", value: search),
      ], byteLimit: 512 * 1024, expectedStatus: 200)
  }
}
