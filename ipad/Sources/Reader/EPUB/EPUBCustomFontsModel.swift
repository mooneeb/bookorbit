import Foundation
import Observation

struct EPUBFontFamily: Identifiable {
  let name: String
  let scope: String
  let cssFamily: String
  let files: [UserFont]
  var id: String { "\(scope):\(name)" }

  var label: String { "\(name) (\(scope == "server" ? "Server" : "Personal"))" }
  var variants: [FontNamedInstance] {
    var result: [String: FontNamedInstance] = [:]
    for file in files {
      let offered =
        [FontNamedInstance(weight: file.weight, style: file.style, name: nil)]
        + (file.weightMin != nil ? file.instances ?? [] : [])
      for variant in offered {
        let key = "\(variant.weight):\(variant.style)"
        if result[key] == nil || result[key]?.name == nil { result[key] = variant }
      }
    }
    return result.values.sorted {
      $0.style == $1.style ? $0.weight < $1.weight : $0.style == "normal"
    }
  }

  func supports(_ file: UserFont, weight: Double, style: String) -> Bool {
    if let minimum = file.weightMin, let maximum = file.weightMax, maximum > minimum {
      return (minimum...maximum).contains(weight)
        && (file.style == style || file.instances?.contains(where: { $0.style == style }) == true)
    }
    return file.weight == weight && file.style == style
  }

  func renderingFiles(weight: Double, style: String) throws -> [UserFont] {
    guard let selected = files.first(where: { supports($0, weight: weight, style: style) }) else {
      throw EPUBFontError.unavailableVariant
    }
    var result = [selected]
    let emphasisWeight: Double = weight < 350 ? 400 : weight < 550 ? 700 : 900
    for variant in [
      (weight, "normal"), (emphasisWeight, "normal"), (weight, "italic"),
      (emphasisWeight, "italic"),
    ] {
      if let file = files.first(where: { supports($0, weight: variant.0, style: variant.1) }),
        !result.contains(where: { $0.id == file.id }), result.count < 4
      {
        result.append(file)
      }
    }
    return result
  }
}

enum EPUBFontError: LocalizedError {
  case unavailableFamily
  case ambiguousFamily
  case unavailableVariant
  case invalidFile
  case loadFailed
  case busy

  var errorDescription: String? {
    switch self {
    case .unavailableFamily:
      "The selected custom font is missing, hidden, or unavailable to this account. Choose another font."
    case .ambiguousFamily:
      "These font family names share the same reader identifier. Choose another family or rename them in font settings."
    case .unavailableVariant:
      "The selected font weight and style are unavailable in this family. Choose an offered variant."
    case .invalidFile: "The font file has an unsupported format, size, or response."
    case .loadFailed:
      "WebKit could not load this custom font. Choose another font or retry the catalog."
    case .busy: "The custom font resource queue is busy. Retry the selection."
    }
  }
}

@MainActor @Observable
final class EPUBCustomFontsModel {
  private let api: BookOrbitAPI
  private(set) var families: [EPUBFontFamily] = []
  private(set) var hiddenFamilies: [String] = []
  private(set) var hasLoaded = false
  private(set) var isLoading = false
  private(set) var isSaving = false
  private(set) var error: String?
  private var generation: UUID?
  private var isClosed = false
  private var pendingVisibility: [String]?
  var hasPendingSave: Bool { pendingVisibility != nil }
  var visibleFamilies: [EPUBFontFamily] {
    families.filter { $0.scope != "server" || !hiddenFamilies.contains($0.name) }
  }
  var serverFamilies: [EPUBFontFamily] { families.filter { $0.scope == "server" } }
  var selectableFamilies: [EPUBFontFamily] {
    visibleFamilies.filter { family in
      visibleFamilies.filter { $0.cssFamily == family.cssFamily }.count == 1
    }
  }

  init(api: BookOrbitAPI) { self.api = api }

  func load() async {
    guard !isLoading, !isSaving, !hasPendingSave, !isClosed else { return }
    isLoading = true
    error = nil
    defer { isLoading = false }
    do {
      let session = try await api.authenticatedSessionGeneration()
      async let user: [UserFont] = api.boundedJSON(
        "fonts", byteLimit: 1024 * 1024, session: session)
      async let server: [UserFont] = api.boundedJSON(
        "server-fonts", byteLimit: 4 * 1024 * 1024, session: session)
      async let visibility: ServerFontPreferencesResponse = api.boundedJSON(
        "user-preferences/server-fonts", byteLimit: 256 * 1024, session: session)
      let (personalFonts, serverFonts, preferences) = try await (user, server, visibility)
      try validate(personalFonts, maximum: ReaderFontVocabulary.userMaximum)
      try validate(serverFonts, maximum: ReaderFontVocabulary.serverMaximum)
      let hidden = preferences.settings?.hiddenFamilies ?? []
      try validateVisibility(hidden)
      guard !isClosed, try await api.authenticatedSessionGeneration() == session else {
        throw ConnectionError.expiredSession
      }
      families = group(personalFonts, scope: "user") + group(serverFonts, scope: "server")
      hiddenFamilies = hidden
      generation = session
      hasLoaded = true
    } catch {
      if !isClosed {
        families = []
        hasLoaded = false
        self.error = "Custom fonts could not be loaded. \(error.localizedDescription)"
      }
    }
  }

  func resolve(_ cssFamily: String?) throws -> EPUBFontFamily? {
    guard let cssFamily, Self.isCustom(cssFamily) else { return nil }
    guard hasLoaded else { throw EPUBFontError.unavailableFamily }
    let matching = visibleFamilies.filter { $0.cssFamily == cssFamily }
    guard matching.count <= 1 else { throw EPUBFontError.ambiguousFamily }
    guard let family = matching.first else { throw EPUBFontError.unavailableFamily }
    return family
  }

  func setHidden(_ family: EPUBFontFamily, hidden: Bool) async {
    guard family.scope == "server", hasLoaded, !isSaving, !isLoading, !hasPendingSave, !isClosed
    else { return }
    var next = hiddenFamilies.filter { $0 != family.name }
    if hidden { next.append(family.name) }
    pendingVisibility = next
    await retryVisibility()
  }

  func retryVisibility() async {
    guard let requested = pendingVisibility, let generation, !isSaving, !isClosed else { return }
    isSaving = true
    error = nil
    defer { isSaving = false }
    do {
      try validateVisibility(requested)
      let body = ServerFontPreferencesBody(
        settings: ServerFontPreferences(hiddenFamilies: requested))
      try await api.sendEmpty(
        "user-preferences/server-fonts", method: "PUT", body: JSONEncoder().encode(body),
        session: generation)
      let confirmed: ServerFontPreferencesResponse = try await api.boundedJSON(
        "user-preferences/server-fonts", byteLimit: 256 * 1024, session: generation)
      guard !isClosed, Set(confirmed.settings?.hiddenFamilies ?? []) == Set(requested),
        try await api.authenticatedSessionGeneration() == generation
      else { throw ConnectionError.invalidResponse }
      hiddenFamilies = requested
      pendingVisibility = nil
    } catch {
      if !isClosed {
        self.error =
          "Font visibility could not be confirmed. Retry the same change. \(error.localizedDescription)"
      }
    }
  }

  func close() { isClosed = true }

  nonisolated static func isCustom(_ family: String?) -> Bool {
    guard let family else { return false }
    return ReaderFontVocabulary.prefixes.values.contains { family.hasPrefix($0) }
  }

  private func group(_ fonts: [UserFont], scope: String) -> [EPUBFontFamily] {
    Dictionary(grouping: fonts, by: \.familyName).map { name, files in
      return EPUBFontFamily(
        name: name, scope: scope,
        cssFamily: ReaderFontVocabulary.familyGroupName(name, scope: scope),
        files: files.sorted { $0.id < $1.id })
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  private func validateVisibility(_ names: [String]) throws {
    guard names.count <= ReaderFontVocabulary.serverMaximum,
      Set(names).count == names.count,
      names.allSatisfy({ !$0.isEmpty && $0.utf16.count <= ReaderFontVocabulary.familyNameMaximum })
    else { throw ConnectionError.invalidResponse }
  }

  private func validate(_ fonts: [UserFont], maximum: Int) throws {
    guard fonts.count <= maximum, Set(fonts.map(\.id)).count == fonts.count else {
      throw ConnectionError.invalidResponse
    }
    for font in fonts {
      guard font.id > 0, !font.familyName.isEmpty,
        font.familyName.utf16.count <= ReaderFontVocabulary.familyNameMaximum,
        font.originalFileName.utf16.count <= 1024, font.createdAt.utf16.count <= 100,
        ReaderFontVocabulary.mimeTypes[font.format] != nil,
        (1...ReaderFontVocabulary.fileMaximum).contains(font.fileSize),
        validWeight(font.weight), ["normal", "italic"].contains(font.style),
        (font.weightMin == nil) == (font.weightMax == nil),
        (font.instances?.count ?? 0) <= 1024
      else { throw EPUBFontError.invalidFile }
      if let minimum = font.weightMin, let maximum = font.weightMax {
        guard validWeight(minimum), validWeight(maximum), minimum < maximum,
          (minimum...maximum).contains(font.weight)
        else { throw EPUBFontError.invalidFile }
      }
      for instance in font.instances ?? [] {
        guard validWeight(instance.weight), ["normal", "italic"].contains(instance.style),
          instance.name.map({ $0.utf16.count <= 200 }) ?? true,
          font.weightMin.map({ instance.weight >= $0 }) ?? false,
          font.weightMax.map({ instance.weight <= $0 }) ?? false
        else { throw EPUBFontError.invalidFile }
      }
    }
  }

  private func validWeight(_ weight: Double) -> Bool {
    weight.isFinite && weight.rounded() == weight && (1...1000).contains(weight)
  }
}
