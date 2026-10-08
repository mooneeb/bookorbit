import Foundation
import Observation

@MainActor @Observable
final class NativeTTSPreferencesModel {
  let api: BookOrbitAPI
  let bookID: Int
  private(set) var speed = 1.0
  private(set) var defaultSpeed = 1.0
  private(set) var voiceIdentifier: String?
  private(set) var providerID: String?
  private(set) var voiceID: String?
  private(set) var useServer = false
  private(set) var isBookOverride = false
  private(set) var hasLoaded = false
  private(set) var isLoading = false
  private(set) var isSaving = false
  private(set) var canChangeSettings = false
  var error: String?
  private var storageKey: String?
  private var session: UUID?
  private var isClosed = false

  init(api: BookOrbitAPI, bookID: Int) {
    self.api = api
    self.bookID = bookID
  }

  var canSave: Bool {
    hasLoaded && canChangeSettings && !isLoading && !isSaving && !isClosed
  }

  func load() async {
    guard !isLoading, !isSaving, !isClosed else { return }
    hasLoaded = false
    isLoading = true
    error = nil
    defer { isLoading = false }
    do {
      let generation = try await api.authenticatedSessionGeneration()
      session = generation
      let namespace = try await api.storageNamespace()
      try await checkSession(generation)
      storageKey = "bookorbit.native-tts-voice.\(namespace)"
      async let effective: TtsEffectivePreferences = api.boundedJSON(
        "tts/preferences/book/\(bookID)", byteLimit: 16 * 1024, session: generation)
      async let defaults: TtsUserPreferences? = api.boundedJSON(
        "tts/preferences", byteLimit: 16 * 1024, session: generation)
      async let user: UserReaderSettingsResponse = api.boundedJSON("auth/me", session: generation)
      let (book, global, account) = try await (effective, defaults, user)
      try await checkSession(generation)
      guard Self.validSpeed(book.speed), global.map({ Self.validSpeed($0.speed) }) != false else {
        throw ConnectionError.invalidResponse
      }
      speed = book.speed
      providerID = book.providerId
      voiceID = book.voiceId
      defaultSpeed = global?.speed ?? 1
      isBookOverride = book.isBookOverride
      let local = localVoice(bookKey) ?? localVoice(defaultKey)
      voiceIdentifier = local?.voiceIdentifier
      useServer = local?.useServer ?? false
      canChangeSettings = !account.permissions.contains(Permission.demoRestricted.rawValue)
      hasLoaded = true
    } catch is CancellationError {
    } catch { if !isClosed { self.error = error.localizedDescription } }
  }

  func save(
    speed: Double, voiceIdentifier: String?, providerID: String?, voiceID: String?,
    useServer: Bool, asDefault: Bool
  ) async -> Bool {
    guard canSave, Self.validSpeed(speed), Self.validVoice(voiceIdentifier), let session,
      storageKey != nil,
      !useServer
        || (Self.validVoice(providerID) && providerID != nil
          && Self.validVoice(voiceID) && voiceID != nil)
    else { return false }
    isSaving = true
    error = nil
    var savedDefaults = false
    defer { isSaving = false }
    do {
      try await checkSession(session)
      let body = try JSONEncoder().encode(
        TtsPreferencesPatch(
          providerId: useServer ? providerID : nil,
          voiceId: useServer ? voiceID : nil, speed: speed))
      if asDefault {
        let saved: TtsUserPreferences = try await api.boundedJSON(
          "tts/preferences", method: "PUT", body: body, byteLimit: 16 * 1024, session: session)
        let confirmed: TtsUserPreferences = try await api.boundedJSON(
          "tts/preferences", byteLimit: 16 * 1024, session: session)
        try await checkSession(session)
        guard saved.speed == speed, confirmed.speed == speed,
          !useServer
            || (saved.providerId == providerID && saved.voiceId == voiceID
              && confirmed.providerId == providerID && confirmed.voiceId == voiceID)
        else { throw ConnectionError.invalidResponse }
        try persistVoice(voiceIdentifier, useServer: useServer, key: defaultKey)
        defaultSpeed = speed
        savedDefaults = true
      }
      try await api.sendEmpty(
        "tts/preferences/book/\(bookID)", method: "PUT", body: body, session: session)
      let effective: TtsEffectivePreferences = try await api.boundedJSON(
        "tts/preferences/book/\(bookID)", byteLimit: 16 * 1024, session: session)
      try await checkSession(session)
      guard effective.speed == speed, effective.isBookOverride,
        !useServer || (effective.providerId == providerID && effective.voiceId == voiceID)
      else { throw ConnectionError.invalidResponse }
      try persistVoice(voiceIdentifier, useServer: useServer, key: bookKey)
      isBookOverride = true
      self.voiceIdentifier = voiceIdentifier
      self.providerID = effective.providerId
      self.voiceID = effective.voiceId
      self.useServer = useServer
      self.speed = effective.speed
      return true
    } catch {
      if !isClosed {
        self.error =
          savedDefaults
          ? "Account speech defaults saved. This book could not be updated. Your draft is kept. \(error.localizedDescription)"
          : error.localizedDescription
      }
      return false
    }
  }

  func useDefaults() async -> Bool {
    guard canSave, let session, storageKey != nil else { return false }
    isSaving = true
    error = nil
    defer { isSaving = false }
    do {
      try await checkSession(session)
      try await api.sendEmpty(
        "tts/preferences/book/\(bookID)", method: "DELETE", session: session)
      let effective: TtsEffectivePreferences = try await api.boundedJSON(
        "tts/preferences/book/\(bookID)", byteLimit: 16 * 1024, session: session)
      try await checkSession(session)
      guard Self.validSpeed(effective.speed), !effective.isBookOverride else {
        throw ConnectionError.invalidResponse
      }
      UserDefaults.standard.removeObject(forKey: bookKey)
      let local = localVoice(defaultKey)
      voiceIdentifier = local?.voiceIdentifier
      useServer = local?.useServer ?? false
      providerID = effective.providerId
      voiceID = effective.voiceId
      speed = effective.speed
      defaultSpeed = effective.speed
      isBookOverride = false
      return true
    } catch {
      if !isClosed { self.error = error.localizedDescription }
      return false
    }
  }

  func close() { isClosed = true }

  static func validSpeed(_ speed: Double) -> Bool {
    speed.isFinite && (0.25...4).contains(speed)
  }

  private static func validVoice(_ value: String?) -> Bool {
    value.map { !$0.isEmpty && $0.utf8.count <= 512 } != false
  }

  private var defaultKey: String { "\(storageKey ?? "").defaults" }
  private var bookKey: String { "\(storageKey ?? "").book.\(bookID)" }

  private func localVoice(_ key: String) -> NativeTtsVoiceSettings? {
    guard let data = UserDefaults.standard.data(forKey: key), data.count <= 1024,
      let value = try? JSONDecoder().decode(NativeTtsVoiceSettings.self, from: data),
      Self.validVoice(value.voiceIdentifier)
    else { return nil }
    return value
  }

  private func persistVoice(_ identifier: String?, useServer: Bool, key: String) throws {
    let data = try JSONEncoder().encode(
      NativeTtsVoiceSettings(voiceIdentifier: identifier, useServer: useServer))
    UserDefaults.standard.set(data, forKey: key)
  }

  private func checkSession(_ expected: UUID) async throws {
    try Task.checkCancellation()
    let active = try await api.authenticatedSessionGeneration()
    try Task.checkCancellation()
    guard !isClosed, active == expected else {
      throw ConnectionError.expiredSession
    }
  }
}
