import CryptoKit
import Foundation
import Observation

struct NativeRecordedResume: Codable, Sendable, Equatable {
  let fragment: String
  let sectionIndex: Int
  let offsetSeconds: Double
  let positionSeconds: Double?
  let percentage: Double
  let cfi: String?
}

@MainActor @Observable
final class NativeRecordedPositionModel {
  private struct Journal: Codable {
    let resume: NativeRecordedResume
    let pending: Bool
    let acknowledgedAt: String?
  }
  let api: BookOrbitAPI
  let fileID: Int
  let canonical: NativeFilePositionModel
  var conflict: ReaderPositionConflictState { canonical.conflict }
  private(set) var saved: NativeRecordedResume?
  private(set) var hasLoaded = false
  private(set) var hasPendingSave = false
  private(set) var isSaving = false
  private(set) var message: String?
  private var session: UUID?
  private var journalURL: URL?
  private var acknowledgedAt: String?
  private var isClosed = false

  init(api: BookOrbitAPI, fileID: Int) {
    self.api = api
    self.fileID = fileID
    canonical = NativeFilePositionModel(api: api, fileID: fileID, source: "narration")
  }

  func load() async throws {
    guard !isClosed else { throw NativeRecordedError.closed }
    let session = try await api.authenticatedSessionGeneration()
    self.session = session
    let namespace = try await api.storageNamespace()
    try await checkSession()
    let directory = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask, appropriateFor: nil, create: true
    )
    .appendingPathComponent("RecordedNarrationPositions", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let key = SHA256.hash(data: Data("\(namespace).file.\(fileID)".utf8))
      .map { String(format: "%02x", $0) }.joined()
    journalURL = directory.appendingPathComponent("\(key).json")
    let remote: FileReadingProgress = try await api.boundedJSON(
      "books/files/\(fileID)/progress",
      byteLimit: 16 * 1024, session: session)
    try await checkSession()
    try canonical.accept(remote, session: session)
    acknowledgedAt = remote.narrationUpdatedAt
    if let local = readJournal() {
      saved = local.resume
      hasPendingSave = local.pending
      canonical.retainLocal(payload(local.resume))
      if conflict.isBlocked { hasPendingSave = true }
    } else {
      saved = resume(remote)
      hasPendingSave = false
    }
    hasLoaded = true
    message = nil
  }

  func record(_ value: NativeRecordedResume) throws {
    guard hasLoaded, !isClosed, !conflict.isBlocked, Self.valid(value) else {
      throw ConnectionError.invalidResponse
    }
    if saved != value {
      saved = value
      hasPendingSave = true
      try persist()
    }
  }

  @discardableResult
  func flush() async -> Bool {
    guard hasLoaded, !isClosed, !isSaving, !conflict.isBlocked else { return false }
    guard let value = saved, hasPendingSave else { return true }
    isSaving = true
    message = nil
    defer { isSaving = false }
    do {
      try await checkSession()
      guard let response = await canonical.save(payload(value)) else {
        message = canonical.message
        return false
      }
      try await checkSession()
      acknowledgedAt = response.narrationUpdatedAt
      hasPendingSave =
        saved != value || response.mediaOverlayFragment != value.fragment
        || response.mediaOverlaySectionIndex != value.sectionIndex
        || response.positionSeconds != value.positionSeconds
        || abs((response.narrationPercentage ?? -1) - value.percentage) >= 0.00001
      try persist()
      return !hasPendingSave
    } catch {
      if !isClosed {
        message =
          "Recorded position is kept on this iPad. Sync failed. \(error.localizedDescription)"
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

  func choosePosition(local: Bool) async -> Bool {
    guard !isClosed, !isSaving else { return false }
    isSaving = true
    let localResume = saved
    defer { isSaving = false }
    guard let response = await canonical.choose(local: local) else {
      message = canonical.message
      return false
    }
    do {
      try await checkSession()
      if local, let localResume, localResume.fragment == response.mediaOverlayFragment,
        localResume.sectionIndex == response.mediaOverlaySectionIndex,
        localResume.positionSeconds == response.positionSeconds
      {
        saved = localResume
      } else {
        saved = resume(response)
      }
      acknowledgedAt = response.narrationUpdatedAt
      hasPendingSave = false
      try persist()
      message = "Chosen recorded narration position saved."
      return true
    } catch {
      message = error.localizedDescription
      return false
    }
  }

  func refresh() async {
    await canonical.refresh(saved.map(payload))
    if conflict.isBlocked { message = canonical.message }
  }

  private func payload(_ value: NativeRecordedResume) -> SaveFileProgressPayload {
    var result = SaveFileProgressPayload(percentage: value.percentage)
    result.source = "narration"
    result.positionSeconds = value.positionSeconds
    result.mediaOverlayFragment = value.fragment
    result.mediaOverlaySectionIndex = value.sectionIndex
    return result
  }

  private func resume(_ remote: FileReadingProgress) -> NativeRecordedResume? {
    guard let fragment = remote.mediaOverlayFragment, let section = remote.mediaOverlaySectionIndex
    else {
      return nil
    }
    let value = NativeRecordedResume(
      fragment: fragment, sectionIndex: section, offsetSeconds: 0,
      positionSeconds: remote.positionSeconds, percentage: remote.narrationPercentage ?? 0, cfi: nil
    )
    return Self.valid(value) ? value : nil
  }

  func acknowledgeReset() {
    saved = nil
    hasPendingSave = false
    acknowledgedAt = nil
    message = nil
    canonical.acknowledgeReset()
  }

  func close() {
    isClosed = true
    canonical.close()
  }

  nonisolated static func valid(_ value: NativeRecordedResume) -> Bool {
    !value.fragment.isEmpty && value.fragment.utf8.count <= 4096 && value.sectionIndex >= 0
      && value.offsetSeconds.isFinite && value.offsetSeconds >= 0
      && value.positionSeconds.map({ $0.isFinite && $0 >= 0 }) != false
      && value.percentage.isFinite && (0...100).contains(value.percentage)
      && value.cfi.map(NativeTTSPositionModel.validCFI) != false
  }

  private func readJournal() -> Journal? {
    guard let journalURL,
      let size = try? journalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size <= 16 * 1024, let data = try? Data(contentsOf: journalURL),
      let journal = try? JSONDecoder().decode(Journal.self, from: data), Self.valid(journal.resume)
    else { return nil }
    return journal
  }

  private func persist() throws {
    guard let journalURL else { return }
    guard let saved else {
      if FileManager.default.fileExists(atPath: journalURL.path) {
        try FileManager.default.removeItem(at: journalURL)
      }
      return
    }
    let data = try JSONEncoder().encode(
      Journal(resume: saved, pending: hasPendingSave, acknowledgedAt: acknowledgedAt))
    guard data.count <= 16 * 1024 else { throw ConnectionError.invalidResponse }
    try data.write(
      to: journalURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }
}
