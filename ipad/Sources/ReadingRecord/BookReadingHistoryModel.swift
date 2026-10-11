import Foundation
import Observation

@MainActor @Observable
final class BookReadingHistoryModel {
  let api: BookOrbitAPI
  let book: BookDetail
  private(set) var sessions: BookReadingSessionListResponse?
  private(set) var attempts: ReadingAttemptListResponse?
  private(set) var isLoading = false
  private(set) var isSaving = false
  private(set) var canDelete = false
  private(set) var error: String?
  private(set) var message: String?
  private(set) var timeZone = TimeZone(secondsFromGMT: 0)!
  var page = 1
  var attemptPage = 1
  var format = ""
  var sortBy = "startedAt"
  var sortDir = "desc"
  var dateFrom = ""
  var dateTo = ""
  var manualStarted = Date().addingTimeInterval(-300)
  var manualMinutes = 5
  var manualProgress = ""
  var manualFormat = ""
  var historicalStarted = ""
  var historicalFinished = ""
  var historicalOutcome = "completed"
  var editingAttempt: ReadingAttempt?
  private var historyDraftID = UUID()
  private var loadedHistoryDraft = false
  private(set) var hasHistoryDraft = false
  private(set) var historyHasPending = false

  var historyDraft: NativeReadingAttemptDraft {
    NativeReadingAttemptDraft(
      id: historyDraftID, bookID: book.id, title: book.title ?? "Book \(book.id)",
      baseline: editingAttempt,
      started: historicalStarted, finished: historicalFinished, outcome: historicalOutcome,
      timeZone: timeZone.identifier)
  }

  init(api: BookOrbitAPI, book: BookDetail) {
    self.api = api
    self.book = book
  }

  var formats: [String] { Array(Set(book.files.compactMap(\.format))).sorted() }
  var manualValidation: String? {
    guard manualStarted <= Date() else { return "A session cannot start in the future." }
    guard (1...1440).contains(manualMinutes) else { return "Enter between 1 and 1,440 minutes." }
    if !manualProgress.isEmpty {
      guard let progress = Double(manualProgress), progress.isFinite, (0...100).contains(progress)
      else { return "End progress must be between zero and 100 percent." }
    }
    return nil
  }
  var historyValidation: String? {
    if editingAttempt == nil && historicalOutcome.isEmpty {
      return "Choose a finished reading outcome."
    }
    let today = ReadingDate.format(Date(), timeZone: timeZone)
    for value in [historicalStarted, historicalFinished] where !value.isEmpty {
      guard ReadingDate.isValid(value) else { return "Enter real dates in YYYY-MM-DD format." }
      guard value <= today else {
        return "Reading dates cannot be in the future in your account's time zone."
      }
    }
    if !historicalStarted.isEmpty, !historicalFinished.isEmpty,
      historicalFinished < historicalStarted
    {
      return "The finished date cannot be before the started date."
    }
    return nil
  }

  func load() async {
    guard !isLoading else { return }
    isLoading = true
    error = nil
    defer { isLoading = false }
    do {
      if let saved = try? await api.authenticatedUser() {
        canDelete = saved.hasPermission(.annotationManageOwn)
        timeZone =
          TimeZone(identifier: saved.settings.timezone ?? "UTC") ?? TimeZone(secondsFromGMT: 0)!
      }
      try await restoreHistoryDraft()
      let user: AuthUser = try await api.boundedJSON("auth/me")
      canDelete = user.hasPermission(.annotationManageOwn)
      timeZone =
        TimeZone(identifier: user.settings.timezone ?? "UTC") ?? TimeZone(secondsFromGMT: 0)!
      var query = [
        URLQueryItem(name: "page", value: String(page)),
        URLQueryItem(name: "pageSize", value: "25"),
        URLQueryItem(name: "sortBy", value: sortBy), URLQueryItem(name: "sortDir", value: sortDir),
      ]
      if !format.isEmpty { query.append(URLQueryItem(name: "format", value: format)) }
      for (key, value) in [("dateFrom", dateFrom), ("dateTo", dateTo)] where !value.isEmpty {
        guard ReadingDate.isValid(value) else { throw ConnectionError.invalidResponse }
        query.append(URLQueryItem(name: key, value: value))
      }
      sessions = try await api.boundedJSON("books/\(book.id)/sessions", query: query)
      attempts = try await api.boundedJSON(
        "books/\(book.id)/reading-attempts",
        query: [
          URLQueryItem(name: "page", value: String(attemptPage)),
          URLQueryItem(name: "pageSize", value: "25"),
        ])
    } catch { self.error = error.localizedDescription }
  }

  func createManual() async {
    guard manualValidation == nil, !isSaving else { return }
    isSaving = true
    error = nil
    var queued = false
    defer { isSaving = false }
    do {
      let formatter = ISO8601DateFormatter()
      var payload = CreateManualReadingSessionPayload(
        startedAt: formatter.string(from: manualStarted), durationMinutes: Double(manualMinutes))
      payload.clientId = UUID().uuidString
      payload.endProgress = Double(manualProgress)
      payload.format = manualFormat.isEmpty ? nil : manualFormat
      let store = try await NativePersonalReadingOutbox.open(api: api)
      try store.enqueueManual(bookID: book.id, payload: payload)
      queued = true
      message = "Manual session saved on this iPad."
      try await NativePersonalReadingOutbox.flush(api: api)
      guard !store.hasPending(bookID: book.id) else {
        error =
          store.recoveryReason(bookID: book.id)
          ?? "The session is waiting for confirmation from the server."
        return
      }
      message = "Manual session synchronized."
      page = 1
      await load()
    } catch {
      self.error =
        queued
        ? "The session is kept on this iPad for retry. \(error.localizedDescription)"
        : "The session could not be saved on this iPad. \(error.localizedDescription)"
    }
  }

  func retryPending() async {
    guard !isSaving else { return }
    isSaving = true
    defer { isSaving = false }
    do {
      try await NativeReadingActivityCoordinator.flush(api: api)
      let store = try await NativePersonalReadingOutbox.open(api: api)
      let history = try await NativeReadingAttemptOutbox.open(api: api)
      historyHasPending = history.hasPending(bookID: book.id)
      if !historyHasPending { hasHistoryDraft = history.draft(bookID: book.id) != nil }
      message =
        store.hasPending(bookID: book.id) || historyHasPending
        ? (history.recoveryReason(bookID: book.id) ?? store.recoveryReason(bookID: book.id)
          ?? "Reading records are still waiting for confirmation.")
        : "Pending reading records synchronized."
      await load()
    } catch { self.error = error.localizedDescription }
  }

  func deleteSession(_ session: BookReadingSession) async {
    guard canDelete, !isSaving else { return }
    isSaving = true
    defer { isSaving = false }
    do {
      try await api.sendEmpty(
        "books/\(book.id)/sessions/\(session.id)", method: "DELETE", expectedStatus: 204)
      message = "Session deleted. A delayed checkpoint cannot restore it."
      await load()
    } catch { self.error = error.localizedDescription }
  }

  func edit(_ attempt: ReadingAttempt) -> Bool {
    guard !historyHasPending, !hasHistoryDraft || editingAttempt?.id == attempt.id else {
      error =
        "A local history draft is kept. Continue it, retry its save, or review its recovery version first."
      return false
    }
    if hasHistoryDraft { return true }
    historyDraftID = UUID()
    editingAttempt = attempt
    historicalStarted = attempt.startedOn ?? ""
    historicalFinished = attempt.endedOn ?? ""
    historicalOutcome = attempt.outcome ?? ""
    hasHistoryDraft = true
    return true
  }

  func beginHistory() {
    guard !hasHistoryDraft else { return }
    historyDraftID = UUID()
    editingAttempt = nil
    historicalStarted = ""
    historicalFinished = ""
    historicalOutcome = "completed"
    hasHistoryDraft = true
  }

  func preserveHistoryDraft() async {
    guard hasHistoryDraft, !historyHasPending else { return }
    do {
      try await NativeReadingAttemptOutbox.open(api: api).preserve(historyDraft)
    } catch {
      self.error =
        "The history draft could not be saved on this iPad. \(error.localizedDescription)"
    }
  }

  private func restoreHistoryDraft() async throws {
    let store = try await NativeReadingAttemptOutbox.open(api: api)
    let wasPending = historyHasPending
    historyHasPending = store.hasPending(bookID: book.id)
    if wasPending, !historyHasPending, store.draft(bookID: book.id) == nil {
      hasHistoryDraft = false
      historyDraftID = UUID()
      editingAttempt = nil
    }
    guard !loadedHistoryDraft else { return }
    loadedHistoryDraft = true
    guard let draft = store.draft(bookID: book.id) else { return }
    historyDraftID = draft.id
    editingAttempt = draft.baseline
    historicalStarted = draft.started
    historicalFinished = draft.finished
    historicalOutcome = draft.outcome
    timeZone = TimeZone(identifier: draft.timeZone) ?? TimeZone(secondsFromGMT: 0)!
    hasHistoryDraft = true
    message =
      historyHasPending
      ? "Reading history is saved on this iPad and waiting for confirmation."
      : "Your local history draft was restored."
  }

  func saveHistory() async {
    guard historyValidation == nil, !isSaving, !historyHasPending else { return }
    isSaving = true
    error = nil
    var queued = false
    defer { isSaving = false }
    do {
      let store = try await NativeReadingAttemptOutbox.open(api: api)
      try store.enqueue(historyDraft)
      queued = true
      historyHasPending = true
      message = "Reading history saved on this iPad."
      try await NativeReadingAttemptOutbox.flush(api: api)
      historyHasPending = store.hasPending(bookID: book.id)
      guard !historyHasPending else {
        error =
          store.recoveryReason(bookID: book.id)
          ?? "Reading history is waiting for server confirmation."
        return
      }
      hasHistoryDraft = false
      editingAttempt = nil
      message = "Reading history synchronized."
      await load()
    } catch {
      self.error =
        queued
        ? "Reading history is kept on this iPad for retry. \(error.localizedDescription)"
        : "Reading history could not be saved on this iPad. \(error.localizedDescription)"
    }
  }

  func startReread(resetProgress: Bool) async {
    guard !isSaving else { return }
    isSaving = true
    defer { isSaving = false }
    do {
      let _: UserBookStatus = try await api.boundedJSON(
        "books/\(book.id)/reading-attempts/start-reread",
        method: "POST", body: JSONEncoder().encode(StartRereadPayload(resetProgress: resetProgress))
      )
      message = "A new reading attempt has started."
      await load()
    } catch { self.error = error.localizedDescription }
  }

  func deleteAttempt(_ attempt: ReadingAttempt) async {
    guard canDelete, !isSaving else { return }
    isSaving = true
    defer { isSaving = false }
    do {
      try await api.sendEmpty(
        "books/\(book.id)/reading-attempts/\(attempt.id)", method: "DELETE", expectedStatus: 204)
      await load()
    } catch { self.error = error.localizedDescription }
  }
}
