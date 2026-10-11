import Foundation

extension BookOrbitAPI {
  func requestSources() async throws -> IndexerListResult {
    try await boundedJSON("admin/request-indexers")
  }

  func requestSourceAdapters() async throws -> IndexerAdapterListResult {
    try await boundedJSON("admin/request-indexers/adapters")
  }

  func saveRequestSource(id: Int?, body: Data) async throws -> IndexerItem {
    try await boundedJSON(
      id.map { "admin/request-indexers/\($0)" } ?? "admin/request-indexers",
      method: id == nil ? "POST" : "PUT", body: body)
  }

  func testRequestSource(id: Int) async throws -> IndexerTestResult {
    try await boundedJSON("admin/request-indexers/\(id)/test", method: "POST")
  }

  func requestDownloadClients() async throws -> DownloadClientListResult {
    try await boundedJSON("admin/download-clients")
  }

  func saveRequestDownloadClient(id: Int?, body: Data) async throws -> DownloadClientItem {
    try await boundedJSON(
      id.map { "admin/download-clients/\($0)" } ?? "admin/download-clients",
      method: id == nil ? "POST" : "PUT", body: body)
  }

  func testRequestDownloadClient(id: Int) async throws -> DownloadClientTestResult {
    try await boundedJSON("admin/download-clients/\(id)/test", method: "POST")
  }

  func testRequestPathMapping(clientID: Int, mappingID: Int) async throws
    -> PathMappingHardlinkTestResult
  {
    try await boundedJSON(
      "admin/download-clients/\(clientID)/test-path-mapping", method: "POST",
      body: JSONSerialization.data(withJSONObject: ["mappingId": mappingID]))
  }

  func requestIndexerManagers() async throws -> IndexerManagerListResult {
    try await boundedJSON("admin/request-indexer-managers")
  }

  func saveRequestIndexerManager(id: Int?, body: Data) async throws -> IndexerManagerItem {
    try await boundedJSON(
      id.map { "admin/request-indexer-managers/\($0)" } ?? "admin/request-indexer-managers",
      method: id == nil ? "POST" : "PUT", body: body)
  }

  func testRequestIndexerManager(id: Int) async throws -> IndexerManagerTestResult {
    try await boundedJSON("admin/request-indexer-managers/\(id)/test", method: "POST")
  }

  func syncRequestIndexerManager(id: Int) async throws -> IndexerManagerSyncResult {
    try await boundedJSON("admin/request-indexer-managers/\(id)/sync", method: "POST")
  }

  func setManagedRequestSource(managerID: Int, sourceID: Int, enabled: Bool) async throws
    -> IndexerManagerItem
  {
    try await boundedJSON(
      "admin/request-indexer-managers/\(managerID)/sources/\(sourceID)", method: "PUT",
      body: JSONSerialization.data(withJSONObject: ["enabled": enabled]))
  }

  func requestAutomation() async throws -> BookRequestAutomationSettings {
    try await boundedJSON("admin/book-request-automation")
  }

  func saveRequestAutomation(body: Data) async throws -> BookRequestAutomationSettings {
    try await boundedJSON("admin/book-request-automation", method: "PUT", body: body)
  }

  func inspectRequestPlugin(data: Data) async throws -> PluginInspection {
    try await boundedMultipart(
      "admin/request-indexers/plugins/inspect", filename: "plugin.mjs", data: data,
      byteLimit: 1024 * 1024)
  }

  func installRequestPlugin(data: Data) async throws -> PluginInstallResult {
    try await boundedMultipart(
      "admin/request-indexers/plugins", filename: "plugin.mjs", data: data, byteLimit: 1024 * 1024)
  }

  func requestPluginUpdates(check: Bool = false) async throws -> PluginUpdateListResult {
    try await boundedJSON(
      check
        ? "admin/request-indexers/plugins/updates/check" : "admin/request-indexers/plugins/updates",
      method: check ? "POST" : "GET")
  }

  func inspectRequestPluginUpdate(type: String) async throws -> PluginUpdateReview {
    try await boundedJSON("admin/request-indexers/plugins/\(type)/update/inspect", method: "POST")
  }

  func installRequestPluginUpdate(type: String, sha256: String) async throws -> PluginUpdateStatus {
    try await boundedJSON(
      "admin/request-indexers/plugins/\(type)/update", method: "POST",
      body: JSONSerialization.data(withJSONObject: ["sha256": sha256]))
  }

  func setRequestPluginAutomaticUpdate(type: String, enabled: Bool) async throws
    -> PluginUpdateStatus
  {
    try await boundedJSON(
      "admin/request-indexers/plugins/\(type)/auto-update", method: "PUT",
      body: JSONSerialization.data(withJSONObject: ["enabled": enabled]))
  }
}
