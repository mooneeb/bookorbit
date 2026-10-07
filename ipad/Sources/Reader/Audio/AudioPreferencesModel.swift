import Foundation
import Observation

extension AudioReaderSettings {
  var isValid: Bool {
    playbackSpeed.isFinite && (0.5...3).contains(playbackSpeed)
      && volume.isFinite && (0...1).contains(volume)
      && skipBackSeconds.isFinite && (0...9_007_199_254_740_991).contains(skipBackSeconds)
      && skipBackSeconds.rounded() == skipBackSeconds
      && skipForwardSeconds.isFinite && (0...9_007_199_254_740_991).contains(skipForwardSeconds)
      && skipForwardSeconds.rounded() == skipForwardSeconds
  }
}

@MainActor @Observable
final class AudioPreferencesModel {
  let api: BookOrbitAPI
  private(set) var value = AudioReaderSettings.readerDefault
  private(set) var hasLoaded = false
  private(set) var isLoading = false
  private(set) var isSaving = false
  private(set) var syncSettings = false
  private(set) var canSync = false
  var error: String?
  private var storageKey: String?
  private var generation: UUID?
  private var isClosed = false

  init(api: BookOrbitAPI) { self.api = api }

  var canSave: Bool {
    hasLoaded && !isLoading && !isSaving && !isClosed && (!syncSettings || canSync)
  }

  func load() async {
    guard !isLoading, !isSaving, !isClosed else { return }
    isLoading = true
    hasLoaded = false
    error = nil
    defer { isLoading = false }
    do {
      let session = try await api.authenticatedSessionGeneration()
      generation = session
      let namespace = try await api.storageNamespace()
      guard try await api.authenticatedSessionGeneration() == session, !isClosed else { return }
      storageKey = "bookorbit.audio-settings.\(namespace)"
      value = .readerDefault
      if let storageKey, let data = UserDefaults.standard.data(forKey: storageKey),
        let saved = try? JSONDecoder().decode(AudioReaderSettings.self, from: data), saved.isValid
      {
        value = saved
      }
      let user: UserReaderSettingsResponse = try await api.boundedJSON("auth/me", session: session)
      guard !isClosed else { return }
      syncSettings = user.settings.syncReaderPreferences == true
      canSync = !user.permissions.contains(Permission.demoRestricted.rawValue)
      if syncSettings {
        let response: AudioReaderDefaultsResponse = try await api.boundedJSON(
          "reader/defaults", session: session)
        guard !isClosed else { return }
        var resolved = AudioReaderSettings.readerDefault
        if let settings = response.audio {
          resolved.playbackSpeed = settings.playbackSpeed ?? resolved.playbackSpeed
          resolved.volume = settings.volume ?? resolved.volume
          resolved.skipBackSeconds = settings.skipBackSeconds ?? resolved.skipBackSeconds
          resolved.skipForwardSeconds = settings.skipForwardSeconds ?? resolved.skipForwardSeconds
        }
        guard resolved.isValid else { throw ConnectionError.invalidResponse }
        value = resolved
      }
      hasLoaded = true
    } catch is CancellationError {
    } catch { if !isClosed { self.error = error.localizedDescription } }
  }

  func save(_ draft: AudioReaderSettings) async -> Bool {
    guard canSave, draft.isValid, let generation, let storageKey else { return false }
    isSaving = true
    error = nil
    defer { isSaving = false }
    do {
      guard try await api.authenticatedSessionGeneration() == generation else {
        throw ConnectionError.expiredSession
      }
      if syncSettings {
        let payload = AudioReaderDefaultsPatchBody(
          set: .init(
            playbackSpeed: draft.playbackSpeed, volume: draft.volume,
            skipBackSeconds: draft.skipBackSeconds, skipForwardSeconds: draft.skipForwardSeconds))
        try await api.sendEmpty(
          "reader/defaults/audio", method: "PATCH", body: JSONEncoder().encode(payload),
          session: generation)
      }
      guard !isClosed, try await api.authenticatedSessionGeneration() == generation else {
        return false
      }
      UserDefaults.standard.set(try JSONEncoder().encode(draft), forKey: storageKey)
      value = draft
      return true
    } catch {
      if !isClosed { self.error = error.localizedDescription }
      return false
    }
  }

  func close() { isClosed = true }
}
