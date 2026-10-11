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
  private(set) var canRate = false
  private(set) var hasPending = false
  private(set) var recoveryReason: String?
  private(set) var message: String?
  private(set) var error: String?
  @ObservationIgnored private var outbox: NativePersonalReadingOutbox?

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
      let store = try await NativePersonalReadingOutbox.open(api: api)
      outbox = store
      let user: AuthUser = try await api.boundedJSON("auth/me")
      try Task.checkCancellation()
      canRate = true
      let zone =
        TimeZone(identifier: user.settings.timezone ?? "UTC") ?? TimeZone(secondsFromGMT: 0)!
      if let saved = store.draft(bookID: book.id) {
        book = saved.book
        let restored = BookReadingDraft(
          book: saved.book, timeZone: TimeZone(identifier: saved.timeZone) ?? zone)
        restored.status = saved.status
        restored.started = saved.started
        restored.finished = saved.finished
        restored.note = saved.note
        restored.rating = saved.rating
        draft = restored
      } else {
        draft = BookReadingDraft(book: book, timeZone: zone)
      }
      hasPending = store.hasPending(bookID: book.id)
      recoveryReason = store.recoveryReason(bookID: book.id)
      if hasPending {
        message =
          "Your local reading record is kept on this iPad until it is confirmed by the server."
      }
    } catch {
      if !Task.isCancelled { self.error = error.localizedDescription }
    }
  }

  func preserveDraft() {
    guard let draft, let outbox else { return }
    do { try outbox.preserve(book: book, draft: draft) } catch {
      self.error = "Your draft could not be saved on this iPad. \(error.localizedDescription)"
    }
  }

  func save() async {
    guard let draft, let outbox, draft.validationError == nil, !isSaving,
      draft.hasChanges || hasPending
    else { return }
    if draft.ratingChanged, !canRate {
      error = ConnectionError.denied.localizedDescription
      return
    }
    isSaving = true
    error = nil
    isComplete = false
    defer { isSaving = false }
    do {
      try outbox.enqueue(book: book, draft: draft)
      hasPending = true
      try await NativePersonalReadingOutbox.flush(api: api)
      recoveryReason = outbox.recoveryReason(bookID: book.id)
      hasPending = outbox.hasPending(bookID: book.id)
      guard !hasPending else {
        error = recoveryReason ?? "Your changes are saved on this iPad and waiting for the server."
        return
      }
      let saved: BookDetail = try await api.boundedJSON(
        "books/\(book.id)", byteLimit: 2 * 1024 * 1024)
      guard saved.id == book.id else { throw ConnectionError.invalidResponse }
      book = saved
      if let status = saved.readStatus { draft.acknowledgeStatus(status) }
      draft.acknowledgeNote(saved.personalNote)
      draft.acknowledgeRating(saved.rating)
      isComplete = true
      message = "Your reading record is synchronized."
    } catch {
      hasPending = outbox.hasPending(bookID: book.id)
      recoveryReason = outbox.recoveryReason(bookID: book.id)
      self.error =
        outbox.draft(bookID: book.id) != nil || hasPending
        ? "Your changes are kept on this iPad. Retry when connected. \(error.localizedDescription)"
        : "Your changes could not be saved on this iPad. \(error.localizedDescription)"
    }
  }

  func retry() async { await save() }

  func reviewCurrentRecord() async {
    guard let outbox, !isSaving else { return }
    isSaving = true
    defer { isSaving = false }
    do {
      let current: BookDetail = try await api.boundedJSON(
        "books/\(book.id)", byteLimit: 2 * 1024 * 1024)
      guard let draft else { return }
      let local = (draft.status, draft.started, draft.finished, draft.note, draft.rating)
      try outbox.keepDraftOnly(bookID: book.id)
      book = current
      let reviewed = BookReadingDraft(book: current, timeZone: draft.timeZone)
      reviewed.status = local.0
      reviewed.started = local.1
      reviewed.finished = local.2
      reviewed.note = local.3
      reviewed.rating = local.4
      self.draft = reviewed
      recoveryReason = nil
      hasPending = false
      message =
        "The current server record is loaded. Your local version stays in the editor. Save explicitly to use it."
      preserveDraft()
    } catch { self.error = error.localizedDescription }
  }
}
