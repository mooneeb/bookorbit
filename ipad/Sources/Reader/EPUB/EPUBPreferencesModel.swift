import Foundation
import Observation

struct EPUBPreferencesValue: Codable, Equatable {
  var settings = EpubReaderSettings.readerDefault
  var pageAnimation = ReaderTurnAnimation.curl

  var isValid: Bool {
    let s = settings
    return EPUBThemeVocabulary.names.contains(s.themeName) && s.fontSize.isFinite
      && (6...32).contains(s.fontSize)
      && s.fontWeight.isFinite && (1...1000).contains(s.fontWeight)
      && s.fontWeight.rounded() == s.fontWeight
      && ["normal", "italic"].contains(s.fontStyle)
      && s.lineHeight.isFinite && (0.8...3).contains(s.lineHeight)
      && s.paragraphSpacing.isFinite && (0...2).contains(s.paragraphSpacing)
      && (s.letterSpacing.map({ $0.isFinite && (0...0.2).contains($0) }) ?? true)
      && (s.wordSpacing.map({ $0.isFinite && (0...0.5).contains($0) }) ?? true)
      && (s.textIndent.map({ $0.isFinite && (0...4).contains($0) }) ?? true)
      && s.maxColumnCount.isFinite && (1...10).contains(s.maxColumnCount)
      && s.maxColumnCount.rounded() == s.maxColumnCount
      && s.gap.isFinite && (0...0.5).contains(s.gap)
      && s.maxInlineSize.isFinite && (400...1600).contains(s.maxInlineSize)
      && s.maxInlineSize.rounded() == s.maxInlineSize
      && s.maxBlockSize.isFinite && (600...2400).contains(s.maxBlockSize)
      && s.maxBlockSize.rounded() == s.maxBlockSize
      && ["paginated", "scrolled"].contains(s.flow)
      && [0, 1, 2].contains(s.footerDisplayMode)
      && ["auto", "none"].contains(s.fixedLayoutSpread)
  }
}

@MainActor @Observable
final class EPUBPreferencesModel {
  let api: BookOrbitAPI
  let fileID: Int
  let fonts: EPUBCustomFontsModel
  @ObservationIgnored var validateFont: (@MainActor (EPUBPreferencesValue) async throws -> Void)?
  private(set) var value = EPUBPreferencesValue()
  private(set) var defaults = EPUBPreferencesValue()
  private(set) var isCustomized = false
  private(set) var hasLoaded = false
  private(set) var isLoading = false
  private(set) var isSaving = false
  private(set) var error: String?
  private(set) var syncSettings = false
  private(set) var canSync = false
  private var key: String?
  private var generation: UUID?
  private var isClosed = false
  private var pending: EPUBPreferencesValue?
  private var pendingAsDefault = false
  private var defaultConfirmed = false
  private var pendingReset = false
  var hasPendingSave: Bool { pending != nil || pendingReset }

  init(api: BookOrbitAPI, fileID: Int) {
    self.api = api
    self.fileID = fileID
    fonts = EPUBCustomFontsModel(api: api)
  }
  var canSave: Bool {
    hasLoaded && !isLoading && !isSaving && !isClosed
  }
  var useFormatting: Bool { isCustomized || defaults.settings.overrideBookFormatting }
  private var defaultKey: String? { key.map { $0 + ".defaults" } }
  private var bookKey: String? { key.map { $0 + ".file.\(fileID)" } }

  func load() async {
    guard !isLoading, !isSaving, !isClosed, !hasPendingSave else { return }
    isLoading = true
    error = nil
    hasLoaded = false
    defer { isLoading = false }
    do {
      let session = try await api.authenticatedSessionGeneration()
      let namespace = try await api.storageNamespace()
      guard try await api.authenticatedSessionGeneration() == session else {
        throw ConnectionError.expiredSession
      }
      generation = session
      key = "bookorbit.epub-preferences.\(namespace)"
      defaults = cached(defaultKey) ?? EPUBPreferencesValue()
      let local = cached(bookKey)
      value = local ?? defaults
      isCustomized = local != nil
      let user: UserReaderSettingsResponse = try await api.boundedJSON("auth/me", session: session)
      syncSettings = user.settings.syncReaderPreferences == true
      canSync = !user.permissions.contains(Permission.demoRestricted.rawValue)
      if syncSettings {
        let remote: EpubReaderDefaultsResponse = try await api.boundedJSON(
          "reader/defaults", session: session)
        defaults.settings = try merged(remote.epub, over: .readerDefault)
        let book: EpubReaderPreferenceResponse = try await api.boundedJSON(
          "reader/preferences/\(fileID)", session: session)
        guard book.isCustomized == (book.settings != nil) else {
          throw ConnectionError.invalidResponse
        }
        value = local ?? defaults
        value.settings = try merged(book.settings, over: defaults.settings)
        isCustomized = book.isCustomized
      }
      guard value.isValid, defaults.isValid, !isClosed else {
        throw ConnectionError.invalidResponse
      }
      hasLoaded = true
      await fonts.load()
    } catch { if !isClosed { self.error = error.localizedDescription } }
  }

  func save(_ requested: EPUBPreferencesValue, asDefault: Bool) async -> Bool {
    guard canSave, requested.isValid, !hasPendingSave, !asDefault || !syncSettings || canSync else {
      return false
    }
    isSaving = true
    error = nil
    do {
      if let validateFont {
        try await validateFont(requested)
      } else if EPUBCustomFontsModel.isCustom(requested.settings.fontFamily) {
        throw EPUBFontError.loadFailed
      }
      guard !isClosed else { throw CancellationError() }
    } catch {
      isSaving = false
      if !isClosed { self.error = error.localizedDescription }
      return false
    }
    isSaving = false
    pending = requested
    pendingAsDefault = asDefault
    defaultConfirmed = false
    return await retry()
  }

  func retry() async -> Bool {
    guard canSave, hasPendingSave, let generation else { return false }
    isSaving = true
    error = nil
    defer { isSaving = false }
    do {
      if pendingReset {
        if syncSettings {
          let remote: EpubReaderDefaultsResponse = try await api.boundedJSON(
            "reader/defaults", session: generation)
          let resolved = try merged(remote.epub, over: .readerDefault)
          try await api.sendEmpty(
            "reader/preferences/\(fileID)", method: "DELETE", session: generation)
          let book: EpubReaderPreferenceResponse = try await api.boundedJSON(
            "reader/preferences/\(fileID)", session: generation)
          guard !book.isCustomized, book.settings == nil else {
            throw ConnectionError.invalidResponse
          }
          defaults.settings = resolved
        }
        guard !isClosed, try await api.authenticatedSessionGeneration() == generation else {
          throw ConnectionError.expiredSession
        }
        if let bookKey { UserDefaults.standard.removeObject(forKey: bookKey) }
        value = defaults
        isCustomized = false
        pendingReset = false
        return true
      }
      guard let requested = pending else { throw ConnectionError.invalidResponse }
      if pendingAsDefault, !defaultConfirmed {
        if syncSettings {
          try await persistRemote(requested.settings, asDefault: true, session: generation)
        }
        guard !isClosed, try await api.authenticatedSessionGeneration() == generation else {
          throw ConnectionError.expiredSession
        }
        defaults = requested
        try store(requested, at: defaultKey)
        defaultConfirmed = true
      }
      if syncSettings {
        try await persistRemote(requested.settings, asDefault: false, session: generation)
      }
      guard !isClosed, try await api.authenticatedSessionGeneration() == generation else {
        throw ConnectionError.expiredSession
      }
      try store(requested, at: bookKey)
      value = requested
      isCustomized = true
      pending = nil
      defaultConfirmed = false
      return true
    } catch {
      if !isClosed {
        self.error =
          "\(defaultConfirmed ? "Defaults saved. " : "")Settings could not be confirmed. Retry the same save. \(error.localizedDescription)"
      }
      return false
    }
  }

  func useDefaults() async -> Bool {
    guard canSave, !hasPendingSave else { return false }
    pendingReset = true
    return await retry()
  }

  func reloadSavedSettings() async {
    guard !isSaving, !isLoading, !isClosed else { return }
    pending = nil
    pendingReset = false
    defaultConfirmed = false
    await load()
  }

  private func persistRemote(_ settings: EpubReaderSettings, asDefault: Bool, session: UUID)
    async throws
  {
    let expected = try dictionary(settings)
    let body = try JSONSerialization.data(withJSONObject: ["settings": expected])
    let path = asDefault ? "reader/defaults/epub" : "reader/preferences/\(fileID)"
    try await api.sendEmpty(path, method: "PUT", body: body, session: session)
    let acknowledged: [String: Any]
    if asDefault {
      let remote: EpubReaderDefaultsResponse = try await api.boundedJSON(
        "reader/defaults", session: session)
      guard let epub = remote.epub else { throw ConnectionError.invalidResponse }
      acknowledged = try partialDictionary(epub)
    } else {
      let remote: EpubReaderPreferenceResponse = try await api.boundedJSON(
        "reader/preferences/\(fileID)", session: session)
      guard remote.isCustomized, let settings = remote.settings else {
        throw ConnectionError.invalidResponse
      }
      acknowledged = try partialDictionary(settings)
    }
    guard NSDictionary(dictionary: expected).isEqual(to: acknowledged) else {
      throw ConnectionError.invalidResponse
    }
  }

  func close() {
    isClosed = true
    fonts.close()
    validateFont = nil
  }

  private func merged<Value: Encodable>(_ partial: Value?, over base: EpubReaderSettings) throws
    -> EpubReaderSettings
  {
    var values = try dictionary(base)
    if let partial { values.merge(try partialDictionary(partial)) { _, new in new } }
    return try JSONDecoder().decode(
      EpubReaderSettings.self, from: JSONSerialization.data(withJSONObject: values))
  }

  private func partialDictionary<Value: Encodable>(_ value: Value) throws -> [String: Any] {
    guard
      let values = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        as? [String: Any]
    else {
      throw ConnectionError.invalidResponse
    }
    return values
  }

  private func dictionary(_ value: EpubReaderSettings) throws -> [String: Any] {
    var values = try partialDictionary(value)
    for field in ["fontFamily", "letterSpacing", "wordSpacing", "textIndent"] {
      if values[field] == nil { values[field] = NSNull() }
    }
    return values
  }

  private func cached(_ key: String?) -> EPUBPreferencesValue? {
    guard let key, let data = UserDefaults.standard.data(forKey: key), data.count <= 16_384,
      let value = try? JSONDecoder().decode(EPUBPreferencesValue.self, from: data), value.isValid
    else { return nil }
    return value
  }

  private func store(_ value: EPUBPreferencesValue, at key: String?) throws {
    guard let key else { throw ConnectionError.invalidResponse }
    let data = try JSONEncoder().encode(value)
    guard data.count <= 16_384 else { throw ConnectionError.invalidResponse }
    UserDefaults.standard.set(data, forKey: key)
  }
}
