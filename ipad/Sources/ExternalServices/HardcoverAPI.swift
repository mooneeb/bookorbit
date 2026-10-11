import Foundation

extension BookOrbitAPI {
  func hardcoverSettings() async throws -> HardcoverSettings {
    try await boundedJSON("hardcover/settings")
  }

  func saveHardcoverSettings(_ payload: UpsertHardcoverSettingsPayload) async throws
    -> HardcoverSettings
  {
    try await boundedJSON(
      "hardcover/settings", method: "PATCH", body: JSONEncoder().encode(payload))
  }

  func validateHardcoverToken(_ token: String?) async throws -> HardcoverTokenValidationResult {
    try await boundedJSON(
      "hardcover/validate-token", method: "POST",
      body: JSONEncoder().encode(ValidateHardcoverTokenPayload(token: token)))
  }

  func disconnectHardcover() async throws {
    try await sendEmpty("hardcover/settings", method: "DELETE")
  }

  func startHardcoverSync() async throws -> HardcoverStartSyncResult {
    try await boundedJSON("hardcover/sync", method: "POST")
  }

  func cancelHardcoverSync() async throws {
    try await sendEmpty("hardcover/sync", method: "DELETE")
  }

  func hardcoverOutcome() async throws -> HardcoverSyncOutcome? {
    try await boundedJSON("hardcover/sync/outcome")
  }

  func hardcoverLinkedBooks() async throws -> HardcoverLinkedBooksResult {
    try await boundedJSON("hardcover/books")
  }

  func hardcoverBookState(_ bookID: Int) async throws -> HardcoverBookSyncState {
    try await boundedJSON("hardcover/books/\(bookID)/sync-state")
  }

  func setHardcoverBookEnabled(_ bookID: Int, enabled: Bool) async throws -> HardcoverBookSyncState
  {
    try await boundedJSON(
      "hardcover/books/\(bookID)/sync-state", method: "PATCH",
      body: JSONEncoder().encode(UpdateHardcoverBookSyncPayload(syncEnabled: enabled)))
  }

  func syncHardcoverBook(_ bookID: Int) async throws -> HardcoverBookSyncNowResult {
    try await boundedJSON("hardcover/books/\(bookID)/sync", method: "POST")
  }

  func hardcoverEditions(_ bookID: Int) async throws -> HardcoverEditionsResult {
    try await boundedJSON("hardcover/books/\(bookID)/editions")
  }

  func setHardcoverEdition(_ bookID: Int, editionID: Int) async throws -> SetHardcoverEditionResult
  {
    try await boundedJSON(
      "hardcover/books/\(bookID)/edition", method: "PATCH",
      body: JSONEncoder().encode(SetHardcoverEditionPayload(editionId: editionID)))
  }
}
