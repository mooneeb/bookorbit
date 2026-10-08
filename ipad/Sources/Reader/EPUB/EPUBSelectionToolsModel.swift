import AVFoundation
import Foundation
import Observation
import UIKit

struct EPUBSelectedPassage: Equatable {
  let publicationID: UUID
  let cfi: String
  let text: String
  let language: String
}

enum EPUBSelectionTool: Equatable {
  case dictionary, translation
}

struct EPUBSelectionToolPresentation: Identifiable {
  let id = UUID()
  let tool: EPUBSelectionTool
  let passage: EPUBSelectedPassage
}

@MainActor @Observable
final class EPUBSelectionToolsModel {
  var presentation: EPUBSelectionToolPresentation?
  private(set) var dictionary: DictionaryResult?
  private(set) var translation: TranslationResult?
  private(set) var isLoading = false
  private(set) var notFound = false
  private(set) var error: String?
  private(set) var pronunciationError: String?
  private(set) var isPronouncing = false
  private(set) var isLoadingPronunciation = false
  private(set) var copied = false
  private(set) var targetLanguage: String
  @ObservationIgnored var pronunciationAllowed: (@MainActor () -> Bool)?
  private weak var reader: EPUBReaderModel?
  private let transport: EPUBLanguageToolTransport
  private let dictionaryService: EPUBDictionaryService
  private let translationService: EPUBTranslationService
  private var request: Task<Void, Never>?
  private var monitor: Task<Void, Never>?
  private var pronunciationTask: Task<Void, Never>?
  private var player: AVAudioPlayer?
  private var operationID = UUID()
  private var sessionID: UUID?
  private let targetKey: String

  init(reader: EPUBReaderModel) {
    self.reader = reader
    let transport = EPUBLanguageToolTransport()
    self.transport = transport
    dictionaryService = EPUBDictionaryService(transport: transport)
    translationService = EPUBTranslationService(transport: transport)
    targetKey = "bookorbit.translation_target_lang.\(reader.api.profile.url.absoluteString)"
    let stored = UserDefaults.standard.string(forKey: targetKey)
    targetLanguage = NativeTranslationVocabulary.languages.first { $0.code == stored }?.code ?? "en"
  }

  var canPronounce: Bool {
    dictionary?.audioUrl != nil && !isLoading && pronunciationAllowed?() == true
  }

  func open(_ tool: EPUBSelectionTool, passage: EPUBSelectedPassage) {
    dismiss()
    presentation = .init(tool: tool, passage: passage)
    start()
  }

  func retry() { start() }

  func setTargetLanguage(_ code: String) {
    guard NativeTranslationVocabulary.languages.contains(where: { $0.code == code }),
      code != targetLanguage
    else { return }
    targetLanguage = code
    UserDefaults.standard.set(code, forKey: targetKey)
    if presentation?.tool == .translation { start() }
  }

  func dismiss() {
    operationID = UUID()
    request?.cancel()
    request = nil
    monitor?.cancel()
    monitor = nil
    stopPronunciation()
    presentation = nil
    sessionID = nil
    dictionary = nil
    translation = nil
    error = nil
    pronunciationError = nil
    notFound = false
    isLoading = false
    copied = false
  }

  func detach() {
    dismiss()
    Task { await translationService.clearToken() }
  }

  func copyTranslation() {
    guard let text = translation?.translatedText, !text.isEmpty, presentation != nil else { return }
    let expected = operationID
    Task {
      guard let sessionID, await isCurrent(expected, session: sessionID) else { return }
      UIPasteboard.general.string = text
      copied = true
    }
  }

  func playPronunciation() {
    if isPronouncing || isLoadingPronunciation {
      stopPronunciation()
      return
    }
    guard canPronounce, let raw = dictionary?.audioUrl,
      let url = URL(string: raw), url.scheme == "https",
      url.host == "api.dictionaryapi.dev", url.user == nil, url.password == nil
    else {
      pronunciationError = "Pronunciation is unavailable."
      return
    }
    let expected = operationID
    pronunciationError = nil
    isLoadingPronunciation = true
    pronunciationTask = Task {
      defer { if expected == operationID { isLoadingPronunciation = false } }
      do {
        guard let sessionID, await isCurrent(expected, session: sessionID), canPronounce else {
          throw CancellationError()
        }
        let (data, status) = try await transport.bytes(URLRequest(url: url), limit: 2 * 1024 * 1024)
        try Task.checkCancellation()
        guard await isCurrent(expected, session: sessionID), canPronounce else {
          throw CancellationError()
        }
        guard status == 200 else { throw EPUBLanguageToolError.status(status) }
        let audio = try AVAudioPlayer(data: data)
        guard audio.duration.isFinite, audio.duration > 0, audio.duration <= 30,
          audio.prepareToPlay(), audio.play()
        else { throw EPUBLanguageToolError.invalidResponse }
        player = audio
        isPronouncing = true
        while audio.isPlaying {
          try await Task.sleep(for: .milliseconds(100))
          guard await isCurrent(expected, session: sessionID), pronunciationAllowed?() == true
          else {
            throw CancellationError()
          }
        }
        if expected == operationID { stopPronunciation() }
      } catch {
        if expected == operationID {
          stopPronunciation()
          if !(error is CancellationError), !Task.isCancelled {
            pronunciationError = "Pronunciation failed. Check your connection and try again."
          }
        }
      }
    }
  }

  func stopPronunciation() {
    pronunciationTask?.cancel()
    pronunciationTask = nil
    player?.stop()
    player = nil
    isPronouncing = false
    isLoadingPronunciation = false
  }

  private func start() {
    request?.cancel()
    monitor?.cancel()
    stopPronunciation()
    operationID = UUID()
    let expected = operationID
    dictionary = nil
    translation = nil
    notFound = false
    error = nil
    pronunciationError = nil
    copied = false
    isLoading = false
    guard let presentation, let reader, reader.isReady,
      reader.publicationID == presentation.passage.publicationID
    else {
      dismiss()
      return
    }
    let text = EPUBLanguageToolTransport.trim(presentation.passage.text)
    guard !text.isEmpty else {
      error = presentation.tool == .translation ? "Nothing to translate." : "Nothing to define."
      return
    }
    if presentation.tool == .translation
      && text.utf16.count > NativeTranslationVocabulary.characterLimit
    {
      error =
        "Selection is too long. Select \(NativeTranslationVocabulary.characterLimit) characters or fewer."
      return
    }
    isLoading = true
    let target = targetLanguage
    request = Task {
      defer { if expected == operationID { isLoading = false } }
      do {
        let session = try await reader.api.authenticatedSessionGeneration()
        guard await isCurrent(expected, session: session) else { return }
        sessionID = session
        startMonitor(expected, session: session)
        switch presentation.tool {
        case .dictionary:
          let result = try await dictionaryService.lookup(
            text, language: presentation.passage.language)
          guard await isCurrent(expected, session: session) else { return }
          dictionary = result
          notFound = result == nil
        case .translation:
          let result = try await translationService.translate(text, target: target)
          guard await isCurrent(expected, session: session) else { return }
          translation = result
        }
      } catch {
        guard expected == operationID, !Task.isCancelled else { return }
        if let sessionID, !(await isCurrent(expected, session: sessionID)) { return }
        self.error =
          presentation.tool == .translation
          ? "Translation failed. Check your connection and try again."
          : "Definitions could not be loaded. Check your connection and try again."
      }
    }
  }

  private func startMonitor(_ expected: UUID, session: UUID) {
    monitor = Task {
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        guard await isCurrent(expected, session: session) else {
          if expected == operationID { detach() }
          return
        }
      }
    }
  }

  private func isCurrent(_ expected: UUID, session: UUID) async -> Bool {
    guard expected == operationID, !Task.isCancelled, let presentation, let reader,
      reader.isReady, reader.publicationID == presentation.passage.publicationID,
      let active = try? await reader.api.authenticatedSessionGeneration(), active == session
    else { return false }
    return expected == operationID && reader.isReady
      && reader.publicationID == presentation.passage.publicationID
  }
}
