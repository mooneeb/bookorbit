import Foundation
import Observation

@MainActor @Observable
final class RequestAdministrationModel {
  let api: BookOrbitAPI
  let canManage: Bool
  let canManagePlugins: Bool
  private(set) var sources: [IndexerItem] = []
  private(set) var adapters: [IndexerAdapterDescriptor] = []
  private(set) var pluginFailures: [IndexerPluginFailure] = []
  private(set) var clients: [DownloadClientItem] = []
  private(set) var managers: [IndexerManagerItem] = []
  private(set) var encryptionConfigured = true
  private(set) var busy = false
  var error: String?
  var feedback: String?

  init(api: BookOrbitAPI, user: AuthUser) {
    self.api = api
    canManage = user.hasPermission(.manageAppSettings)
    canManagePlugins = user.isSuperuser && canManage
  }

  func load() async {
    guard canManage, !busy else { return }
    await perform {
      async let sources = self.api.requestSources()
      async let adapters = self.api.requestSourceAdapters()
      async let clients = self.api.requestDownloadClients()
      async let managers = self.api.requestIndexerManagers()
      let results = try await (sources, adapters, clients, managers)
      self.sources = results.0.indexers
      self.adapters = results.1.adapters
      self.pluginFailures = results.1.pluginFailures
      self.clients = results.2.clients
      self.managers = results.3.managers
      self.encryptionConfigured = results.0.encryptionConfigured && results.2.encryptionConfigured
    }
  }

  func perform(_ operation: () async throws -> Void) async {
    guard canManage, !busy else { return }
    busy = true
    error = nil
    feedback = nil
    defer { busy = false }
    do { try await operation() } catch { self.error = error.localizedDescription }
  }

  func remove(path: String) async {
    await perform { try await self.api.sendEmpty(path, method: "DELETE", expectedStatus: 204) }
    if error == nil { await load() }
  }

  func testSource(_ source: IndexerItem) async {
    await perform {
      let result = try await self.api.testRequestSource(id: source.id)
      self.feedback =
        result.success ? "Source connection verified." : result.error ?? "Source test failed."
    }
  }

  func testClient(_ client: DownloadClientItem) async {
    await perform {
      let result = try await self.api.testRequestDownloadClient(id: client.id)
      self.feedback =
        result.success
        ? "Download client connection verified." : result.error ?? "Download client test failed."
    }
  }

  func testMapping(clientID: Int, mappingID: Int) async {
    await perform {
      let result = try await self.api.testRequestPathMapping(
        clientID: clientID, mappingID: mappingID)
      self.feedback =
        result.hardlinkWorks
        ? "Hardlink verified." : result.error ?? "Files will be copied. Hardlinks are unavailable."
    }
  }
}
