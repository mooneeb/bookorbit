import Foundation
import Observation

@MainActor @Observable
final class KOReaderManagementModel {
  let api: BookOrbitAPI
  let user: AuthUser
  private(set) var status: KoreaderSyncStatus?
  private(set) var unmatched: [KoreaderUnmatchedBook] = []
  private(set) var links: [KoreaderManualHashLink] = []
  private(set) var isBusy = false
  private(set) var isMutating = false
  private(set) var plugin: StagedBookFile?
  var defaultPattern = ""
  var error: String?
  var result: String?
  var devicePage = 0
  var unmatchedPage = 0
  var linkPage = 0
  private var requestID = UUID()
  let pageSize = 10

  init(api: BookOrbitAPI, user: AuthUser) {
    self.api = api
    self.user = user
  }

  var isPermitted: Bool { user.hasPermission(.koreaderSync) }
  var hasCredentials: Bool { status?.credentials != nil }
  var deviceIDs: [String] {
    Array(Set((status?.devices.map(\.deviceId) ?? []) + (status?.sweeps.map(\.deviceId) ?? [])))
      .sorted()
  }
  var visibleDevices: [String] {
    Array(deviceIDs.dropFirst(devicePage * pageSize).prefix(pageSize))
  }
  var visibleUnmatched: [KoreaderUnmatchedBook] {
    Array(unmatched.dropFirst(unmatchedPage * pageSize).prefix(pageSize))
  }
  var visibleLinks: [KoreaderManualHashLink] {
    Array(links.dropFirst(linkPage * pageSize).prefix(pageSize))
  }

  func deviceName(_ id: String) -> String {
    status?.devices.first { $0.deviceId == id }?.device
      ?? status?.sweeps.first { $0.deviceId == id }?.deviceModel ?? id
  }
  func device(_ id: String) -> KoreaderDeviceInfo? {
    status?.devices.first { $0.deviceId == id }
  }
  func sweep(_ id: String) -> KoreaderDeviceSweepInfo? {
    status?.sweeps.first { $0.deviceId == id }
  }
  func isRetired(_ id: String) -> Bool {
    device(id)?.retiredAt != nil || sweep(id)?.retiredAt != nil
  }
  func patterns(_ id: String) -> (pattern: String, series: String, standalone: String) {
    let device = device(id)
    let sweep = sweep(id)
    return (
      device?.fileNamingPattern ?? sweep?.fileNamingPattern ?? "",
      device?.seriesFileNamingPattern ?? sweep?.seriesFileNamingPattern ?? "",
      device?.standaloneFileNamingPattern ?? sweep?.standaloneFileNamingPattern ?? ""
    )
  }

  func load() async {
    guard isPermitted, !isMutating else { return }
    let request = UUID()
    requestID = request
    isBusy = true
    error = nil
    defer { if requestID == request { isBusy = false } }
    do {
      let status: KoreaderSyncStatus = try await api.boundedJSONOnline("koreader/sync-status")
      guard requestID == request else { return }
      guard status.devices.count <= 200, status.sweeps.count <= 200 else {
        throw ConnectionError.responseTooLarge
      }
      self.status = status
      guard status.credentials != nil else {
        unmatched = []
        links = []
        return
      }
      let pattern: KoreaderFileNamingPattern = try await api.boundedJSONOnline(
        "koreader/file-naming-pattern")
      guard requestID == request else { return }
      defaultPattern = pattern.pattern
      let unmatched: [KoreaderUnmatchedBook] = try await api.boundedJSONOnline(
        "koreader/unmatched-books")
      guard requestID == request else { return }
      guard unmatched.count <= 100 else { throw ConnectionError.invalidResponse }
      self.unmatched = unmatched
      let links: [KoreaderManualHashLink] = try await api.boundedJSONOnline("koreader/hash-links")
      guard requestID == request else { return }
      guard links.count <= 100 else { throw ConnectionError.invalidResponse }
      self.links = links
      devicePage = min(devicePage, max(0, (deviceIDs.count - 1) / pageSize))
      unmatchedPage = min(unmatchedPage, max(0, (unmatched.count - 1) / pageSize))
      linkPage = min(linkPage, max(0, (links.count - 1) / pageSize))
    } catch {
      if requestID == request, !Task.isCancelled { self.error = error.localizedDescription }
    }
  }

  func saveDefaultPattern() async {
    await mutate {
      guard !self.defaultPattern.isEmpty, self.defaultPattern.count <= 1000 else {
        throw KOReaderManagementError.invalidPattern
      }
      let payload = KoreaderFileNamingPattern(pattern: self.defaultPattern)
      let _: KoreaderFileNamingPattern = try await self.api.boundedJSONOnline(
        "koreader/file-naming-pattern", method: "PUT", body: JSONEncoder().encode(payload))
      self.result = "Default file naming pattern saved."
    }
  }

  func saveDevicePatterns(_ id: String, pattern: String, series: String, standalone: String) async {
    await mutate {
      try self.validateDevice(id)
      guard [pattern, series, standalone].allSatisfy({ $0.count <= 1000 }) else {
        throw KOReaderManagementError.invalidPattern
      }
      let payload = UpdateKoreaderDeviceFilePatternPayload(
        pattern: pattern, seriesPattern: series, standalonePattern: standalone)
      let _: UpdateKoreaderDeviceFilePatternPayload = try await self.api.boundedJSONOnline(
        "koreader/devices/\(id)/file-naming-pattern", method: "PUT",
        body: JSONEncoder().encode(payload))
      self.result = "Device file naming patterns saved."
    }
  }

  func clearDevicePatterns(_ id: String) async {
    await mutate {
      try self.validateDevice(id)
      try await self.api.sendEmpty("koreader/devices/\(id)/file-naming-pattern", method: "DELETE")
      self.result = "Device file naming patterns reset to the account default."
    }
  }

  func retireDevice(_ id: String, retired: Bool) async {
    await mutate {
      try self.validateDevice(id)
      let payload = UpdateKoreaderDevicePayload(retired: retired)
      try await self.api.sendEmpty(
        "koreader/devices/\(id)", method: "PATCH", body: JSONEncoder().encode(payload))
      self.result = retired ? "Device retired." : "Device restored."
    }
  }

  func removeDevice(_ id: String) async {
    await mutate {
      try self.validateDevice(id)
      try await self.api.sendEmpty("koreader/devices/\(id)", method: "DELETE")
      self.result = "Device removed."
    }
  }

  func linkBook(hash: String, bookID: Int, existing: Bool) async {
    await mutate {
      try self.validateHash(hash)
      guard bookID > 0 else { throw ConnectionError.invalidResponse }
      if existing {
        let payload = UpdateKoreaderManualHashLinkPayload(bookId: bookID)
        let _: LinkKoreaderUnmatchedBookResult = try await self.api.boundedJSONOnline(
          "koreader/hash-links/\(hash)", method: "PATCH", body: JSONEncoder().encode(payload))
      } else {
        let payload = LinkKoreaderUnmatchedBookPayload(bookId: bookID)
        let _: LinkKoreaderUnmatchedBookResult = try await self.api.boundedJSONOnline(
          "koreader/unmatched-books/\(hash)/link", method: "POST",
          body: JSONEncoder().encode(payload), expectedStatus: 201)
      }
      self.result = existing ? "Book link changed." : "KOReader book linked."
    }
  }

  func dismissBook(_ hash: String) async {
    await mutate {
      try self.validateHash(hash)
      let _: DismissKoreaderUnmatchedBookResult = try await self.api.boundedJSONOnline(
        "koreader/unmatched-books/\(hash)", method: "DELETE")
      self.result = "Unmatched book dismissed."
    }
  }

  func dismissAll() async {
    await mutate {
      let response: DismissAllKoreaderUnmatchedBooksResult = try await self.api.boundedJSONOnline(
        "koreader/unmatched-books", method: "DELETE")
      self.result = "Dismissed \(response.count.formatted()) unmatched books."
    }
  }

  func unlinkBook(_ hash: String) async {
    await mutate {
      try self.validateHash(hash)
      let _: UnlinkKoreaderManualHashLinkResult = try await self.api.boundedJSONOnline(
        "koreader/hash-links/\(hash)", method: "DELETE")
      self.result = "Manual book link removed."
    }
  }

  func preparePlugin() async {
    await mutate(refresh: false) {
      self.discardPlugin()
      let bytes: Data
      do {
        bytes = try await self.api.downloadKOReaderPlugin()
      } catch ConnectionError.http(400) {
        throw KOReaderManagementError.pluginCredentials
      }
      self.plugin = try KOReaderPluginArtifact.stage(bytes)
      self.result =
        "Plugin prepared. Save the ZIP and extract bookorbit.koplugin into koreader/plugins on your device."
    }
  }

  func discardPlugin() {
    plugin?.remove()
    plugin = nil
  }

  private func validateDevice(_ id: String) throws {
    guard deviceIDs.contains(id),
      id.range(of: "^[A-Za-z0-9-]{1,100}$", options: .regularExpression) != nil
    else {
      throw ConnectionError.invalidResponse
    }
  }
  private func validateHash(_ hash: String) throws {
    guard hash.range(of: "^[A-Fa-f0-9]{32}$", options: .regularExpression) != nil else {
      throw ConnectionError.invalidResponse
    }
  }
  private func mutate(refresh: Bool = true, _ action: @MainActor () async throws -> Void) async {
    guard isPermitted, hasCredentials, !isMutating else { return }
    requestID = UUID()
    isBusy = false
    isMutating = true
    error = nil
    result = nil
    do { try await action() } catch {
      if !Task.isCancelled { self.error = error.localizedDescription }
    }
    isMutating = false
    if error == nil, refresh, !Task.isCancelled { await load() }
  }
}

enum KOReaderManagementError: LocalizedError {
  case invalidPattern, pluginCredentials
  var errorDescription: String? {
    switch self {
    case .invalidPattern:
      "Use a naming pattern with at most 1,000 characters. The account default cannot be empty."
    case .pluginCredentials:
      "Save your KOReader password again in catalog settings, then retry preparing the plugin."
    }
  }
}
