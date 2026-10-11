import Foundation
import Observation

@MainActor @Observable
final class ReadwiseModel {
  let api: BookOrbitAPI
  private(set) var settings: ReadwiseSettings?
  private(set) var status: ReadwiseSyncStatus?
  private(set) var isBusy = false
  private(set) var error: String?
  private(set) var feedback: String?
  var token = ""
  var enabled = true
  var includeExistingHighlights = false

  init(api: BookOrbitAPI) { self.api = api }

  var canSave: Bool {
    !isBusy
      && (!token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || settings?.tokenConfigured == true)
  }

  var canSync: Bool { !isBusy && settings?.effectiveEnabled == true }

  var stateLabel: String {
    guard let status else { return "No sync has run" }
    switch status.state {
    case "idle": return "No sync has run"
    case "queued": return "Queued"
    case "running": return "Exporting highlights"
    case "succeeded": return "Delivery confirmed"
    case "failed": return "Delivery failed"
    case "interrupted": return "Interrupted: ready to resume"
    default: return "Refreshing sync status"
    }
  }

  func refresh() async {
    await perform {
      async let settings = self.api.readwiseSettings()
      async let status = self.api.readwiseSyncStatus()
      let loaded = try await (settings, status)
      if self.settings == nil { self.enabled = loaded.0.enabled }
      self.settings = loaded.0
      self.status = loaded.1
    }
  }

  func save() async {
    await perform {
      let trimmed = self.token.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        let validation = try await self.api.validateReadwiseToken(trimmed)
        guard validation.valid else {
          self.feedback = "Token validation failed. Check the token and connection, then try again."
          return
        }
      }
      self.settings = try await self.api.saveReadwiseSettings(
        UpsertReadwiseSettingsPayload(
          apiToken: trimmed.isEmpty ? nil : trimmed, enabled: self.enabled,
          includeExistingHighlights: self.includeExistingHighlights))
      self.token = ""
      self.includeExistingHighlights = false
      self.status = try await self.api.readwiseSyncStatus()
      self.feedback = "Readwise settings saved."
    }
  }

  func validate() async {
    await perform {
      let trimmed = self.token.trimmingCharacters(in: .whitespacesAndNewlines)
      let validation = try await self.api.validateReadwiseToken(trimmed.isEmpty ? nil : trimmed)
      self.feedback =
        validation.valid
        ? "Token is valid."
        : "Token validation failed. Check the token and connection, then try again."
    }
  }

  func sync() async {
    await perform {
      self.status = try await self.api.synchronizeReadwise()
      self.feedback = "Readwise sync requested."
    }
  }

  func disconnect() async {
    await perform {
      self.settings = try await self.api.saveReadwiseSettings(
        UpsertReadwiseSettingsPayload(apiToken: "", enabled: false, includeExistingHighlights: nil))
      self.enabled = false
      self.token = ""
      self.feedback = "Readwise disconnected."
    }
  }

  func monitor() async {
    await refresh()
    while !Task.isCancelled {
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
      if !isBusy { await refresh() }
    }
  }

  private func perform(_ operation: () async throws -> Void) async {
    guard !isBusy else { return }
    isBusy = true
    error = nil
    defer { isBusy = false }
    do {
      let generation = try await api.authenticatedSessionGeneration()
      try await operation()
      guard generation == (try await api.authenticatedSessionGeneration()) else {
        settings = nil
        status = nil
        token = ""
        feedback = nil
        throw ConnectionError.expiredSession
      }
    } catch is CancellationError {
    } catch {
      self.error = error.localizedDescription
    }
  }
}
