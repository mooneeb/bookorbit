import Foundation
import Observation

enum DashboardShelfType: String, CaseIterable, Identifiable {
  case recentlyAdded = "recently-added"
  case continueReading = "continue-reading"
  case continueListening = "continue-listening"
  case wantToRead = "want-to-read"
  case upNext = "up-next-in-series"
  case random
  case smartScope = "smart-scope"

  var id: String { rawValue }
  var title: String {
    switch self {
    case .recentlyAdded: "Recently added"
    case .continueReading: "Continue reading"
    case .continueListening: "Continue listening"
    case .wantToRead: "Want to read"
    case .upNext: "Up next in series"
    case .random: "Discover something new"
    case .smartScope: "Smart scope"
    }
  }
}

struct DashboardShelf: Identifiable {
  let configuration: ScrollerConfig
  let books: [BookCard]
  let failed: Bool
  var id: String { configuration.id }
}

@MainActor @Observable
final class DashboardModel {
  let api: BookOrbitAPI
  let canSync: Bool
  let coverNamespace: String
  private(set) var configuration = DashboardModel.defaultConfiguration
  private(set) var shelves: [DashboardShelf] = []
  private(set) var isBusy = false
  private(set) var isSaving = false
  var error: String?
  var settingsError: String?
  private let storageKey: String
  private var requestID = UUID()

  init(api: BookOrbitAPI, serverURL: String, user: AuthUser) {
    self.api = api
    canSync = !user.permissions.contains(Permission.demoRestricted.rawValue)
    storageKey = "bookorbit.dashboard.\(serverURL).user.\(user.id)"
    coverNamespace = storageKey
  }

  static var defaultConfiguration: DashboardShelfConfig {
    let types: [DashboardShelfType] = [
      .recentlyAdded, .random, .continueReading, .continueListening,
    ]
    return DashboardShelfConfig(
      syncAcrossSessions: false,
      scrollers: types.enumerated().map { index, type in
        ScrollerConfig(
          id: type.rawValue, type: type.rawValue, label: type.title,
          enabled: true, order: Double(index + 1), limit: 20, rows: 1, smartScopeId: nil)
      }, shelfLayout: "wide")
  }

  func load() async {
    guard !isSaving else { return }
    let id = UUID()
    requestID = id
    isBusy = true
    error = nil
    defer { if requestID == id { isBusy = false } }
    do {
      let user: UserDashboardSettingsResponse = try await api.send("auth/me")
      guard requestID == id else { return }
      if let serverConfig = user.settings.dashboardShelfConfig,
        serverConfig.syncAcrossSessions == true
      {
        configuration = normalized(serverConfig)
      } else if let data = UserDefaults.standard.data(forKey: storageKey),
        let local = try? JSONDecoder().decode(DashboardShelfConfig.self, from: data)
      {
        configuration = normalized(local)
        configuration.syncAcrossSessions = false
      } else {
        configuration = Self.defaultConfiguration
      }
      try await loadShelves(requestID: id)
    } catch {
      guard requestID == id else { return }
      self.error = error.localizedDescription
    }
  }

  func save(_ configuration: DashboardShelfConfig) async -> Bool {
    guard !isSaving else { return false }
    isSaving = true
    settingsError = nil
    defer { isSaving = false }
    do {
      let next = normalized(configuration)
      if next.syncAcrossSessions == true || self.configuration.syncAcrossSessions == true {
        guard canSync else { throw DashboardError.syncRestricted }
        let payload = UserDashboardSettingsResponse(
          settings: UserSettings(dashboardConfig: nil, dashboardShelfConfig: next))
        try await api.sendEmpty(
          "users/me/settings", method: "PATCH", body: JSONEncoder().encode(payload))
      }
      UserDefaults.standard.set(try JSONEncoder().encode(next), forKey: storageKey)
      self.configuration = next
      let id = UUID()
      requestID = id
      isBusy = true
      error = nil
      defer { if requestID == id { isBusy = false } }
      do { try await loadShelves(requestID: id) } catch {
        if requestID == id { self.error = error.localizedDescription }
      }
      return true
    } catch {
      settingsError = error.localizedDescription
      return false
    }
  }

  private func loadShelves(requestID: UUID) async throws {
    let active = (configuration.scrollers ?? []).filter {
      $0.enabled && DashboardShelfType(rawValue: $0.type) != nil
    }
    guard !active.isEmpty else {
      shelves = []
      return
    }
    let request = DashboardScrollerBatchRequest(
      items: active.map { shelf in
        DashboardScrollerBatchItem(
          id: shelf.id, type: shelf.type,
          limit: min(50, shelf.limit * shelf.rows), smartScopeId: shelf.smartScopeId)
      })
    let response: DashboardScrollerBatchResponse = try await api.send(
      "dashboard/scrollers/batch", method: "POST", body: JSONEncoder().encode(request))
    guard self.requestID == requestID else { return }
    let byID = Dictionary(
      response.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    shelves = active.map { shelf in
      DashboardShelf(
        configuration: shelf, books: byID[shelf.id]?.books ?? [],
        failed: byID[shelf.id]?.failed ?? true)
    }
  }

  private func normalized(_ config: DashboardShelfConfig) -> DashboardShelfConfig {
    var ids = Set<String>()
    var scrollers: [ScrollerConfig] = []
    for var shelf in (config.scrollers ?? []).prefix(8) {
      guard DashboardShelfType(rawValue: shelf.type) != nil || shelf.type == "continue-podcasts"
      else { continue }
      if shelf.id.isEmpty || shelf.id.count > 64 || !ids.insert(shelf.id).inserted {
        shelf.id = UUID().uuidString
        ids.insert(shelf.id)
      }
      shelf.limit = min(50, max(1, shelf.limit.rounded(.towardZero)))
      shelf.rows = min(3, max(1, shelf.rows.rounded(.towardZero)))
      shelf.order = Double(scrollers.count + 1)
      scrollers.append(shelf)
    }
    if scrollers.isEmpty { scrollers = Self.defaultConfiguration.scrollers ?? [] }
    return DashboardShelfConfig(
      syncAcrossSessions: config.syncAcrossSessions,
      scrollers: scrollers,
      shelfLayout: config.shelfLayout == "two-columns" ? "two-columns" : "wide")
  }

  func close() { requestID = UUID() }
}

enum DashboardError: LocalizedError {
  case syncRestricted
  var errorDescription: String? { "This account cannot change dashboard sync settings." }
}
