import Foundation
import Observation

enum NativePositionResetTarget {
  case file(bookID: Int, fileID: Int, label: String)
  case audiobook(bookID: Int, label: String)
  case speech(bookID: Int, fileID: Int, label: String)

  var label: String {
    switch self {
    case .file(_, _, let label), .audiobook(_, let label), .speech(_, _, let label): label
    }
  }

  var path: String {
    switch self {
    case .file(_, let fileID, _): "books/files/\(fileID)/progress"
    case .audiobook(let bookID, _): "audiobooks/\(bookID)/playback-state"
    case .speech(_, let fileID, _): "tts/position/\(fileID)"
    }
  }

  var confirmedMessage: String {
    switch self {
    case .file:
      "Saved file positions cleared. The next reading session uses its default starting position."
    case .audiobook: "Saved listening position cleared. Reopening has no saved track or time."
    case .speech:
      "Saved speech position cleared. The previous spoken passage is no longer offered for resume."
    }
  }

  var explanation: String {
    switch self {
    case .file:
      "Clear your text and recorded narration positions for this file. This also clears this file's KOReader positions and resets the Kobo bookmark and device status when this is the primary file. Audiobook playback is cleared if this file is the current audio file. Your BookOrbit reading sessions, personal dates, notes and bookmarks remain. The source file stays unchanged."
    case .audiobook:
      "Clear your saved playback for this audiobook, including the current track and time. Reopening has no saved track or time and starts at the beginning of the opened track. Your audio bookmarks, ebook positions and source files remain."
    case .speech:
      "Stop speech and clear your saved spoken passage for this file, for both installed and server voices. Your text, recorded narration and audiobook positions remain. The source file stays unchanged."
    }
  }
}

@MainActor @Observable
final class NativePositionResetModel: Identifiable {
  private struct Snapshot {
    let label: String
    let query: [URLQueryItem]
    let isEmpty: Bool
  }

  let id = UUID()
  let api: BookOrbitAPI
  let target: NativePositionResetTarget
  private(set) var isBusy = false
  private(set) var hasPrepared = false
  private(set) var didAttempt = false
  private(set) var didAcknowledgeDeletion = false
  private(set) var didClearLocalPosition = false
  private(set) var isConfirmed = false
  private(set) var savedPosition = ""
  private(set) var message: String?
  private(set) var error: String?
  private var snapshot: Snapshot?
  private var session: UUID?
  private var namespace: String?
  private var isClosed = false
  private var cleanupPending = false
  @ObservationIgnored private let prepare: @MainActor () async throws -> Void
  @ObservationIgnored private let acknowledged: @MainActor () async throws -> Void

  init(
    api: BookOrbitAPI, target: NativePositionResetTarget,
    prepare: @escaping @MainActor () async throws -> Void = {},
    acknowledged: @escaping @MainActor () async throws -> Void = {}
  ) {
    self.api = api
    self.target = target
    self.prepare = prepare
    self.acknowledged = acknowledged
  }

  var canReset: Bool {
    !isClosed && !isBusy && hasPrepared && snapshot != nil && !isConfirmed && !cleanupPending
  }

  func load() async {
    guard !isClosed, !isBusy, !isConfirmed else { return }
    isBusy = true
    error = nil
    defer { isBusy = false }
    do {
      if session == nil {
        session = try await api.authenticatedSessionGeneration()
        namespace = try await api.storageNamespace()
      }
      try await checkSession()
      if !hasPrepared {
        try await prepare()
        try await checkSession()
        hasPrepared = true
      }
      if cleanupPending { try await cleanAcknowledgedPosition() }
      let current = try await fetch()
      snapshot = current
      savedPosition = current.label
      if didAcknowledgeDeletion && current.isEmpty {
        isConfirmed = true
        message = "The server confirms there is no saved position."
      } else if didAttempt {
        message =
          "Review the server's current position before resetting again. An earlier request may have finished."
      }
    } catch {
      snapshot = nil
      if !isClosed { self.error = error.localizedDescription }
    }
  }

  func reset() async {
    guard canReset, let snapshot else { return }
    isBusy = true
    error = nil
    message = nil
    defer { isBusy = false }
    do {
      try await checkSession()
      didAttempt = true
      didAcknowledgeDeletion = false
      didClearLocalPosition = false
      try await api.sendEmpty(
        target.path, method: "DELETE", query: snapshot.query, session: session, expectedStatus: 204)
      try await checkSession()
      didAcknowledgeDeletion = true
      cleanupPending = true
      try await cleanAcknowledgedPosition()
      let current = try await fetch()
      self.snapshot = current
      savedPosition = current.label
      if current.isEmpty {
        isConfirmed = true
        message = target.confirmedMessage
      } else {
        message =
          "The reset was acknowledged, but another reader has saved a position since then. Review it before resetting again."
      }
    } catch ConnectionError.http(409) {
      self.snapshot = nil
      self.error =
        "The position changed in another reader. Check its current position before resetting."
    } catch ConnectionError.http(412) {
      self.snapshot = nil
      self.error = "The audiobook files changed. Close and reopen this book before resetting."
    } catch {
      if !isClosed {
        self.error =
          didAcknowledgeDeletion
          ? "The reset was acknowledged. Its current position could not be confirmed. Check the server again. \(error.localizedDescription)"
          : "The reset was not confirmed. Check the server before retrying. \(error.localizedDescription)"
        self.snapshot = nil
      }
    }
  }

  func detach() { isClosed = true }

  private func cleanAcknowledgedPosition() async throws {
    try await checkSession()
    guard let namespace else { throw ConnectionError.invalidResponse }
    try NativePositionResetJournals.clear(target, namespace: namespace)
    try await acknowledged()
    try await checkSession()
    cleanupPending = false
    didClearLocalPosition = true
  }

  private func checkSession() async throws {
    try Task.checkCancellation()
    guard !isClosed, let session, try await api.authenticatedSessionGeneration() == session else {
      throw ConnectionError.expiredSession
    }
    try Task.checkCancellation()
  }

  private func fetch() async throws -> Snapshot {
    try await checkSession()
    let value: Snapshot
    switch target {
    case .file:
      let current: FileReadingProgress = try await api.boundedJSON(
        target.path, byteLimit: 16 * 1024, session: session)
      guard NativeFilePositionModel.validVersion(current.textVersion),
        NativeFilePositionModel.validVersion(current.narrationVersion),
        current.percentage.isFinite, (0...100).contains(current.percentage),
        current.narrationPercentage.map({ $0.isFinite && (0...100).contains($0) }) != false,
        current.pageNumber.map({ $0.isFinite && (1...100_000).contains($0) && $0.rounded() == $0 })
          != false
      else { throw ConnectionError.invalidResponse }
      let text =
        current.pageNumber.map { "Page \(Int($0))" }
        ?? "\(current.percentage.formatted(.number.precision(.fractionLength(1)))) percent read"
      let narration =
        current.narrationPercentage.map {
          ", \($0.formatted(.number.precision(.fractionLength(1)))) percent narrated"
        } ?? ""
      value = Snapshot(
        label: text + narration,
        query: ClearFileProgressQuery(
          textVersion: current.textVersion, narrationVersion: current.narrationVersion
        ).urlQuery,
        isEmpty: current.cfi == nil && current.pageNumber == nil && current.percentage == 0
          && current.mediaOverlayFragment == nil && current.mediaOverlaySectionIndex == nil
          && current.positionSeconds == nil && current.narrationPercentage == nil
          && current.koreaderProgress == nil && current.koboLocationValue == nil
          && current.koboLocationSource == nil && current.koboLocationType == nil
          && current.koboContentSourceProgressPercent == nil
          && current.textUpdatedAt == nil && current.narrationUpdatedAt == nil)
    case .speech:
      let current: TtsPositionSnapshot = try await api.boundedJSON(
        target.path, query: [URLQueryItem(name: "withVersion", value: "true")],
        byteLimit: 16 * 1024, session: session)
      guard NativeFilePositionModel.validVersion(current.version),
        current.position.map(NativeTTSPositionModel.validPosition) != false
      else { throw ConnectionError.invalidResponse }
      value = Snapshot(
        label: current.position.map { position in
          position.chapterIndex.map { "Spoken passage in chapter \($0 + 1)" }
            ?? "Saved spoken passage"
        } ?? "No saved spoken passage",
        query: ClearTtsPositionQuery(baseVersion: current.version).urlQuery,
        isEmpty: current.position == nil)
    case .audiobook(let bookID, _):
      let manifest: AudiobookManifest = try await api.boundedJSON(
        "audiobooks/\(bookID)/manifest", byteLimit: 2 * 1024 * 1024, session: session)
      let current: AudiobookPlaybackState? = try await api.boundedJSON(
        target.path, byteLimit: 16 * 1024, session: session)
      guard manifest.book.id == bookID, (1...4096).contains(manifest.assets.count),
        NativeFilePositionModel.validVersion(manifest.revision),
        current.map({ position in
          position.revision >= 0 && position.positionMs >= 0
            && position.percentage.isFinite && (0...100).contains(position.percentage)
            && position.manifestRevision == manifest.revision
            && manifest.assets.contains(where: { $0.assetId == position.assetId })
        }) != false
      else { throw ConnectionError.invalidResponse }
      let track = current.flatMap { position in
        manifest.assets.first { $0.assetId == position.assetId }
      }
      value = Snapshot(
        label: current.map {
          "Track \((track?.sequence ?? 0) + 1), \(AudioPlaybackModel.clock(Double($0.positionMs) / 1000))"
        }
          ?? "No saved listening position",
        query: DeleteAudiobookPlaybackStateQuery(
          baseRevision: current?.revision ?? 0, manifestRevision: manifest.revision
        ).urlQuery, isEmpty: current == nil)
    }
    try await checkSession()
    return value
  }
}
