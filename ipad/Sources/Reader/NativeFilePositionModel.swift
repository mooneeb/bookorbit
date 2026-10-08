import Foundation
import Observation

@MainActor @Observable
final class NativeFilePositionModel {
  let api: BookOrbitAPI
  let fileID: Int
  let source: String
  let conflict = ReaderPositionConflictState()
  private(set) var acknowledged: FileReadingProgress?
  private(set) var pending: SaveFileProgressPayload?
  private(set) var isSaving = false
  private(set) var isResolving = false
  private(set) var message: String?
  private var remoteCandidate: FileReadingProgress?
  private var localCandidate: SaveFileProgressPayload?
  private var session: UUID?
  var localTarget: String? { localCandidate?.cfi ?? localCandidate?.mediaOverlayFragment }
  var remoteTarget: String? {
    source == "narration" ? remoteCandidate?.mediaOverlayFragment : remoteCandidate?.cfi
  }
  private var isClosed = false
  private var pendingChoice: Bool?
  private var pendingBody: Data?
  private var beginning: SaveFileProgressPayload?

  init(api: BookOrbitAPI, fileID: Int, source: String = "text") {
    self.api = api
    self.fileID = fileID
    self.source = source
  }

  func accept(_ value: FileReadingProgress, session: UUID) throws {
    guard !isClosed, Self.validVersion(version(value)), value.percentage.isFinite,
      (0...100).contains(value.percentage), valid(value)
    else { throw ConnectionError.invalidResponse }
    self.session = session
    acknowledged = value
  }

  func setBeginning(_ value: SaveFileProgressPayload) {
    beginning = value
    if let localCandidate, let remoteCandidate {
      present(local: localCandidate, remote: remoteCandidate)
    }
  }

  func retainLocal(_ value: SaveFileProgressPayload) {
    guard let acknowledged, !matches(acknowledged, value) else { return }
    pending = value
    present(local: value, remote: acknowledged)
  }

  @discardableResult
  func save(_ value: SaveFileProgressPayload) async -> FileReadingProgress? {
    guard !isClosed, !isSaving, !isResolving, !conflict.isBlocked, let acknowledged else {
      return nil
    }
    if pending == nil {
      var payload = value
      payload.source = source
      payload.baseVersion = version(acknowledged)
      pending = payload
      pendingBody = nil
    }
    return await flush()
  }

  private func flush() async -> FileReadingProgress? {
    guard !isClosed, !isSaving, let pending else { return nil }
    isSaving = true
    message = nil
    defer { isSaving = false }
    do {
      try await checkSession()
      let body = try pendingBody ?? JSONEncoder().encode(pending)
      pendingBody = body
      let saved: FileReadingProgress = try await api.boundedJSON(
        "books/files/\(fileID)/progress", method: "POST", body: body,
        byteLimit: 16 * 1024, session: session)
      try await checkSession()
      guard matches(saved, pending), Self.validVersion(version(saved)) else {
        throw ConnectionError.invalidResponse
      }
      let current = try await fetch()
      guard version(current) == version(saved), matches(current, pending) else {
        present(local: localCandidate ?? pending, remote: current)
        return nil
      }
      acknowledged = saved
      self.pending = nil
      pendingBody = nil
      pendingChoice = nil
      conflict.clear()
      localCandidate = nil
      remoteCandidate = nil
      return saved
    } catch ConnectionError.http(409) {
      pendingChoice = nil
      if let acknowledged { present(local: localCandidate ?? pending, remote: acknowledged) }
      do { present(local: localCandidate ?? pending, remote: try await fetch()) } catch {
        if !isClosed { message = error.localizedDescription }
      }
    } catch {
      if !isClosed {
        message =
          "Position could not be confirmed. Retry sends the same saved request. \(error.localizedDescription)"
      }
    }
    return nil
  }

  func refresh(_ local: SaveFileProgressPayload? = nil) async {
    guard !isClosed, !isSaving, !isResolving, !conflict.isBlocked, let acknowledged else { return }
    do {
      let current = try await fetch()
      if version(current) != version(acknowledged) {
        present(local: pending ?? local ?? payload(acknowledged), remote: current)
      }
    } catch { if !isClosed { message = error.localizedDescription } }
  }

  func choose(local: Bool) async -> FileReadingProgress? {
    guard !isClosed, !isSaving, !isResolving, conflict.isBlocked, let localCandidate,
      let remoteCandidate
    else {
      return nil
    }
    isResolving = true
    defer { isResolving = false }
    do {
      if pendingChoice == local, pending != nil { return await flush() }
      let current = try await fetch()
      guard version(current) == version(remoteCandidate) else {
        present(local: localCandidate, remote: current)
        message = "The other reader moved again. Review its new position before choosing."
        return nil
      }
      if !local, source == "narration", current.mediaOverlayFragment == nil {
        acknowledged = current
        pending = nil
        pendingChoice = nil
        conflict.clear()
        self.localCandidate = nil
        self.remoteCandidate = nil
        return current
      }
      var chosen = local ? localCandidate : payload(current)
      chosen.baseVersion = version(current)
      pending = chosen
      pendingBody = nil
      pendingChoice = local
      acknowledged = current
      return await flush()
    } catch { if !isClosed { message = error.localizedDescription } }
    return nil
  }

  func close() { isClosed = true }

  private func checkSession() async throws {
    try Task.checkCancellation()
    guard !isClosed, let session, session == (try await api.authenticatedSessionGeneration()) else {
      throw ConnectionError.expiredSession
    }
    try Task.checkCancellation()
  }

  private func fetch() async throws -> FileReadingProgress {
    try await checkSession()
    let value: FileReadingProgress = try await api.boundedJSON(
      "books/files/\(fileID)/progress", byteLimit: 16 * 1024, session: session)
    try await checkSession()
    guard Self.validVersion(version(value)), valid(value) else {
      throw ConnectionError.invalidResponse
    }
    return value
  }

  private func present(local: SaveFileProgressPayload, remote: FileReadingProgress) {
    guard !isClosed else { return }
    localCandidate = local
    remoteCandidate = remote
    conflict.present(local: label(local), remote: label(payload(remote)))
    message = "Saving is paused until you choose a resume position."
  }

  private func version(_ value: FileReadingProgress) -> String? {
    source == "narration" ? value.narrationVersion : value.textVersion
  }

  func payload(_ value: FileReadingProgress) -> SaveFileProgressPayload {
    if source == "text", value.cfi == nil, value.pageNumber == nil, value.percentage == 0,
      let beginning
    {
      return beginning
    }
    var payload = SaveFileProgressPayload(
      percentage: source == "narration" ? value.narrationPercentage ?? 0 : value.percentage)
    payload.source = source
    if source == "narration" {
      payload.positionSeconds = value.positionSeconds
      payload.mediaOverlayFragment = value.mediaOverlayFragment
      payload.mediaOverlaySectionIndex = value.mediaOverlaySectionIndex
    } else {
      payload.cfi = value.cfi
      payload.pageNumber = value.pageNumber
    }
    return payload
  }

  private func matches(_ value: FileReadingProgress, _ payload: SaveFileProgressPayload) -> Bool {
    if source == "narration" {
      return value.mediaOverlayFragment == payload.mediaOverlayFragment
        && value.mediaOverlaySectionIndex == payload.mediaOverlaySectionIndex
        && value.positionSeconds == payload.positionSeconds
        && abs((value.narrationPercentage ?? -1) - payload.percentage) < 0.00001
    }
    return value.cfi == payload.cfi && value.pageNumber == payload.pageNumber
      && abs(value.percentage - payload.percentage) < 0.00001
  }

  private func valid(_ value: FileReadingProgress) -> Bool {
    value.percentage.isFinite && (0...100).contains(value.percentage)
      && value.pageNumber.map { $0.isFinite && $0 >= 1 && $0 <= 100_000 && $0.rounded() == $0 }
        != false
      && value.cfi.map { $0.hasPrefix("epubcfi(") && $0.utf16.count <= 2000 } != false
      && value.positionSeconds.map { $0.isFinite && $0 >= 0 && $0 <= Double(Int.max / 1000) }
        != false
      && value.narrationPercentage.map { $0.isFinite && (0...100).contains($0) } != false
      && value.mediaOverlaySectionIndex.map { $0 >= 0 && $0 <= 4096 } != false
      && value.mediaOverlayFragment.map { $0.utf8.count <= 4096 } != false
  }

  private func label(_ value: SaveFileProgressPayload) -> String {
    if source == "narration" {
      if value.mediaOverlayFragment == nil { return "No saved recorded narration position" }
      let chapter = value.mediaOverlaySectionIndex.map { "Chapter \($0 + 1), " } ?? ""
      let time = value.positionSeconds.map { AudioPlaybackModel.clock($0) + ", " } ?? ""
      return
        "\(chapter)\(time)\(value.percentage.formatted(.number.precision(.fractionLength(1)))) percent narrated"
    }
    if let page = value.pageNumber {
      return "Page \(Int(page)), \(Int(value.percentage)) percent read"
    }
    return "\(value.percentage.formatted(.number.precision(.fractionLength(1)))) percent read"
  }

  nonisolated static func validVersion(_ value: String?) -> Bool {
    value.map { $0.count == 64 && $0.allSatisfy { $0.isASCII && $0.isHexDigit } } == true
  }
}
