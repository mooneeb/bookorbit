import Foundation
import Observation

@MainActor @Observable
final class SeriesCollapsePreferenceModel {
  let api: BookOrbitAPI
  private(set) var preferences: SeriesCollapsePreferences?
  private(set) var userID: Int?
  private(set) var isLoaded = false
  private(set) var isBusy = false
  private(set) var revision = 0
  private(set) var error: String?
  private(set) var pendingScope: SeriesCollapseScope?
  private var pendingValue: Bool?
  private var pendingSession: UUID?
  private var writeConfirmed = false
  private var operationID = UUID()

  init(api: BookOrbitAPI) { self.api = api }

  func receive(user: AuthUser?) {
    guard let user else {
      operationID = UUID()
      userID = nil
      preferences = nil
      isLoaded = false
      isBusy = false
      clearPending()
      revision += 1
      return
    }
    if userID != user.id {
      operationID = UUID()
      isBusy = false
      isLoaded = false
      preferences = nil
      clearPending()
      userID = user.id
    }
    guard !isBusy, !isLoaded else { return }
    accept(user)
  }

  func effective(in scope: SeriesCollapseScope) -> Bool { scope.effective(preferences) }

  func reconcile() async {
    guard !isBusy else { return }
    let operation = UUID()
    operationID = operation
    let expectedUserID = userID
    isBusy = true
    defer { if operationID == operation { isBusy = false } }
    do {
      let session = try await api.authenticatedSessionGeneration()
      let user = try await api.seriesCollapseUser(session: session)
      try Task.checkCancellation()
      guard operationID == operation, expectedUserID == nil || user.id == expectedUserID else {
        return
      }
      accept(user)
      if let scope = pendingScope, scope.matches(preferences, value: pendingValue) {
        clearPending()
      } else if pendingScope == nil {
        error = nil
      }
    } catch {
      guard operationID == operation, !Task.isCancelled else { return }
      self.error = "Could not refresh series preferences. " + error.localizedDescription
    }
  }

  func setPreference(in scope: SeriesCollapseScope, value: Bool?) async {
    guard isLoaded, userID != nil, !isBusy, pendingScope == nil else { return }
    pendingScope = scope
    pendingValue = value
    writeConfirmed = false
    await publish()
  }

  func retry() async {
    guard !isBusy else { return }
    if pendingScope != nil { await publish() } else { await reconcile() }
  }

  func revert() async {
    guard !isBusy else { return }
    clearPending()
    await reconcile()
  }

  private func publish() async {
    guard let scope = pendingScope, let expectedUserID = userID else { return }
    let operation = UUID()
    operationID = operation
    let value = pendingValue
    isBusy = true
    error = nil
    defer { if operationID == operation { isBusy = false } }
    do {
      let session = try await api.authenticatedSessionGeneration()
      guard pendingSession == nil || pendingSession == session else {
        throw ConnectionError.expiredSession
      }
      pendingSession = session
      if !writeConfirmed {
        try await api.updateSeriesCollapsePreferences(scope.payload(value: value), session: session)
        guard operationID == operation, userID == expectedUserID else { return }
        writeConfirmed = true
      }
      let user = try await api.seriesCollapseUser(session: session)
      try Task.checkCancellation()
      guard operationID == operation, user.id == expectedUserID, userID == expectedUserID else {
        return
      }
      accept(user)
      guard scope.matches(preferences, value: value) else {
        writeConfirmed = false
        error =
          "The server returned a different series preference. Review the current setting or retry."
        return
      }
      clearPending()
    } catch {
      guard operationID == operation, !Task.isCancelled else { return }
      self.error =
        (writeConfirmed
          ? "Preference saved, but confirmation failed. " : "Could not save series preference. ")
        + error.localizedDescription
    }
  }

  private func accept(_ user: AuthUser) {
    let next = user.settings.seriesCollapsePreferences
    if !isLoaded || preferences != next || userID != user.id { revision += 1 }
    userID = user.id
    preferences = next
    isLoaded = true
  }

  private func clearPending() {
    pendingScope = nil
    pendingValue = nil
    pendingSession = nil
    writeConfirmed = false
    error = nil
  }
}
