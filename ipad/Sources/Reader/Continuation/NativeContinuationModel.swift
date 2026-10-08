import Foundation
import Observation

struct NativeContinuationError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

struct NativeContinuationDestination: Identifiable {
  let file: BookDetailFile
  let position: BookContinuationTarget
  var id: Int { file.id }
}

@MainActor @Observable
final class NativeContinuationModel {
  let api: BookOrbitAPI
  let bookID: Int
  let direction: String
  private let files: [BookDetailFile]
  var isPresented = false
  private(set) var isBusy = false
  private(set) var response: BookContinuationResponse?
  private(set) var message: String?
  var readAloudSync: BookReadAloudSyncModel?
  @ObservationIgnored var beforeResolve: (@MainActor () async -> BookContinuationQuery?)?
  @ObservationIgnored var chosen: (@MainActor (NativeContinuationDestination) -> Void)?
  @ObservationIgnored var cancelled: (@MainActor () -> Void)?
  private var query: BookContinuationQuery?
  private var session: UUID?
  private var attempt = UUID()

  init(api: BookOrbitAPI, bookID: Int, direction: String, files: [BookDetailFile]) {
    self.api = api
    self.bookID = bookID
    self.direction = direction
    self.files = files
  }

  var title: String { direction == "text_to_audio" ? "Continue listening" : "Continue reading" }
  var explanation: String {
    response?.accuracy == "duration_adjusted"
      ? "Approximate continuation: the audiobook and recorded narration have slightly different durations. The existing bridge adjusts their timelines."
      : "Continue at the narrated passage matched to your saved position. Only editions with matching publisher text are offered."
  }

  func open() async {
    guard !isBusy, !isPresented else { return }
    isPresented = true
    isBusy = true
    response = nil
    message = nil
    query = nil
    let attempt = UUID()
    self.attempt = attempt
    defer { if self.attempt == attempt { isBusy = false } }
    do {
      let session = try await api.authenticatedSessionGeneration()
      try await check(attempt, session: session)
      self.session = session
      guard let query = await beforeResolve?() else {
        throw NativeContinuationError(
          message: "The latest position was not confirmed. Retry Save before continuing.")
      }
      try await check(attempt, session: session)
      self.query = query
      let response = try await resolve(query, session: session)
      try await check(attempt, session: session)
      self.response = response
      message = unavailableMessage(response.reason)
    } catch {
      if self.attempt == attempt, isPresented {
        if case ConnectionError.http(409) = error {
          message =
            "The saved position changed in another reader. Close this sheet and save again before continuing."
        } else {
          message = error.localizedDescription
        }
      }
    }
  }

  func choose(_ target: BookContinuationTarget) async {
    guard !isBusy, isPresented, let session, let query,
      response?.state == "ready", response?.targets.contains(target) == true,
      let file = files.first(where: { $0.id == target.fileId })
    else { return }
    isBusy = true
    message = nil
    let attempt = self.attempt
    defer { if self.attempt == attempt { isBusy = false } }
    do {
      try await check(attempt, session: session)
      let current = try await resolve(query, session: session)
      try await check(attempt, session: session)
      guard current.state == "ready", current.targets.contains(target) else {
        throw NativeContinuationError(
          message:
            "The continuation position changed. Close this sheet and save again before switching.")
      }
      isPresented = false
      chosen?(.init(file: file, position: target))
    } catch {
      if self.attempt == attempt, isPresented {
        if case ConnectionError.http(409) = error {
          message =
            "The saved position changed in another reader. Close this sheet and save again before continuing."
        } else {
          message = error.localizedDescription
        }
      }
    }
  }

  func cancel() {
    readAloudSync?.detach()
    readAloudSync = nil
    attempt = UUID()
    isBusy = false
    isPresented = false
    query = nil
    response = nil
    cancelled?()
  }

  func openReadAloudSync() {
    guard isPresented, !isBusy, response?.reason == "disabled", let session else { return }
    readAloudSync = BookReadAloudSyncModel(
      api: api, bookID: bookID, files: files, session: session)
  }

  func readAloudSyncSaved(_ setting: BookReadAloudSyncModel, book: BookDetail, session: UUID)
    async
  {
    guard readAloudSync?.id == setting.id, !setting.isDetached,
      isPresented, !isBusy, self.session == session, book.id == bookID
    else { return }
    let attempt = self.attempt
    isBusy = true
    response = nil
    query = nil
    message = nil
    defer { if self.attempt == attempt { isBusy = false } }
    do {
      try await check(attempt, session: session)
      guard let query = await beforeResolve?() else {
        throw NativeContinuationError(
          message: "The setting was saved. Confirm your resume choice and Save before continuing.")
      }
      try await check(attempt, session: session)
      self.query = query
      let current = try await resolve(query, session: session)
      try await check(attempt, session: session)
      response = current
      message = unavailableMessage(current.reason)
    } catch {
      guard self.attempt == attempt, isPresented else { return }
      if case ConnectionError.http(409) = error {
        message =
          "The setting was saved, but the position changed in another reader. Close this sheet and choose a resume position before continuing."
      } else {
        message =
          "The setting was saved. Continuation could not be confirmed. \(error.localizedDescription)"
      }
    }
  }

  private func resolve(_ query: BookContinuationQuery, session: UUID) async throws
    -> BookContinuationResponse
  {
    var items = [
      URLQueryItem(name: "direction", value: query.direction),
      URLQueryItem(name: "sourceFileId", value: String(query.sourceFileId)),
    ]
    if let cfi = query.textCfi { items.append(.init(name: "textCfi", value: cfi)) }
    if let revision = query.audioRevision {
      items.append(.init(name: "audioRevision", value: String(revision)))
    }
    let value: BookContinuationResponse = try await api.boundedJSON(
      "books/\(bookID)/continuation", query: items, byteLimit: 128 * 1024, session: session)
    guard ["ready", "unavailable"].contains(value.state), value.sourceFileId == query.sourceFileId,
      value.targets.count <= 32, Set(value.targets.map(\.fileId)).count == value.targets.count,
      value.state != "ready"
        || (value.reason == nil && !value.targets.isEmpty
          && ["narrated_segment", "duration_adjusted"].contains(value.accuracy ?? "")
          && value.sourceTextCfi == query.textCfi
          && value.sourceAudioRevision == query.audioRevision)
    else { throw ConnectionError.invalidResponse }
    for target in value.targets {
      guard let file = files.first(where: { $0.id == target.fileId }),
        file.format?.lowercased() == target.format.lowercased(), target.filename.utf16.count <= 1024
      else { throw ConnectionError.fileChanged }
      if direction == "audio_to_text" {
        guard target.format.lowercased() == "epub", let cfi = target.cfi,
          cfi.hasPrefix("epubcfi("), cfi.utf16.count <= 2000,
          target.assetId == nil, target.positionMs == nil
        else { throw ConnectionError.invalidResponse }
      } else {
        guard AudioStreamFormat.mimeTypes[target.format.lowercased()] != nil,
          let asset = target.assetId, asset.hasPrefix("aud_"),
          UUID(uuidString: String(asset.dropFirst(4))) != nil,
          let milliseconds = target.positionMs, (0...9_007_199_254_740_991).contains(milliseconds),
          let sequence = target.sequence, (0..<4096).contains(sequence), target.cfi == nil
        else { throw ConnectionError.invalidResponse }
      }
    }
    return value
  }

  private func check(_ attempt: UUID, session: UUID) async throws {
    let currentSession = try await api.authenticatedSessionGeneration()
    try Task.checkCancellation()
    guard self.attempt == attempt, isPresented, currentSession == session
    else { throw ConnectionError.expiredSession }
  }

  private func unavailableMessage(_ reason: String?) -> String? {
    switch reason {
    case "disabled":
      "Progress sync is disabled for your account on this book. Edit progress sync to enable matching ebook and audio continuation."
    case "unsupported_source": "This file format has no supported narration mapping."
    case "no_media_overlay_epub":
      "This book has no EPUB with recorded narration to match its text and audiobook."
    case "ambiguous_media_overlay":
      "Several recorded EPUBs could supply the mapping. Choose a primary recorded EPUB in the web book settings."
    case "ambiguous_audio_order":
      "Several audio files have the same track order and filename. Set distinct track orders in the web book settings before continuing."
    case "no_audio_files":
      "This book has no separate audiobook files. Recorded Read Along remains available in the EPUB reader when supplied by the publisher."
    case "missing_duration":
      "Continuation needs measured durations for the audiobook and recorded narration."
    case "duration_mismatch":
      "The audiobook and recorded narration durations differ too much for a reliable continuation."
    case "position_not_mapped": "No narrated passage could be matched to the saved position."
    case "position_not_synced":
      "The matching destination save was not confirmed. A newer position may be held by another reader. Save again before continuing."
    case "too_many_files":
      "This book exceeds the supported continuation limit of 4096 files or 32 EPUB editions."
    case "overlay_exceeds_limit":
      "The recorded narration metadata exceeds the supported continuation limit."
    case nil: nil
    default: "Continuation is unavailable for this book."
    }
  }
}
