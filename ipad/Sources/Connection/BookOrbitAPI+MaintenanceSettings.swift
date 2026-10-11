import Foundation

extension BookOrbitAPI {
  func maintenanceSettings() async throws -> [AppSettingResponse] {
    try await boundedJSON("app-settings", byteLimit: 256 * 1024, expectedStatus: 200)
  }

  func updateMaintenanceSetting(key: String, value: String) async throws -> AppSettingResponse {
    guard ["max_upload_size_mb", "update_check_enabled"].contains(key) else {
      throw ConnectionError.invalidResponse
    }
    return try await boundedJSON(
      "app-settings/\(key)", method: "PATCH",
      body: JSONEncoder().encode(UpdateAppSettingRequest(value: value)), expectedStatus: 200)
  }

  func rebuildRecommendationIndex() async throws -> BookEmbeddingRebuildResult {
    try await boundedJSON("books/embed-all", method: "POST", expectedStatus: 201)
  }

  func recommendationIndexStatus() async throws -> MaintenanceOperationStatus {
    try await boundedJSON("books/embed-all/status", byteLimit: 64 * 1024, expectedStatus: 200)
  }

  func startAchievementBackfill() async throws -> MaintenanceOperationStatus {
    try await boundedJSON("achievements/admin/backfill/start", method: "POST", expectedStatus: 201)
  }

  func achievementBackfillStatus() async throws -> MaintenanceOperationStatus {
    try await boundedJSON(
      "achievements/admin/backfill/status", byteLimit: 64 * 1024, expectedStatus: 200)
  }
}
