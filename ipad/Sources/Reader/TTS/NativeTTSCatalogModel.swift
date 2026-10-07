import Foundation
import Observation

@MainActor @Observable
final class NativeTTSCatalogModel {
  private(set) var providers: [TtsProviderInfo] = []
  private(set) var voices: [TtsVoice] = []
  private(set) var loadedProviderID: String?
  private(set) var isLoadingProviders = false
  private(set) var isLoadingVoices = false
  private(set) var error: String?
  private let api: BookOrbitAPI
  private var voiceGeneration = UUID()
  private var isClosed = false

  init(api: BookOrbitAPI) { self.api = api }

  func loadProviders() async {
    guard !isClosed, !isLoadingProviders else { return }
    isLoadingProviders = true
    error = nil
    defer { isLoadingProviders = false }
    do {
      let session = try await api.authenticatedSessionGeneration()
      let value: [TtsProviderInfo] = try await api.boundedJSON(
        "tts/providers", byteLimit: 256 * 1024, session: session)
      try await checkSession(session)
      guard value.count <= 512, Set(value.map(\.id)).count == value.count,
        value.allSatisfy({
          !$0.id.isEmpty && $0.id.utf8.count <= 64 && !$0.name.isEmpty
            && $0.name.utf8.count <= 512 && $0.type == "openai-compatible"
        })
      else { throw ConnectionError.invalidResponse }
      providers = value
    } catch is CancellationError {
    } catch { if !isClosed { self.error = error.localizedDescription } }
  }

  func loadVoices(providerID: String) async {
    guard !isClosed else { return }
    let request = UUID()
    voiceGeneration = request
    isLoadingVoices = true
    loadedProviderID = nil
    voices = []
    error = nil
    defer { if request == voiceGeneration { isLoadingVoices = false } }
    do {
      guard providers.contains(where: { $0.id == providerID }) else {
        throw NativeTTSError.unavailableServerVoice
      }
      let session = try await api.authenticatedSessionGeneration()
      let value: [TtsVoice] = try await api.boundedJSON(
        "tts/voices", query: [URLQueryItem(name: "providerId", value: providerID)],
        byteLimit: 4 * 1024 * 1024, session: session)
      try await checkSession(session)
      guard request == voiceGeneration else { return }
      guard value.count <= 10000, Set(value.map(\.id)).count == value.count,
        value.allSatisfy({
          $0.providerId == providerID && !$0.id.isEmpty && $0.id.utf8.count <= 512
            && !$0.name.isEmpty && $0.name.utf8.count <= 512 && $0.language.utf8.count <= 128
            && $0.locale.utf8.count <= 128
        })
      else { throw ConnectionError.invalidResponse }
      voices = value.sorted { ($0.language, $0.name, $0.id) < ($1.language, $1.name, $1.id) }
      loadedProviderID = providerID
    } catch is CancellationError {
    } catch {
      if request == voiceGeneration, !isClosed { self.error = error.localizedDescription }
    }
  }

  func contains(providerID: String, voiceID: String) -> Bool {
    loadedProviderID == providerID && voices.contains(where: { $0.id == voiceID })
  }

  func close() {
    isClosed = true
    voiceGeneration = UUID()
  }

  private func checkSession(_ session: UUID) async throws {
    try Task.checkCancellation()
    let active = try await api.authenticatedSessionGeneration()
    try Task.checkCancellation()
    guard !isClosed, active == session else {
      throw ConnectionError.expiredSession
    }
  }
}
