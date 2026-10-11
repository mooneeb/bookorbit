import Foundation
import Observation

@MainActor @Observable
final class MaintenanceSettingsModel {
  enum Action: String, Identifiable {
    case recommendations, achievements
    var id: String { rawValue }
    var title: String {
      self == .recommendations ? "Rebuild recommendation index" : "Backfill achievements"
    }
    var explanation: String {
      self == .recommendations
        ? "Rebuild recommendations for all books on this server. Existing books and reading data are preserved."
        : "Review existing activity for every active user and grant missing achievements. Existing awards are preserved."
    }
  }

  let api: BookOrbitAPI
  let user: AuthUser
  var updateChecksEnabled = true
  var uploadLimit = "500"
  var confirmation: Action?
  var error: String?
  private(set) var loaded = false
  private(set) var isSaving = false
  private(set) var isMonitoring = false
  private(set) var result: String?
  private(set) var recommendationStatus: MaintenanceOperationStatus?
  private(set) var achievementStatus: MaintenanceOperationStatus?
  private var savedUpdateChecks = true
  private var savedUploadLimit = "500"
  private var monitoring: Task<Void, Never>?

  init(api: BookOrbitAPI, user: AuthUser) {
    self.api = api
    self.user = user
  }

  var canManageSettings: Bool { user.hasPermission(.manageAppSettings) }
  var canBackfill: Bool { canManageSettings && user.isSuperuser }
  var updateChecksChanged: Bool { loaded && updateChecksEnabled != savedUpdateChecks }
  var uploadLimitChanged: Bool { loaded && uploadLimit != savedUploadLimit }
  var validUploadLimit: Bool {
    guard !uploadLimit.isEmpty, uploadLimit.allSatisfy({ $0.isASCII && $0.isNumber }),
      let value = Int(uploadLimit)
    else { return false }
    return (1...4096).contains(value)
  }

  func load() async {
    guard canManageSettings else { return }
    error = nil
    do {
      let settings = try await api.maintenanceSettings()
      let values = Dictionary(uniqueKeysWithValues: settings.map { ($0.key, $0.value) })
      updateChecksEnabled = values["update_check_enabled"] != "false"
      savedUpdateChecks = updateChecksEnabled
      uploadLimit = values["max_upload_size_mb"] ?? "500"
      savedUploadLimit = uploadLimit
      loaded = true
      try await refreshStatuses()
      if recommendationStatus?.status == "running" || achievementStatus?.status == "running" {
        monitor()
      }
    } catch { self.error = error.localizedDescription }
  }

  func saveUpdateChecks() {
    guard canManageSettings, updateChecksChanged, !isSaving else { return }
    save(key: "update_check_enabled", value: String(updateChecksEnabled))
  }

  func saveUploadLimit() {
    guard canManageSettings, uploadLimitChanged, validUploadLimit, !isSaving else { return }
    save(key: "max_upload_size_mb", value: uploadLimit)
  }

  private func save(key: String, value: String) {
    isSaving = true
    error = nil
    Task {
      defer { isSaving = false }
      do {
        let setting = try await api.updateMaintenanceSetting(key: key, value: value)
        if key == "update_check_enabled" {
          savedUpdateChecks = setting.value == "true"
          updateChecksEnabled = savedUpdateChecks
        } else {
          savedUploadLimit = setting.value
          uploadLimit = setting.value
        }
        result = "Settings saved."
      } catch { self.error = error.localizedDescription }
    }
  }

  func performConfirmedAction() {
    guard let action = confirmation, canManageSettings, !isMonitoring,
      action != .achievements || canBackfill
    else { return }
    confirmation = nil
    error = nil
    result = nil
    isMonitoring = true
    monitoring = Task {
      defer {
        isMonitoring = false
        monitoring = nil
      }
      do {
        if action == .recommendations {
          let outcome = try await api.rebuildRecommendationIndex()
          result = "\(outcome.queued) books queued for recommendations."
        } else {
          achievementStatus = try await api.startAchievementBackfill()
        }
        try await pollStatuses()
      } catch is CancellationError {
      } catch {
        self.error =
          "\(error.localizedDescription) Reconnect to review server progress before retrying."
      }
    }
  }

  private func monitor() {
    guard !isMonitoring else { return }
    isMonitoring = true
    monitoring = Task {
      defer {
        isMonitoring = false
        monitoring = nil
      }
      do { try await pollStatuses() } catch is CancellationError {
      } catch { self.error = error.localizedDescription }
    }
  }

  private func pollStatuses() async throws {
    repeat {
      try Task.checkCancellation()
      try await refreshStatuses()
      if recommendationStatus?.status != "running" && achievementStatus?.status != "running" {
        break
      }
      try await Task.sleep(for: .seconds(1))
    } while true
  }

  private func refreshStatuses() async throws {
    recommendationStatus = try await api.recommendationIndexStatus()
    if canBackfill { achievementStatus = try await api.achievementBackfillStatus() }
    remember(recommendationStatus, action: .recommendations)
    remember(achievementStatus, action: .achievements)
  }

  private func recoveryKey(_ action: Action) -> String {
    "maintenance.\(action.rawValue).\(api.profile.url.absoluteString).user.\(user.id)"
  }

  private func remember(_ status: MaintenanceOperationStatus?, action: Action) {
    guard let status, let runID = status.runId else { return }
    UserDefaults.standard.set(runID, forKey: recoveryKey(action))
  }

  func statusMessage(_ status: MaintenanceOperationStatus?, action: Action) -> String {
    guard let status else { return "Refresh to review server progress." }
    switch status.status {
    case "disabled": return "Recommendation processing is unavailable on this server."
    case "running":
      return "Processed \(status.processed), failed \(status.failed). Work continues on the server."
    case "completed":
      if action == .achievements {
        return
          "Reviewed \(status.processed) users, granted \(status.awardsGranted) awards, failed \(status.failed)."
      }
      return "Processed \(status.processed) books, failed \(status.failed)."
    case "failed": return "The run stopped. Review the result and retry to finish remaining work."
    default:
      return UserDefaults.standard.string(forKey: recoveryKey(action)) == nil
        ? "No run is reported by the current server process."
        : "The server no longer reports the previous run. Retry safely to rebuild the index or grant missing awards."
    }
  }
}
