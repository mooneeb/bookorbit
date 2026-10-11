import Foundation
import Observation

@MainActor @Observable
final class ReadingPrivacyModel {
  let api: BookOrbitAPI
  var selectedLevel = "private" {
    didSet {
      if selectedLevel != oldValue { message = nil }
    }
  }
  private(set) var settings: ReadingInsightsSharingSettings?
  private(set) var restrictions: ContentFilterRulesWithNames?
  private(set) var preview: ReadingInsightsPreview?
  private(set) var history: ReadingInsightsAccessHistoryPage?
  private(set) var isBusy = false
  private(set) var message: String?
  private(set) var error: String?
  private(set) var saveFailed = false

  init(api: BookOrbitAPI) { self.api = api }

  func load() async {
    guard !isBusy else { return }
    isBusy = true
    error = nil
    message = nil
    saveFailed = false
    defer { isBusy = false }
    do {
      let session = try await api.authenticatedSessionGeneration()
      let settings = try await api.readingPrivacySettings(session: session)
      let restrictions = try await api.readingContentRestrictions(session: session)
      try Task.checkCancellation()
      self.settings = settings
      selectedLevel = settings.sharingLevel
      self.restrictions = restrictions
    } catch {
      if !Task.isCancelled { self.error = error.localizedDescription }
    }
  }

  func save() async {
    guard !isBusy, settings != nil else { return }
    isBusy = true
    error = nil
    message = nil
    saveFailed = false
    preview = nil
    defer { isBusy = false }
    do {
      let session = try await api.authenticatedSessionGeneration()
      let settings = try await api.updateReadingPrivacy(level: selectedLevel, session: session)
      try Task.checkCancellation()
      self.settings = settings
      selectedLevel = settings.sharingLevel
      message =
        settings.sharingLevel == "private"
        ? "Sharing is off. Existing insight access is revoked." : "Sharing settings saved."
    } catch {
      if !Task.isCancelled {
        saveFailed = true
        self.error = "Could not confirm your sharing setting. " + error.localizedDescription
      }
    }
  }

  func loadPreview() async {
    guard !isBusy else { return }
    isBusy = true
    error = nil
    saveFailed = false
    preview = nil
    defer { isBusy = false }
    do {
      let session = try await api.authenticatedSessionGeneration()
      let preview = try await api.readingPrivacyPreview(session: session)
      try Task.checkCancellation()
      self.preview = preview
    } catch {
      if !Task.isCancelled { self.error = error.localizedDescription }
    }
  }

  func loadHistory(page: Int = 1) async {
    guard !isBusy else { return }
    isBusy = true
    error = nil
    saveFailed = false
    defer { isBusy = false }
    do {
      let session = try await api.authenticatedSessionGeneration()
      let history = try await api.readingPrivacyHistory(page: page, session: session)
      try Task.checkCancellation()
      self.history = history
    } catch {
      if !Task.isCancelled { self.error = error.localizedDescription }
    }
  }
}
