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
  let conflict = ReaderPositionConflictState()
  private(set) var savedPosition: TtsPosition?
  private(set) var hasLoaded = false
  private(set) var isLoading = false
  private(set) var isSaving = false
  private(set) var isResolving = false
  private(set) var hasPendingSave = false
  private(set) var permissionBlocked = false
  private(set) var message: String?
  private var session: UUID?
  private var storageKey: String?
  private var journalURL: URL?
  private var acknowledged: TtsPosition?
  private var version: String?
  private var remoteCandidate: TtsPositionSnapshot?
  private var localCandidate: TtsPosition?
  private var pendingRequest: SaveTtsPositionPayload?
  private var pendingChoice: Bool?
  private var pendingBody: Data?
  var localTarget: String? { localCandidate?.cfi }
  var remoteTarget: String? { remoteCandidate?.position?.cfi }
  private var isClosed = false
  private var resetSuspended = false

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
      let snapshot: TtsPositionSnapshot = try await api.boundedJSON(
        "tts/position/\(fileID)", query: [URLQueryItem(name: "withVersion", value: "true")],
        byteLimit: 16 * 1024, session: generation)
      let remote = snapshot.position
      guard NativeFilePositionModel.validVersion(snapshot.version) else {
        throw ConnectionError.invalidResponse
      }
      version = snapshot.version
      try await checkSession()
      guard remote.map(Self.validPosition) != false else { throw ConnectionError.invalidResponse }
      acknowledged = remote
      permissionBlocked = false
      if let journal = localJournal() {
        savedPosition = journal.position
        hasPendingSave = !same(journal.position, remote)
        if hasPendingSave { present(local: journal.position, remote: snapshot) }
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
    guard hasLoaded, !isClosed, !resetSuspended, !conflict.isBlocked, Self.validPosition(position),
      Self.validCFI(position.cfi)
    else {
      throw ConnectionError.invalidResponse
    }
    try await checkSession()
    savedPosition = position
    hasPendingSave = !same(acknowledged, position)
    try persistJournal()
  }

  @discardableResult
  func flush() async -> Bool {
    guard hasLoaded, !isClosed, !resetSuspended, !conflict.isBlocked else { return false }
    guard !isSaving else { return false }
    guard let savedPosition, hasPendingSave else { return true }
    isSaving = true
    message = nil
    defer { isSaving = false }
    do {
      try await checkSession()
      if pendingRequest == nil {
        guard let version else { throw ConnectionError.invalidResponse }
        pendingRequest = SaveTtsPositionPayload(
          cfi: savedPosition.cfi, chapterIndex: savedPosition.chapterIndex, baseVersion: version)
      }
      guard let request = pendingRequest else { throw ConnectionError.invalidResponse }
      let body = try pendingBody ?? JSONEncoder().encode(request)
      pendingBody = body
      let response: TtsPosition = try await api.boundedJSON(
        "tts/position/\(fileID)", method: "PUT", body: body,
        byteLimit: 16 * 1024, session: session)
      try await checkSession()
      guard response.cfi == request.cfi, response.chapterIndex == request.chapterIndex,
        NativeFilePositionModel.validVersion(response.version)
      else { throw ConnectionError.invalidResponse }
      let current = try await fetch()
      guard current.version == response.version else {
        present(local: localCandidate ?? savedPosition, remote: current)
        return false
      }
      acknowledged = response
      version = response.version
      pendingRequest = nil
      pendingBody = nil
      pendingChoice = nil
      permissionBlocked = false
      hasPendingSave = !same(self.savedPosition, response)
      try persistJournal()
      return !hasPendingSave
    } catch ConnectionError.http(409) {
      pendingChoice = nil
      pendingRequest = nil
      pendingBody = nil
      if let version {
        present(
          local: localCandidate ?? savedPosition,
          remote: TtsPositionSnapshot(position: acknowledged, version: version))
      }
      do { present(local: localCandidate ?? savedPosition, remote: try await fetch()) } catch {
        if !isClosed { message = error.localizedDescription }
      }
      return false
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

  func refresh() async {
    guard hasLoaded, !isClosed, !resetSuspended, !isSaving, !isResolving, !conflict.isBlocked else {
      return
    }
    do {
      let current = try await fetch()
      if current.version != version, let savedPosition {
        present(local: savedPosition, remote: current)
      }
    } catch { if !isClosed { message = error.localizedDescription } }
  }

  func choosePosition(local: Bool) async -> Bool {
    guard !isClosed, !resetSuspended, !isSaving, !isResolving, conflict.isBlocked,
      let localCandidate, let remoteCandidate
    else {
      return false
    }
    isResolving = true
    defer { isResolving = false }
    do {
      if pendingChoice == local, pendingRequest != nil {
        conflict.clear()
        let result = await flush()
        if !result, !conflict.isBlocked { present(local: localCandidate, remote: remoteCandidate) }
        return result
      }
      let current = try await fetch()
      guard current.version == remoteCandidate.version else {
        present(local: localCandidate, remote: current)
        message = "The other reader moved again. Review its new speech position before choosing."
        return false
      }
      guard let chosen = local ? localCandidate : current.position else {
        acknowledged = nil
        savedPosition = nil
        version = current.version
        hasPendingSave = false
        pendingRequest = nil
        pendingChoice = nil
        conflict.clear()
        try persistJournal()
        return true
      }
      savedPosition = chosen
      version = current.version
      hasPendingSave = true
      pendingRequest = SaveTtsPositionPayload(
        cfi: chosen.cfi, chapterIndex: chosen.chapterIndex, baseVersion: current.version)
      pendingChoice = local
      pendingBody = nil
      conflict.clear()
      let result = await flush()
      if !result, !conflict.isBlocked { present(local: localCandidate, remote: current) }
      if result { message = "Chosen speech position saved." }
      return result
    } catch { if !isClosed { message = error.localizedDescription } }
    return false
  }

  private func fetch() async throws -> TtsPositionSnapshot {
    try await checkSession()
    let snapshot: TtsPositionSnapshot = try await api.boundedJSON(
      "tts/position/\(fileID)", query: [URLQueryItem(name: "withVersion", value: "true")],
      byteLimit: 16 * 1024, session: session)
    try await checkSession()
    guard NativeFilePositionModel.validVersion(snapshot.version),
      snapshot.position.map(Self.validPosition) != false
    else {
      throw ConnectionError.invalidResponse
    }
    return snapshot
  }

  private func present(local: TtsPosition, remote: TtsPositionSnapshot) {
    guard !isClosed else { return }
    localCandidate = local
    remoteCandidate = remote
    conflict.present(
      local: label(local), remote: remote.position.map(label) ?? "No saved speech position")
    message = "Speech saving is paused until you choose a resume position."
  }

  private func same(_ first: TtsPosition?, _ second: TtsPosition?) -> Bool {
    first?.cfi == second?.cfi && first?.chapterIndex == second?.chapterIndex
  }

  private func label(_ value: TtsPosition) -> String {
    if value.cfi.hasPrefix("tts:") {
      let parts = value.cfi.split(separator: ":")
      if parts.count == 3, let block = Int(parts[2]) {
        return "Chapter \((value.chapterIndex ?? 0) + 1), spoken block \(block + 1)"
      }
    }
    return value.chapterIndex.map { "Saved passage in chapter \($0 + 1)" } ?? "Saved spoken passage"
  }

  func checkSession() async throws {
    try Task.checkCancellation()
    guard !isClosed, let session, try await api.authenticatedSessionGeneration() == session else {
      throw ConnectionError.expiredSession
    }
    try Task.checkCancellation()
  }

  func suspendForReset(_ suspended: Bool) { resetSuspended = suspended }

  func acknowledgeReset() {
    savedPosition = nil
    acknowledged = nil
    version = nil
    hasLoaded = false
    hasPendingSave = false
    pendingRequest = nil
    pendingBody = nil
    pendingChoice = nil
    localCandidate = nil
    remoteCandidate = nil
    conflict.clear()
    message = nil
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
