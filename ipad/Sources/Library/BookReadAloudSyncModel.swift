import Foundation
import Observation

@MainActor @Observable
final class BookReadAloudSyncModel: Identifiable {
  let id = UUID()
  let api: BookOrbitAPI
  let bookID: Int
  private let expectedFiles: [BookDetailFile]
  private let expectedSession: UUID?
  private let expectedUserID: Int?
  private(set) var book: BookDetail?
  private(set) var session: UUID?
  private(set) var isBusy = false
  private(set) var isComplete = false
  private(set) var isDetached = false
  private(set) var error: String?
  private(set) var pendingMode: String?
  var selectedMode = "auto"
  private var attempt = UUID()
  @ObservationIgnored private var savingTask: Task<Void, Never>?

  init(
    api: BookOrbitAPI, bookID: Int, files: [BookDetailFile], session: UUID? = nil,
    userID: Int? = nil
  ) {
    self.api = api
    self.bookID = bookID
    expectedFiles = files
    expectedSession = session
    expectedUserID = userID
  }

  var canSave: Bool {
    !isBusy && !isDetached && !isComplete && pendingMode == nil
      && book != nil && ["auto", "disabled"].contains(selectedMode)
      && selectedMode != book?.readAloudSync.mode
  }

  var canRetry: Bool {
    !isBusy && !isDetached && !isComplete && pendingMode != nil && session != nil
  }

  var isSaving: Bool { isBusy && pendingMode != nil }

  func load() async {
    guard book == nil, !isBusy, !isDetached else { return }
    isBusy = true
    error = nil
    let attempt = self.attempt
    defer { if self.attempt == attempt { isBusy = false } }
    do {
      let currentSession = try await api.authenticatedSessionGeneration()
      let session = self.session ?? expectedSession ?? currentSession
      guard currentSession == session else {
        throw ConnectionError.expiredSession
      }
      try await check(attempt, session: session)
      self.session = session
      if let userID = expectedUserID {
        let user: AuthUser = try await api.boundedJSON("auth/me", session: session)
        try await check(attempt, session: session)
        guard user.id == userID else { throw ConnectionError.expiredSession }
      }
      let current: BookDetail = try await api.boundedJSON("books/\(bookID)", session: session)
      try await check(attempt, session: session)
      try validate(current)
      book = current
      selectedMode = current.readAloudSync.mode
    } catch {
      handle(error, attempt: attempt, saving: false)
    }
  }

  func save() async {
    guard canSave, let session else { return }
    pendingMode = selectedMode
    await runSave(session: session)
  }

  func retry() async {
    guard canRetry, let session else { return }
    await runSave(session: session)
  }

  func detach() {
    attempt = UUID()
    savingTask?.cancel()
    savingTask = nil
    isDetached = true
    isBusy = false
    isComplete = false
    book = nil
    session = nil
  }

  private func runSave(session: UUID) async {
    let attempt = self.attempt
    isBusy = true
    let task = Task { await self.persist(session: session) }
    savingTask = task
    await task.value
    if self.attempt == attempt { savingTask = nil }
  }

  private func persist(session: UUID) async {
    guard let mode = pendingMode else { return }
    isBusy = true
    error = nil
    let attempt = self.attempt
    defer { if self.attempt == attempt { isBusy = false } }
    do {
      try await check(attempt, session: session)
      let beforeSave: BookDetail = try await api.boundedJSON("books/\(bookID)", session: session)
      try await check(attempt, session: session)
      try validate(beforeSave)
      let payload = UpdateBookReadAloudSyncPayload(mode: mode)
      let saved: BookDetail = try await api.boundedJSON(
        "books/\(bookID)/read-aloud-sync", method: "PATCH",
        body: JSONEncoder().encode(payload), session: session, expectedStatus: 200)
      try await check(attempt, session: session)
      try validate(saved)
      guard saved.readAloudSync.mode == mode else { throw ConnectionError.invalidResponse }
      let current: BookDetail = try await api.boundedJSON("books/\(bookID)", session: session)
      try await check(attempt, session: session)
      try validate(current)
      guard current.readAloudSync.mode == mode else {
        throw BookReadAloudSyncError(
          message: "The setting changed in another client before it could be confirmed.")
      }
      book = current
      selectedMode = current.readAloudSync.mode
      pendingMode = nil
      isComplete = true
    } catch {
      handle(error, attempt: attempt, saving: true)
    }
  }

  private func check(_ attempt: UUID, session: UUID) async throws {
    let current = try await api.authenticatedSessionGeneration()
    try Task.checkCancellation()
    guard self.attempt == attempt, !isDetached, current == session else {
      throw ConnectionError.expiredSession
    }
  }

  private func validate(_ value: BookDetail) throws {
    guard value.id == bookID else { throw ConnectionError.invalidResponse }
    guard
      value.files.sorted(by: { $0.id < $1.id })
        == expectedFiles.sorted(by: { $0.id < $1.id })
    else { throw ConnectionError.fileChanged }
    let sync = value.readAloudSync
    guard ["auto", "disabled"].contains(sync.mode),
      ["enabled", "disabled", "unavailable"].contains(sync.state),
      (sync.mode == "disabled") == (sync.state == "disabled"),
      (sync.state == "unavailable") == (sync.unavailableReason != nil),
      sync.unavailableReason.map({
        ["no_media_overlay_epub", "no_audio_files", "missing_duration", "duration_mismatch"]
          .contains($0)
      }) ?? true
    else { throw ConnectionError.invalidResponse }
  }

  private func handle(_ failure: Error, attempt: UUID, saving: Bool) {
    guard self.attempt == attempt, !isDetached else { return }
    let unavailable: Bool
    switch failure {
    case ConnectionError.expiredSession, ConnectionError.denied, ConnectionError.fileChanged,
      ConnectionError.http(404):
      unavailable = true
    default: unavailable = false
    }
    if unavailable {
      isDetached = true
      error =
        "This account, book, or its files changed or became unavailable. Close and reopen the book to check its current setting. \(failure.localizedDescription)"
    } else {
      error =
        saving
        ? "Your setting could not be confirmed and may already be saved. Retry sends the same \(BookReadAloudSyncPresentation.modeLabel(pendingMode ?? selectedMode)) choice. \(failure.localizedDescription)"
        : "Could not load your current setting. \(failure.localizedDescription)"
    }
  }
}

private struct BookReadAloudSyncError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

@MainActor
struct BookReadAloudSyncPresentation {
  let book: BookDetail

  static func isVisible(_ book: BookDetail) -> Bool {
    book.files.contains {
      ($0.format?.lowercased() == "epub" && $0.mediaOverlay?.available == true)
        || AudioStreamFormat.mimeTypes[$0.format?.lowercased() ?? ""] != nil
    }
  }

  static func modeLabel(_ mode: String) -> String { mode == "disabled" ? "Disabled" : "Auto" }

  var epubCopiesOnly: Bool {
    book.readAloudSync.state == "unavailable"
      && book.readAloudSync.unavailableReason != "no_media_overlay_epub"
      && book.files.filter { $0.format?.lowercased() == "epub" }.count > 1
  }

  var state: String {
    if epubCopiesOnly { return "EPUB copies only" }
    switch book.readAloudSync.state {
    case "enabled": return "Enabled"
    case "disabled": return "Disabled"
    default: return "Unavailable"
    }
  }

  var description: String {
    switch book.readAloudSync.state {
    case "enabled":
      return
        "Audiobook, web reader, Kobo, and KOReader positions stay in sync through matching recorded narration."
    case "disabled": return "Each format keeps its own reading position."
    default:
      if epubCopiesOnly {
        return
          "Web reader, Kobo, and KOReader positions stay in sync across the EPUB copies. Add matching audiobook files to sync the audiobook too."
      }
      return unavailableReason
    }
  }

  var audiobookNote: String? {
    epubCopiesOnly && book.readAloudSync.unavailableReason != "no_audio_files"
      ? unavailableReason : nil
  }

  private var unavailableReason: String {
    switch book.readAloudSync.unavailableReason {
    case "no_media_overlay_epub": return "A read-along EPUB with media overlays is required."
    case "no_audio_files": return "Matching standalone audiobook files are required."
    case "duration_mismatch":
      return
        "Durations do not match closely enough: audiobook \(duration(book.readAloudSync.audioDurationSeconds)), read-along EPUB \(duration(book.readAloudSync.overlayDurationSeconds))."
    default: return "Audio duration metadata is incomplete."
    }
  }

  private func duration(_ seconds: Double?) -> String {
    guard let seconds, seconds.isFinite, seconds >= 0 else { return "unknown" }
    return AudioPlaybackModel.clock(seconds)
  }
}
