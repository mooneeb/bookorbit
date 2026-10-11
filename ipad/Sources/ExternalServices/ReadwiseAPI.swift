import Foundation

extension BookOrbitAPI {
  func readwiseSettings() async throws -> ReadwiseSettings {
    try await send("readwise/settings")
  }

  func saveReadwiseSettings(_ payload: UpsertReadwiseSettingsPayload) async throws
    -> ReadwiseSettings
  {
    try await send(
      "readwise/settings", method: "PATCH", body: JSONEncoder().encode(payload))
  }

  func validateReadwiseToken(_ token: String?) async throws -> ReadwiseTokenValidationResult {
    let body = try JSONSerialization.data(withJSONObject: token.map { ["token": $0] } ?? [:])
    return try await send("readwise/validate-token", method: "POST", body: body)
  }

  func readwiseSyncStatus() async throws -> ReadwiseSyncStatus {
    try await send("readwise/sync/status")
  }

  func synchronizeReadwise() async throws -> ReadwiseSyncStatus {
    try await send("readwise/sync", method: "POST")
  }
}
