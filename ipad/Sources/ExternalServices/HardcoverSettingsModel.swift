import Foundation
import Observation

@MainActor @Observable
final class HardcoverSettingsModel {
  let api: BookOrbitAPI
  var token = ""
  var enabled = false
  var mode = "selected_only"
  var statusChanges = true
  var progressChanges = true
  var ratingChanges = true
  var privacy = 3
  private(set) var settings: HardcoverSettings?
  private(set) var outcome: HardcoverSyncOutcome?
  private(set) var linkedBooks: HardcoverLinkedBooksResult?
  private(set) var busy = false
  private(set) var error: String?
  private(set) var message: String?

  init(api: BookOrbitAPI) { self.api = api }

  var running: Bool { outcome?.status == "running" }

  func load() async {
    guard !busy else { return }
    busy = true
    error = nil
    defer { busy = false }
    do {
      let fresh = try await api.hardcoverSettings()
      try Task.checkCancellation()
      accept(fresh)
      outcome = try await api.hardcoverOutcome()
      if fresh.effectiveEnabled {
        linkedBooks = try await api.hardcoverLinkedBooks()
      } else {
        linkedBooks = nil
      }
    } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
  }

  func save() async {
    guard !busy else { return }
    busy = true
    error = nil
    message = nil
    defer { busy = false }
    do {
      let enteredToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
      if !enteredToken.isEmpty {
        let verification = try await api.validateHardcoverToken(enteredToken)
        guard verification.valid else {
          error =
            "Hardcover could not verify this token. Check your token and connection, then try again."
          return
        }
      }
      let result = try await api.saveHardcoverSettings(
        UpsertHardcoverSettingsPayload(
          apiToken: enteredToken.isEmpty ? nil : enteredToken, enabled: enabled, bookSyncMode: mode,
          autoSyncOnStatusChange: statusChanges, autoSyncOnProgressUpdate: progressChanges,
          autoSyncOnRatingChange: ratingChanges, privacySettingId: privacy))
      accept(result)
      token = ""
      message = "Settings confirmed by BookOrbit."
    } catch { self.error = "Settings could not be confirmed. \(error.localizedDescription)" }
  }

  func validate() async {
    guard !busy else { return }
    busy = true
    error = nil
    message = nil
    defer { busy = false }
    do {
      let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
      let result = try await api.validateHardcoverToken(value.isEmpty ? nil : value)
      if result.valid {
        message = "Hardcover verified \(result.hardcoverUsername ?? "your account")."
      } else {
        error = "Hardcover could not verify your token. Check your credentials and connection."
      }
    } catch { self.error = error.localizedDescription }
  }

  func disconnect() async {
    guard !busy else { return }
    busy = true
    error = nil
    message = nil
    defer { busy = false }
    do {
      try await api.disconnectHardcover()
      accept(try await api.hardcoverSettings())
      token = ""
      linkedBooks = nil
      message = "Hardcover disconnected."
    } catch { self.error = "Disconnect could not be confirmed. \(error.localizedDescription)" }
  }

  func startSync() async {
    guard !busy, !running else { return }
    busy = true
    error = nil
    message = nil
    defer { busy = false }
    do {
      let start = try await api.startHardcoverSync()
      guard start.runId > 0 else { throw ConnectionError.invalidResponse }
      outcome = try await api.hardcoverOutcome()
    } catch {
      self.error =
        "Sync could not be started. Refresh before retrying. \(error.localizedDescription)"
    }
  }

  func cancel() async {
    guard !busy, running else { return }
    busy = true
    defer { busy = false }
    do {
      try await api.cancelHardcoverSync()
      message = "Cancellation requested. The current record will finish before the job stops."
    } catch { self.error = error.localizedDescription }
  }

  func reconcile() async {
    guard !busy else { return }
    do {
      outcome = try await api.hardcoverOutcome()
      error = nil
    } catch {
      if !Task.isCancelled {
        self.error = "Sync status could not be refreshed. \(error.localizedDescription)"
      }
    }
  }

  private func accept(_ fresh: HardcoverSettings) {
    settings = fresh
    enabled = fresh.enabled
    mode = fresh.bookSyncMode
    statusChanges = fresh.autoSyncOnStatusChange
    progressChanges = fresh.autoSyncOnProgressUpdate
    ratingChanges = fresh.autoSyncOnRatingChange
    privacy = fresh.privacySettingId
  }
}
