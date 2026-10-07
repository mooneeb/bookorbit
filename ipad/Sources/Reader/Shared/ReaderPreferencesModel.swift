import Foundation
import Observation

enum ReaderTurnAnimation: String, Codable, CaseIterable, Identifiable {
  case curl, horizontalSlide, verticalSlide, fade, none
  var id: String { rawValue }
  var label: String {
    switch self {
    case .curl: "Page curl"
    case .horizontalSlide: "Horizontal slide"
    case .verticalSlide: "Vertical slide"
    case .fade: "Fade"
    case .none: "No animation"
    }
  }
}

struct ReaderPreferencesValue: Codable, Equatable {
  var pdf = PdfReaderSettings.readerDefault
  var comic = CbxReaderSettings.readerDefault
  var pageAnimation = ReaderTurnAnimation.curl

  var isValid: Bool {
    ["fit-page", "fit-width", "automatic", "custom"].contains(pdf.zoomMode)
      && pdf.customScale.isFinite && (0.25...4).contains(pdf.customScale)
      && [0, 90, 180, 270].contains(pdf.rotation)
      && ["page", "vertical", "horizontal"].contains(pdf.scrollMode)
      && ["none", "odd", "even", "auto"].contains(pdf.spread)
      && ["fit-page", "fit-width", "fit-height", "actual"].contains(comic.fitMode)
      && ["black", "gray", "white"].contains(comic.bgColor)
      && ["single", "two-page"].contains(comic.viewMode)
      && ["paginated", "infinite", "long-strip"].contains(comic.scrollMode)
      && ["ltr", "rtl"].contains(comic.direction)
      && ["normal", "shifted"].contains(comic.spreadAlignment)
      && ["auto", "disable"].contains(comic.widePageSingletonMode)
      && (ReaderLayoutBounds.spreadGapMinimum...ReaderLayoutBounds.spreadGapMaximum).contains(
        comic.spreadGap)
  }
}

@MainActor @Observable
final class ReaderPreferencesModel {
  let api: BookOrbitAPI
  let fileID: Int
  let group: String
  private(set) var value = ReaderPreferencesValue()
  private(set) var defaults = ReaderPreferencesValue()
  private(set) var isCustomized = false
  private(set) var isLoading = false
  private(set) var hasLoaded = false
  private(set) var isSaving = false
  private(set) var syncLook = false
  private(set) var canSync = false
  var error: String?
  private var storageKey: String?
  private var isClosed = false

  init(api: BookOrbitAPI, fileID: Int, group: String) {
    self.api = api
    self.fileID = fileID
    self.group = group
  }

  func load() async {
    guard !isLoading, !isSaving, !isClosed else { return }
    isLoading = true
    hasLoaded = false
    error = nil
    defer { isLoading = false }
    do {
      let namespace = try await api.storageNamespace()
      guard !isClosed else { return }
      storageKey = "bookorbit.reader-preferences.\(namespace).\(group)"
      defaults = localValue(defaultKey) ?? ReaderPreferencesValue()
      let localBook = localValue(bookKey)
      value = localBook ?? defaults
      isCustomized = localBook != nil
      let user: UserReaderSettingsResponse = try await api.send("auth/me")
      guard !isClosed else { return }
      syncLook = user.settings.syncReaderPreferences == true
      canSync = !user.permissions.contains(Permission.demoRestricted.rawValue)
      if syncLook {
        let server: FixedReaderDefaultsResponse = try await api.send("reader/defaults")
        guard !isClosed else { return }
        try applyServerDefaults(server)
        var resolved = localBook ?? defaults
        if group == "pdf" {
          let response: PdfReaderPreferenceResponse = try await api.send(
            "reader/preferences/\(fileID)")
          guard !isClosed else { return }
          resolved.pdf = defaults.pdf
          if let patch = response.settings {
            resolved.pdf.zoomMode = patch.zoomMode ?? resolved.pdf.zoomMode
            resolved.pdf.customScale = patch.customScale ?? resolved.pdf.customScale
            resolved.pdf.rotation = patch.rotation ?? resolved.pdf.rotation
            resolved.pdf.scrollMode = patch.scrollMode ?? resolved.pdf.scrollMode
            resolved.pdf.spread = patch.spread ?? resolved.pdf.spread
          }
          isCustomized = isCustomized || response.isCustomized
        } else {
          let response: CbxReaderPreferenceResponse = try await api.send(
            "reader/preferences/\(fileID)")
          guard !isClosed else { return }
          resolved.comic = defaults.comic
          if let patch = response.settings {
            resolved.comic.fitMode = patch.fitMode ?? resolved.comic.fitMode
            resolved.comic.bgColor = patch.bgColor ?? resolved.comic.bgColor
            resolved.comic.viewMode = patch.viewMode ?? resolved.comic.viewMode
            resolved.comic.scrollMode = patch.scrollMode ?? resolved.comic.scrollMode
            resolved.comic.direction = patch.direction ?? resolved.comic.direction
            resolved.comic.spreadAlignment = patch.spreadAlignment ?? resolved.comic.spreadAlignment
            resolved.comic.spreadGap = patch.spreadGap ?? resolved.comic.spreadGap
            resolved.comic.forceTwoPage = patch.forceTwoPage ?? resolved.comic.forceTwoPage
            resolved.comic.widePageSingletonMode =
              patch.widePageSingletonMode ?? resolved.comic.widePageSingletonMode
            resolved.comic.autoAdvance = patch.autoAdvance ?? resolved.comic.autoAdvance
          }
          isCustomized = isCustomized || response.isCustomized
        }
        guard resolved.isValid else { throw ConnectionError.invalidResponse }
        value = resolved
      }
      guard value.isValid else { throw ConnectionError.invalidResponse }
      hasLoaded = true
    } catch is CancellationError {
    } catch { if !isClosed { self.error = error.localizedDescription } }
  }

  func save(_ draft: ReaderPreferencesValue, asDefault: Bool) async -> Bool {
    guard draft.isValid, hasLoaded, storageKey != nil, !isSaving, !isLoading, !isClosed else {
      return false
    }
    guard !syncLook || canSync else {
      error = "This account cannot change synchronized reader settings."
      return false
    }
    isSaving = true
    error = nil
    var savedDefaults = false
    defer { isSaving = false }
    do {
      if asDefault {
        if syncLook { try await saveLook(draft, asDefault: true) }
        guard !isClosed else { return false }
        try persist(draft, key: defaultKey)
        defaults = draft
        savedDefaults = true
      }
      if syncLook { try await saveLook(draft, asDefault: false) }
      guard !isClosed else { return false }
      try persist(draft, key: bookKey)
      value = draft
      isCustomized = true
      return true
    } catch {
      if !isClosed {
        self.error =
          savedDefaults
          ? "Defaults saved. This book could not be updated. Your draft is kept. \(error.localizedDescription)"
          : error.localizedDescription
      }
      return false
    }
  }

  func useDefaults() async -> Bool {
    guard hasLoaded, storageKey != nil, !isSaving, !isLoading, !isClosed else { return false }
    guard !syncLook || canSync else {
      error = "This account cannot change synchronized reader settings."
      return false
    }
    isSaving = true
    error = nil
    defer { isSaving = false }
    do {
      if syncLook {
        let server: FixedReaderDefaultsResponse = try await api.send("reader/defaults")
        guard !isClosed else { return false }
        try applyServerDefaults(server)
        let body =
          group == "pdf"
          ? try JSONEncoder().encode(
            PdfReaderPreferencePatchBody(unset: [
              "zoomMode", "customScale", "rotation", "scrollMode", "spread",
            ]))
          : try JSONEncoder().encode(
            CbxReaderPreferencePatchBody(unset: [
              "fitMode", "bgColor", "viewMode", "scrollMode", "direction", "spreadAlignment",
              "spreadGap", "forceTwoPage", "widePageSingletonMode", "autoAdvance",
            ]))
        try await api.sendEmpty("reader/preferences/\(fileID)", method: "PATCH", body: body)
      }
      guard !isClosed else { return false }
      UserDefaults.standard.removeObject(forKey: bookKey)
      value = defaults
      isCustomized = false
      return true
    } catch {
      if !isClosed { self.error = error.localizedDescription }
      return false
    }
  }

  func close() { isClosed = true }

  private var defaultKey: String { "\(storageKey ?? "").defaults" }
  private var bookKey: String { "\(storageKey ?? "").file.\(fileID)" }

  private func localValue(_ key: String) -> ReaderPreferencesValue? {
    guard let data = UserDefaults.standard.data(forKey: key), data.count <= 16 * 1024,
      let value = try? JSONDecoder().decode(ReaderPreferencesValue.self, from: data), value.isValid
    else { return nil }
    return value
  }

  private func persist(_ value: ReaderPreferencesValue, key: String) throws {
    let data = try JSONEncoder().encode(value)
    guard data.count <= 16 * 1024 else { throw ConnectionError.invalidResponse }
    UserDefaults.standard.set(data, forKey: key)
  }

  private func applyServerDefaults(_ server: FixedReaderDefaultsResponse) throws {
    var resolved = defaults
    if let pdf = server.pdf {
      resolved.pdf.zoomMode = pdf.zoomMode ?? resolved.pdf.zoomMode
      resolved.pdf.customScale = pdf.customScale ?? resolved.pdf.customScale
      resolved.pdf.rotation = pdf.rotation ?? resolved.pdf.rotation
      resolved.pdf.scrollMode = pdf.scrollMode ?? resolved.pdf.scrollMode
      resolved.pdf.spread = pdf.spread ?? resolved.pdf.spread
    }
    if let comic = server.cbx {
      resolved.comic.fitMode = comic.fitMode ?? resolved.comic.fitMode
      resolved.comic.bgColor = comic.bgColor ?? resolved.comic.bgColor
      resolved.comic.viewMode = comic.viewMode ?? resolved.comic.viewMode
      resolved.comic.scrollMode = comic.scrollMode ?? resolved.comic.scrollMode
      resolved.comic.direction = comic.direction ?? resolved.comic.direction
      resolved.comic.spreadAlignment = comic.spreadAlignment ?? resolved.comic.spreadAlignment
      resolved.comic.spreadGap = comic.spreadGap ?? resolved.comic.spreadGap
      resolved.comic.forceTwoPage = comic.forceTwoPage ?? resolved.comic.forceTwoPage
      resolved.comic.widePageSingletonMode =
        comic.widePageSingletonMode ?? resolved.comic.widePageSingletonMode
      resolved.comic.autoAdvance = comic.autoAdvance ?? resolved.comic.autoAdvance
    }
    guard resolved.isValid else { throw ConnectionError.invalidResponse }
    defaults = resolved
  }

  private func saveLook(_ draft: ReaderPreferencesValue, asDefault: Bool) async throws {
    let original = asDefault ? defaults : value
    if group == "pdf" {
      let zoom = draft.pdf.zoomMode == original.pdf.zoomMode ? nil : draft.pdf.zoomMode
      let scale = draft.pdf.customScale == original.pdf.customScale ? nil : draft.pdf.customScale
      let rotation = draft.pdf.rotation == original.pdf.rotation ? nil : draft.pdf.rotation
      let scroll = draft.pdf.scrollMode == original.pdf.scrollMode ? nil : draft.pdf.scrollMode
      let spread = draft.pdf.spread == original.pdf.spread ? nil : draft.pdf.spread
      guard zoom != nil || scale != nil || rotation != nil || scroll != nil || spread != nil else {
        return
      }
      let body =
        asDefault
        ? try JSONEncoder().encode(
          PdfReaderDefaultsPatchBody(
            set: .init(
              scrollMode: scroll, spread: spread, zoomMode: zoom, customScale: scale,
              rotation: rotation)))
        : try JSONEncoder().encode(
          PdfReaderPreferencePatchBody(
            set: .init(
              scrollMode: scroll, spread: spread, zoomMode: zoom, customScale: scale,
              rotation: rotation)))
      try await api.sendEmpty(
        asDefault ? "reader/defaults/pdf" : "reader/preferences/\(fileID)",
        method: "PATCH", body: body)
    } else {
      let fit = draft.comic.fitMode == original.comic.fitMode ? nil : draft.comic.fitMode
      let background = draft.comic.bgColor == original.comic.bgColor ? nil : draft.comic.bgColor
      let view = draft.comic.viewMode == original.comic.viewMode ? nil : draft.comic.viewMode
      let scroll =
        draft.comic.scrollMode == original.comic.scrollMode ? nil : draft.comic.scrollMode
      let direction =
        draft.comic.direction == original.comic.direction ? nil : draft.comic.direction
      let alignment =
        draft.comic.spreadAlignment == original.comic.spreadAlignment
        ? nil : draft.comic.spreadAlignment
      let gap = draft.comic.spreadGap == original.comic.spreadGap ? nil : draft.comic.spreadGap
      let force =
        draft.comic.forceTwoPage == original.comic.forceTwoPage ? nil : draft.comic.forceTwoPage
      let wide =
        draft.comic.widePageSingletonMode == original.comic.widePageSingletonMode
        ? nil : draft.comic.widePageSingletonMode
      let advance =
        draft.comic.autoAdvance == original.comic.autoAdvance ? nil : draft.comic.autoAdvance
      guard
        fit != nil || background != nil || view != nil || scroll != nil || direction != nil
          || alignment != nil || gap != nil || force != nil || wide != nil || advance != nil
      else { return }
      let body =
        asDefault
        ? try JSONEncoder().encode(
          CbxReaderDefaultsPatchBody(
            set: .init(
              fitMode: fit, viewMode: view, scrollMode: scroll, direction: direction,
              spreadAlignment: alignment, spreadGap: gap, forceTwoPage: force,
              widePageSingletonMode: wide, bgColor: background,
              autoAdvance: advance))
        )
        : try JSONEncoder().encode(
          CbxReaderPreferencePatchBody(
            set: .init(
              fitMode: fit, viewMode: view, scrollMode: scroll, direction: direction,
              spreadAlignment: alignment, spreadGap: gap, forceTwoPage: force,
              widePageSingletonMode: wide, bgColor: background,
              autoAdvance: advance))
        )
      try await api.sendEmpty(
        asDefault ? "reader/defaults/cbx" : "reader/preferences/\(fileID)",
        method: "PATCH", body: body)
    }
  }
}
