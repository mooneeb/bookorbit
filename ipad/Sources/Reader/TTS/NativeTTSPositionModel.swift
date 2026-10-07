import CryptoKit
import Foundation
import Observation

@MainActor @Observable
final class NativeTTSPositionModel {
  private struct Journal: Codable {
    let position: TtsPosition
    let pending: Bool
  }

  let api: BookOrbitAPI
  let fileID: Int
  private(set) var savedPosition: TtsPosition?
  private(set) var hasLoaded = false
  private(set) var isLoading = false
  private(set) var isSaving = false
  private(set) var hasPendingSave = false
  private(set) var permissionBlocked = false
  private(set) var message: String?
  private var session: UUID?
  private var storageKey: String?
  private var journalURL: URL?
  private var acknowledged: TtsPosition?
  private var isClosed = false

  init(api: BookOrbitAPI, fileID: Int) {
    self.api = api
    self.fileID = fileID
  }

  func load() async {
    guard !isLoading, !isSaving, !isClosed else { return }
    isLoading = true
    hasLoaded = false
    message = nil
    defer { isLoading = false }
    do {
      let generation = try await api.authenticatedSessionGeneration()
      session = generation
      let namespace = try await api.storageNamespace()
      try await checkSession()
      storageKey = "bookorbit.native-tts-position.\(namespace).file.\(fileID)"
      let directory = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true
      ).appendingPathComponent("NativeSpeechPositions", isDirectory: true)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
      let key = SHA256.hash(data: Data((storageKey ?? "").utf8))
        .map { String(format: "%02x", $0) }.joined()
      journalURL = directory.appendingPathComponent("\(key).json")
      let remote: TtsPosition? = try await api.boundedJSON(
        "tts/position/\(fileID)", byteLimit: 16 * 1024, session: generation)
      try await checkSession()
      guard remote.map(Self.validPosition) != false else { throw ConnectionError.invalidResponse }
      acknowledged = remote
      permissionBlocked = false
      if let journal = localJournal(), journal.pending {
        savedPosition = journal.position
        hasPendingSave = journal.position != remote
      } else {
        savedPosition = remote
        hasPendingSave = false
      }
      try persistJournal()
      hasLoaded = true
    } catch is CancellationError {
    } catch { if !isClosed { message = error.localizedDescription } }
  }

  func record(_ position: TtsPosition) async throws {
    guard hasLoaded, !isClosed, Self.validPosition(position), Self.validCFI(position.cfi) else {
      throw ConnectionError.invalidResponse
    }
    try await checkSession()
    savedPosition = position
    hasPendingSave = acknowledged != position
    try persistJournal()
  }

  @discardableResult
  func flush() async -> Bool {
    guard hasLoaded, !isClosed else { return false }
    guard !isSaving else { return false }
    guard let savedPosition, hasPendingSave else { return true }
    isSaving = true
    message = nil
    defer { isSaving = false }
    do {
      try await checkSession()
      let response: TtsPosition = try await api.boundedJSON(
        "tts/position/\(fileID)", method: "PUT", body: JSONEncoder().encode(savedPosition),
        byteLimit: 16 * 1024, session: session)
      try await checkSession()
      guard response == savedPosition else { throw ConnectionError.invalidResponse }
      acknowledged = response
      permissionBlocked = false
      hasPendingSave = self.savedPosition != response
      try persistJournal()
      return !hasPendingSave
    } catch {
      if !isClosed {
        if let connection = error as? ConnectionError {
          switch connection {
          case .denied, .expiredSession: permissionBlocked = true
          default: break
          }
        }
        message = "Speech position is kept on this iPad. Sync failed. \(error.localizedDescription)"
      }
      return false
    }
  }

  func checkSession() async throws {
    try Task.checkCancellation()
    guard !isClosed, let session, try await api.authenticatedSessionGeneration() == session else {
      throw ConnectionError.expiredSession
    }
  }

  func close() { isClosed = true }

  nonisolated static func validCFI(_ cfi: String) -> Bool {
    cfi.hasPrefix("epubcfi(") && cfi.hasSuffix(")") && cfi.utf8.count <= 8192
      && !cfi.contains(where: { $0.isNewline || $0 == "\0" })
  }

  nonisolated static func validPosition(_ value: TtsPosition) -> Bool {
    (validCFI(value.cfi) || validLegacyMarker(value.cfi))
      && value.chapterIndex.map { $0 >= 0 } != false
  }

  private nonisolated static func validLegacyMarker(_ value: String) -> Bool {
    let parts = value.split(separator: ":", omittingEmptySubsequences: false)
    return parts.count == 3 && parts[0] == "tts" && value.utf8.count <= 64
      && parts.dropFirst().allSatisfy {
        !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber }
          && Int($0).map { $0 >= 0 && $0 <= 9_007_199_254_740_991 } == true
      }
  }

  private func localJournal() -> Journal? {
    let stored: Data?
    if let journalURL,
      let size = try? journalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size <= 16 * 1024
    {
      stored = try? Data(contentsOf: journalURL)
    } else if let storageKey {
      stored = UserDefaults.standard.data(forKey: storageKey)
    } else {
      stored = nil
    }
    guard let data = stored,
      data.count <= 16 * 1024, let value = try? JSONDecoder().decode(Journal.self, from: data),
      Self.validPosition(value.position)
    else { return nil }
    return value
  }

  private func persistJournal() throws {
    guard let journalURL, let storageKey else { throw ConnectionError.invalidResponse }
    if let savedPosition {
      let data = try JSONEncoder().encode(Journal(position: savedPosition, pending: hasPendingSave))
      guard data.count <= 16 * 1024 else { throw ConnectionError.invalidResponse }
      try data.write(
        to: journalURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      UserDefaults.standard.removeObject(forKey: storageKey)
    } else {
      if FileManager.default.fileExists(atPath: journalURL.path) {
        try FileManager.default.removeItem(at: journalURL)
      }
      UserDefaults.standard.removeObject(forKey: storageKey)
    }
  }
}
