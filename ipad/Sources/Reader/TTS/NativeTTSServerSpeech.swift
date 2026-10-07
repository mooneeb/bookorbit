import Foundation
import Observation

enum NativeTTSServerEvent: Sendable {
  case word(NSRange)
  case finished, failed
}

@MainActor @Observable
final class NativeTTSServerSpeech {
  private(set) var isPreviewing = false
  private(set) var isLoadingPreview = false
  private(set) var error: String?
  private(set) var hasWordTimings = false
  private let api: BookOrbitAPI
  @ObservationIgnored private let audio = NativeTTSAudioController()
  @ObservationIgnored private var clock: Task<Void, Never>?
  @ObservationIgnored private var preview: Task<Void, Never>?
  @ObservationIgnored private var receive: (@Sendable (NativeTTSServerEvent) -> Void)?
  private var generation = UUID()
  private var session: UUID?
  private var lastRange: NSRange?
  private var isClosed = false

  init(api: BookOrbitAPI) { self.api = api }

  var isPrepared: Bool { audio.isPrepared && !isPreviewing && !isLoadingPreview }

  func prepare(
    chunk: EPUBSpeechChunk, providerID: String, voiceID: String, speed: Double,
    receive: @escaping @Sendable (NativeTTSServerEvent) -> Void
  ) async throws {
    stop()
    let request = generation
    let session = try await api.authenticatedSessionGeneration()
    self.session = session
    let body = try JSONEncoder().encode(
      TtsSynthesisRequest(
        text: chunk.text, voiceId: voiceID, providerId: providerID, speed: speed, format: "mp3"))
    let speech: TtsCaptionedSpeech = try await api.boundedJSON(
      "tts/synthesize/captioned", method: "POST", body: body,
      byteLimit: 12 * 1024 * 1024, session: session)
    try await checkSession(session, generation: request)
    guard speech.format == "mp3", speech.audio.utf8.count <= 12 * 1024 * 1024,
      let data = Data(base64Encoded: speech.audio), !data.isEmpty
    else { throw ConnectionError.invalidResponse }
    self.receive = receive
    try audio.prepare(audio: data, words: speech.words, text: chunk.text) { [weak self] event in
      Task { @MainActor in self?.completed(event, generation: request) }
    }
    hasWordTimings = audio.hasWordTimings
  }

  func play() async throws {
    guard let session, !isClosed else { throw ConnectionError.expiredSession }
    try await checkSession(session, generation: generation)
    try audio.play()
    startClock()
  }

  func pause() {
    audio.pause()
    clock?.cancel()
    clock = nil
  }

  func previewVoice(providerID: String, voiceID: String) async {
    guard !isClosed else { return }
    stop()
    error = nil
    isLoadingPreview = true
    let request = generation
    preview = Task { [weak self] in
      guard let self else { return }
      defer { if request == self.generation { self.isLoadingPreview = false } }
      do {
        let session = try await self.api.authenticatedSessionGeneration()
        self.session = session
        let body = try JSONEncoder().encode(
          TtsVoicePreviewRequest(providerId: providerID, voiceId: voiceID))
        let data = try await self.api.speechAudio("tts/preview", body: body, session: session)
        try await self.checkSession(session, generation: request)
        try self.audio.prepare(audio: data, words: [], text: "") { [weak self] event in
          Task { @MainActor in self?.completed(event, generation: request) }
        }
        try self.audio.play()
        self.isPreviewing = true
        self.startClock()
      } catch is CancellationError {
      } catch {
        if request == self.generation, !self.isClosed {
          self.error = error.localizedDescription
          self.stop()
        }
      }
    }
    await preview?.value
  }

  func stop() {
    generation = UUID()
    clock?.cancel()
    clock = nil
    preview?.cancel()
    preview = nil
    audio.stop()
    receive = nil
    lastRange = nil
    hasWordTimings = false
    isPreviewing = false
    isLoadingPreview = false
  }

  func close() {
    isClosed = true
    stop()
  }

  private func startClock() {
    clock?.cancel()
    let request = generation
    clock = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, let session = self.session else { return }
        do {
          try await self.checkSession(session, generation: request)
          if let range = self.audio.wordRange(at: self.audio.elapsed), range != self.lastRange {
            self.lastRange = range
            self.receive?(.word(range))
          }
          try await Task.sleep(for: .milliseconds(50))
        } catch is CancellationError { return } catch {
          guard request == self.generation, !self.isClosed else { return }
          let receive = self.receive
          self.error = error.localizedDescription
          self.stop()
          receive?(.failed)
          return
        }
      }
    }
  }

  private func completed(_ event: NativeTTSAudioEvent, generation request: UUID) {
    guard request == generation, !isClosed else { return }
    clock?.cancel()
    clock = nil
    if isPreviewing {
      if case .failed = event { error = NativeTTSError.serverAudioFailed.localizedDescription }
      stop()
    } else {
      switch event {
      case .finished: receive?(.finished)
      case .failed: receive?(.failed)
      }
    }
  }

  private func checkSession(_ session: UUID, generation request: UUID) async throws {
    try Task.checkCancellation()
    let active = try await api.authenticatedSessionGeneration()
    try Task.checkCancellation()
    guard !isClosed, request == generation, active == session
    else { throw ConnectionError.expiredSession }
  }
}
