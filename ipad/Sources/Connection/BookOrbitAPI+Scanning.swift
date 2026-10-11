import Foundation

extension BookOrbitAPI {
  func scanConfiguration(libraryID: Int) async throws -> LibraryScanConfiguration {
    try await boundedJSON("libraries/\(libraryID)", byteLimit: 256 * 1024, expectedStatus: 200)
  }

  func saveScanConfiguration(libraryID: Int, request: ScanConfigurationRequest) async throws
    -> LibraryScanConfiguration
  {
    try await boundedJSON(
      "libraries/\(libraryID)", method: "PATCH", body: JSONEncoder().encode(request),
      byteLimit: 256 * 1024,
      expectedStatus: 200)
  }

  func previewScan(libraryID: Int, paths: [String]) async throws -> PrescanResult {
    try await boundedJSON(
      "libraries/prescan", method: "POST",
      body: JSONEncoder().encode(ScanPreviewRequest(libraryId: libraryID, paths: paths)),
      byteLimit: 256 * 1024, expectedStatus: 201)
  }

  func scanStatus(libraryID: Int) async throws -> ScanStatusResponse {
    try await boundedJSON(
      "scanner/libraries/\(libraryID)/scan-status", byteLimit: 64 * 1024, expectedStatus: 200)
  }

  func scanHistory(libraryID: Int) async throws -> [LibraryScanHistoryEntry] {
    try await boundedJSON(
      "scanner/libraries/\(libraryID)/scan-history",
      query: [URLQueryItem(name: "limit", value: "5")], byteLimit: 64 * 1024, expectedStatus: 200)
  }

  func startScan(libraryID: Int, baseline: Int) async throws -> ScanStartResult {
    try await boundedJSON(
      "scanner/libraries/\(libraryID)/scan", method: "POST",
      body: JSONEncoder().encode(ScanStartRequest(expectedLastJobId: baseline)),
      byteLimit: 16 * 1024, expectedStatus: 202)
  }

  func dockScanSettings() async throws -> BookDockSettings {
    try await boundedJSON("book-dock/settings", byteLimit: 64 * 1024, expectedStatus: 200)
  }

  func rescanDock() async throws {
    try await sendEmpty("book-dock/rescan", expectedStatus: 204)
  }
}
