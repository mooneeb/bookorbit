import Foundation
import Observation

@MainActor @Observable
final class BookAddedAtModel: Identifiable {
  enum Phase { case loading, editing, saving, uncertain, denied, changed, failed, saved }

  let id = UUID()
  let api: BookOrbitAPI
  let bookID: Int
  let libraryID: Int
  let userID: Int
  private(set) var phase = Phase.loading
  private(set) var currentDate = ""
  private(set) var timeZone = BookAddedAtDate.utc
  private(set) var book: BookDetail?
  private(set) var message: String?
  private(set) var session: UUID?
  private(set) var attemptedDate: String?
  var selectedDate = ""
  private var operation = UUID()
  private var isAttached = true

  init(api: BookOrbitAPI, book: BookDetail, userID: Int) {
    self.api = api
    bookID = book.id
    libraryID = book.libraryId
    self.userID = userID
  }

  var isBusy: Bool { phase == .loading || phase == .saving }
  var canEdit: Bool { isAttached && attemptedDate == nil && phase == .editing }
  var canRetry: Bool { isAttached && attemptedDate != nil && phase == .uncertain }
  var canSave: Bool {
    canEdit && selectedDate != currentDate && validationMessage == nil
  }
  var validationMessage: String? {
    guard !selectedDate.isEmpty else { return "An added date is required." }
    guard BookAddedAtDate.isValid(selectedDate) else {
      return "Enter a real date in YYYY-MM-DD format."
    }
    if selectedDate > BookAddedAtDate.key(Date(), timeZone: timeZone) {
      return "The added date cannot be in the future."
    }
    return nil
  }
  var pickerDate: Date {
    BookAddedAtDate.pickerDate(selectedDate)
      ?? BookAddedAtDate.pickerDate(BookAddedAtDate.key(Date(), timeZone: timeZone)) ?? Date()
  }
  var pickerMaximum: Date {
    BookAddedAtDate.pickerDate(BookAddedAtDate.key(Date(), timeZone: timeZone)) ?? Date()
  }

  func select(_ date: Date) {
    guard canEdit else { return }
    selectedDate = BookAddedAtDate.key(date, timeZone: BookAddedAtDate.utc)
    message = nil
  }

  func prepare() async {
    guard isAttached, attemptedDate == nil else { return }
    let operation = begin(.loading)
    do {
      if session == nil { session = try await api.authenticatedSessionGeneration() }
      guard let session else { throw ConnectionError.expiredSession }
      let (current, zone) = try await checkedCurrent(session: session)
      guard await accepts(operation) else { return }
      try useCurrent(current, timeZone: zone)
      if selectedDate.isEmpty { selectedDate = currentDate }
      phase = .editing
    } catch { await fail(error, operation: operation) }
  }

  func save() async {
    guard canSave || canRetry, let session else { return }
    let date = attemptedDate ?? selectedDate
    let operation = begin(.saving)
    do {
      let (current, zone) = try await checkedCurrent(session: session)
      guard await accepts(operation) else { return }
      if zone != timeZone {
        try useCurrent(current, timeZone: zone)
        phase = attemptedDate == nil ? .editing : .uncertain
        message = "Your account's time zone changed. Review the date and save again."
        return
      }
      try useCurrent(current, timeZone: zone)
      if attemptedDate != nil, currentDate == date {
        phase = .saved
        return
      }
      guard BookAddedAtDate.isValid(date), date <= BookAddedAtDate.key(Date(), timeZone: zone)
      else {
        phase = attemptedDate == nil ? .editing : .uncertain
        message = "The selected date is no longer valid. Close this editor and reopen it."
        return
      }
      try Task.checkCancellation()
      attemptedDate = date
      let saved: BookDetail = try await api.boundedJSON(
        "books/\(bookID)/added-at", method: "PATCH",
        body: JSONEncoder().encode(BookAddedAtUpdatePayload(addedAt: date)),
        session: session, expectedStatus: 200)
      guard await accepts(operation) else { return }
      try validate(saved, date: date, timeZone: zone)
      let (readback, readbackZone) = try await checkedCurrent(session: session)
      guard await accepts(operation) else { return }
      try validate(readback, date: date, timeZone: readbackZone)
      try useCurrent(readback, timeZone: readbackZone)
      phase = .saved
    } catch { await fail(error, operation: operation) }
  }

  func checkSavedDate() async {
    guard canRetry, let attemptedDate, let session else { return }
    let operation = begin(.loading)
    do {
      let (current, zone) = try await checkedCurrent(session: session)
      guard await accepts(operation) else { return }
      try useCurrent(current, timeZone: zone)
      if currentDate == attemptedDate {
        phase = .saved
      } else {
        phase = .uncertain
        message =
          "The current added date is \(currentDate). Your selected date \(attemptedDate) is not confirmed. Retry sends that same selected date."
      }
    } catch { await fail(error, operation: operation) }
  }

  func belongsToCurrentSession() async -> Bool {
    guard isAttached, let session else { return false }
    let current = try? await api.authenticatedSessionGeneration()
    return isAttached && current == session
  }

  func detach() {
    isAttached = false
    operation = UUID()
    book = nil
    selectedDate = ""
    currentDate = ""
    message = nil
  }

  private func checkedCurrent(session: UUID) async throws -> (BookDetail, TimeZone) {
    let user: AuthUser = try await api.boundedJSON("auth/me", session: session, expectedStatus: 200)
    guard user.id == userID else { throw ConnectionError.expiredSession }
    guard user.hasPermission(.libraryEditMetadata) else { throw ConnectionError.denied }
    let current: BookDetail = try await api.boundedJSON(
      "books/\(bookID)", session: session, expectedStatus: 200)
    guard current.id == bookID else { throw ConnectionError.invalidResponse }
    guard current.libraryId == libraryID else { throw AddedAtContextChanged() }
    return (current, BookAddedAtDate.timeZone(user.settings.timezone))
  }

  private func useCurrent(_ current: BookDetail, timeZone: TimeZone) throws {
    guard current.id == bookID, current.libraryId == libraryID,
      let date = BookAddedAtDate.key(current.addedAt, timeZone: timeZone)
    else { throw ConnectionError.invalidResponse }
    book = current
    currentDate = date
    self.timeZone = timeZone
  }

  private func validate(_ current: BookDetail, date: String, timeZone: TimeZone) throws {
    guard current.id == bookID else { throw ConnectionError.invalidResponse }
    guard current.libraryId == libraryID else { throw AddedAtContextChanged() }
    guard BookAddedAtDate.key(current.addedAt, timeZone: timeZone) == date else {
      throw ConnectionError.invalidResponse
    }
  }

  private func begin(_ phase: Phase) -> UUID {
    let operation = UUID()
    self.operation = operation
    self.phase = phase
    message = nil
    return operation
  }

  private func accepts(_ operation: UUID) async -> Bool {
    guard isAttached, self.operation == operation else { return false }
    guard let session, (try? await api.authenticatedSessionGeneration()) == session else {
      detach()
      phase = .denied
      message = "Your session changed. Close this editor and sign in again."
      return false
    }
    return isAttached && self.operation == operation
  }

  private func fail(_ error: any Error, operation: UUID) async {
    guard await accepts(operation) else { return }
    if error is AddedAtContextChanged {
      book = nil
      phase = .changed
      message = "This book changed libraries. Close this editor and reload the book."
    } else if case ConnectionError.denied = error {
      book = nil
      phase = .denied
      message = "Your account cannot edit metadata for this book."
    } else if case ConnectionError.http(404) = error {
      book = nil
      phase = .denied
      message = "This book is no longer available to your account."
    } else {
      phase = attemptedDate == nil ? .failed : .uncertain
      message =
        attemptedDate == nil
        ? "Could not load the added date. \(error.localizedDescription)"
        : "The added date could not be confirmed. The server may have saved it. Your selected date is kept. \(error.localizedDescription)"
    }
  }
}

private struct AddedAtContextChanged: Error {}
