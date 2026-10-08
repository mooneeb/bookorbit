import Foundation
import Observation

@MainActor @Observable
final class BookReadingModel {
  let api: BookOrbitAPI
  private(set) var book: BookDetail
  private(set) var draft: BookReadingDraft?
  private(set) var isLoading = false
  private(set) var isSaving = false
  private(set) var isComplete = false
  private(set) var error: String?
  private var didSaveStatus = false

  init(api: BookOrbitAPI, book: BookDetail) {
    self.api = api
    self.book = book
  }

  func load() async {
    guard draft == nil, !isLoading else { return }
    isLoading = true
    error = nil
    defer { isLoading = false }
    do {
      let user: UserReaderSettingsResponse = try await api.boundedJSON("auth/me")
      try Task.checkCancellation()
      let zone =
        TimeZone(identifier: user.settings.timezone ?? "UTC") ?? TimeZone(secondsFromGMT: 0)!
      draft = BookReadingDraft(book: book, timeZone: zone)
    } catch {
      if !Task.isCancelled { self.error = error.localizedDescription }
    }
  }

  func save() async {
    guard let draft, draft.hasChanges, draft.validationError == nil, !isSaving else { return }
    isSaving = true
    error = nil
    if draft.statusPayload != nil { didSaveStatus = false }
    defer { isSaving = false }
    do {
      if let payload = draft.statusPayload {
        let saved: UserBookStatus = try await api.boundedJSON(
          "books/\(book.id)/status", method: "PATCH", body: JSONEncoder().encode(payload))
        guard BookReadingVocabulary.statuses.contains(saved.status) else {
          throw ConnectionError.invalidResponse
        }
        book.readStatus = saved
        draft.acknowledgeStatus(saved)
        didSaveStatus = true
      }
      if draft.noteChanged {
        let saved: BookDetail = try await api.boundedJSON(
          "books/\(book.id)/personal-note", method: "PATCH",
          body: JSONEncoder().encode(draft.notePayload))
        guard saved.id == book.id else { throw ConnectionError.invalidResponse }
        book = saved
        draft.acknowledgeNote(saved.personalNote)
        if let status = saved.readStatus { draft.acknowledgeStatus(status) }
      }
      isComplete = true
    } catch {
      self.error =
        didSaveStatus
        ? "Reading status and dates saved. Your note could not be confirmed. Your draft is kept. \(error.localizedDescription)"
        : "Your changes could not be confirmed. Your draft is kept. \(error.localizedDescription)"
    }
  }
}
