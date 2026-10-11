import Foundation

struct PersonalPreferenceEnvelope: Codable, Sendable {
  var settings: [String: JSONValue]?
}

extension BookOrbitAPI {
  func personalPreferences(_ category: String) async throws -> [String: JSONValue]? {
    guard ["theme", "locale", "display", "whats-new"].contains(category) else {
      throw ConnectionError.invalidResponse
    }
    let response: PersonalPreferenceEnvelope = try await boundedJSON(
      "user-preferences/\(category)", byteLimit: 64 * 1024, expectedStatus: 200)
    return response.settings
  }

  func savePersonalPreferences(_ category: String, settings: [String: JSONValue]) async throws {
    guard ["theme", "locale", "display", "whats-new"].contains(category) else {
      throw ConnectionError.invalidResponse
    }
    try await sendEmpty(
      "user-preferences/\(category)", method: "PUT",
      body: JSONEncoder().encode(PersonalPreferenceEnvelope(settings: settings)),
      expectedStatus: 204)
  }

  func saveProfileName(_ name: String) async throws {
    try await sendEmpty(
      "users/me", method: "PATCH", body: JSONEncoder().encode(["name": name]), expectedStatus: 200)
  }

  func saveAccountSettings(_ settings: [String: JSONValue]) async throws {
    try await sendEmpty(
      "users/me/settings", method: "PATCH",
      body: JSONEncoder().encode(PersonalPreferenceEnvelope(settings: settings)),
      expectedStatus: 200)
  }

  func uploadProfileAvatar(_ data: Data) async throws {
    let _: [String: JSONValue] = try await boundedMultipart(
      "users/me/avatar", filename: "avatar.jpg", data: data, mimeType: "image/jpeg")
  }

  func profileAvatar(userID: Int) async throws -> Data {
    try await authenticatedImage(
      path: "users/\(userID)/avatar", query: [], cachePolicy: .reloadIgnoringLocalCacheData)
  }

  func removeProfileAvatar() async throws {
    try await sendEmpty("users/me/avatar", method: "DELETE", expectedStatus: 200)
  }

  func personalPrivacy() async throws -> ReadingInsightsSharingSettings {
    try await boundedJSON("reading-insights-sharing/me", byteLimit: 64 * 1024, expectedStatus: 200)
  }

  func savePersonalPrivacy(_ level: String) async throws -> ReadingInsightsSharingSettings {
    try await boundedJSON(
      "reading-insights-sharing/me", method: "PATCH",
      body: JSONEncoder().encode(["sharingLevel": level]), expectedStatus: 200)
  }

  func personalPrivacyHistory(page: Int) async throws -> ReadingInsightsAccessHistoryPage {
    try await boundedJSON(
      "reading-insights-sharing/me/access-history",
      query: [.init(name: "page", value: String(page)), .init(name: "pageSize", value: "20")],
      byteLimit: 128 * 1024, expectedStatus: 200)
  }

  func personalNotifications(offset: Int) async throws -> NotificationPage {
    try await boundedJSON(
      "notifications",
      query: [.init(name: "limit", value: "20"), .init(name: "offset", value: String(offset))],
      byteLimit: 256 * 1024, expectedStatus: 200)
  }

  func markPersonalNotificationRead(_ id: Int) async throws {
    try await sendEmpty("notifications/\(id)/read", method: "PATCH", expectedStatus: 204)
  }

  func dismissPersonalNotification(_ id: Int) async throws {
    try await sendEmpty("notifications/\(id)", method: "DELETE", expectedStatus: 204)
  }

  func markAllPersonalNotificationsRead() async throws {
    try await sendEmpty("notifications/read-all", method: "PATCH", expectedStatus: 204)
  }

  func releaseInformation(page: Int) async throws -> ReleaseNotesResponse {
    try await boundedJSON(
      "release-notes", query: [.init(name: "page", value: String(page))], byteLimit: 512 * 1024,
      expectedStatus: 200)
  }
}
