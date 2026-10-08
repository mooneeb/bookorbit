import Foundation
import Observation

@MainActor @Observable
final class BookWriteAndRenameModel {
  enum Phase: Equatable {
    case checking, review, writing, readingBack, finished, uncertain, denied, failed
  }

  let api: BookOrbitAPI
  let bookID: Int
  let session: UUID
  private(set) var book: BookDetail?
  private(set) var result: BookWriteAndRenameResult?
  private(set) var phase = Phase.checking
  private(set) var message: String?
  private(set) var didAttemptWrite = false
  private(set) var hasUnconfirmedWrite = false
  private(set) var isDeliberateRepeat = false
  private(set) var didReadBack = false
  private(set) var canEditMetadata = false
  private var userID: Int?
  private var operation = UUID()
  private var isAttached = true
  private var execution: Task<Void, Never>?
  private let willWrite: (UUID) -> Void
  private let readBack: (BookDetail, UUID) -> Void

  init(
    api: BookOrbitAPI, bookID: Int, session: UUID,
    willWrite: @escaping (UUID) -> Void,
    readBack: @escaping (BookDetail, UUID) -> Void
  ) {
    self.api = api
    self.bookID = bookID
    self.session = session
    self.willWrite = willWrite
    self.readBack = readBack
  }

  var isBusy: Bool { [.checking, .writing, .readingBack].contains(phase) }
  var canConfirm: Bool {
    isAttached && canEditMetadata && phase == .review && book != nil && execution == nil
  }
  var canReload: Bool { isAttached && !isBusy && execution == nil }
  var canReviewAgain: Bool {
    canReload && phase != .review && canEditMetadata && book != nil
      && (didAttemptWrite || result != nil || hasUnconfirmedWrite)
  }

  func inspectStatus(current: BookDetail) async {
    guard isAttached, !didAttemptWrite, result == nil, execution == nil, current.id == bookID else {
      return
    }
    let operation = beginChecking()
    do {
      let unconfirmed = try await api.bookFileWriteIsUnconfirmed(bookID, session: session)
      guard await accepts(operation) else { return }
      book = current
      hasUnconfirmedWrite = unconfirmed
      phase = unconfirmed ? .uncertain : .review
      message = unconfirmed ? uncertaintyMessage : nil
    } catch { await fail(error, operation: operation) }
  }

  func prepare() async {
    guard isAttached, execution == nil else { return }
    if result != nil || didAttemptWrite || hasUnconfirmedWrite {
      await reload()
    } else {
      await checkForReview(deliberateRepeat: false)
    }
  }

  func reviewAgain() async {
    guard canReviewAgain else { return }
    await checkForReview(deliberateRepeat: hasUnconfirmedWrite)
  }

  private func checkForReview(deliberateRepeat: Bool) async {
    let operation = beginChecking()
    do {
      let current = try await checkedBook()
      let unconfirmed = try await api.bookFileWriteIsUnconfirmed(bookID, session: session)
      guard await accepts(operation) else { return }
      book = current
      hasUnconfirmedWrite = unconfirmed
      isDeliberateRepeat = deliberateRepeat && unconfirmed
      if unconfirmed && !deliberateRepeat {
        phase = .uncertain
        message = uncertaintyMessage
      } else {
        phase = .review
        message = isDeliberateRepeat ? uncertaintyMessage : nil
      }
    } catch { await fail(error, operation: operation) }
  }

  func confirm() {
    guard canConfirm else { return }
    phase = .writing
    execution = Task { [weak self] in
      guard let self else { return }
      await execute()
      execution = nil
    }
  }

  private func execute() async {
    let operation = UUID()
    self.operation = operation
    message = nil
    do {
      let current = try await checkedBook()
      guard await accepts(operation) else { return }
      book = current
      try Task.checkCancellation()
      didAttemptWrite = true
      didReadBack = false
      result = nil
      willWrite(session)
      let response = try await api.writeAndRenameBook(
        bookID, session: session, deliberateRepeat: isDeliberateRepeat)
      guard await accepts(operation) else { return }
      result = response
      hasUnconfirmedWrite = false
      phase = .readingBack
      await refreshAfterAttempt(operation: operation)
    } catch { await fail(error, operation: operation) }
  }

  func reload() async {
    guard canReload || (phase == .checking && execution == nil) else { return }
    let operation = beginChecking()
    await refreshAfterAttempt(operation: operation)
  }

  private func refreshAfterAttempt(operation: UUID) async {
    do {
      let current = try await checkedBook(requirePermission: false)
      let unconfirmed = try await api.bookFileWriteIsUnconfirmed(bookID, session: session)
      guard await accepts(operation) else { return }
      book = current
      hasUnconfirmedWrite = unconfirmed
      didReadBack = true
      readBack(current, session)
      phase = result != nil ? .finished : (unconfirmed ? .uncertain : .review)
      if result != nil && unconfirmed {
        message =
          "The server acknowledged the result below, but this device could not clear its safety marker. A later review will still warn before repeating. Current book details do not verify every source file or every embedded field."
      } else {
        message =
          phase == .uncertain
          ? uncertaintyMessage
          : "Current book details reloaded. They do not verify every source file or every embedded field."
      }
    } catch { await fail(error, operation: operation) }
  }

  func stopWaiting() {
    execution?.cancel()
    if phase == .writing && didAttemptWrite {
      hasUnconfirmedWrite = true
      phase = .uncertain
      message = uncertaintyMessage
    }
  }

  func detach() {
    stopWaiting()
    isAttached = false
    operation = UUID()
    book = nil
    result = nil
  }

  private var uncertaintyMessage: String {
    "An earlier request has no confirmed outcome. It may have changed source files or may still be running. Reloading details does not resolve it. To send another request, review and confirm an explicit repeat of the entire operation."
  }

  private func checkedBook(requirePermission: Bool = true) async throws -> BookDetail {
    try Task.checkCancellation()
    let user: AuthUser = try await api.boundedJSON("auth/me", session: session, expectedStatus: 200)
    if let userID, user.id != userID { throw ConnectionError.expiredSession }
    userID = user.id
    canEditMetadata = user.hasPermission(.libraryEditMetadata)
    if requirePermission && !canEditMetadata { throw ConnectionError.denied }
    let current: BookDetail = try await api.boundedJSON(
      "books/\(bookID)", session: session, expectedStatus: 200)
    guard current.id == bookID else { throw ConnectionError.invalidResponse }
    return current
  }

  private func beginChecking() -> UUID {
    let operation = UUID()
    self.operation = operation
    phase = .checking
    message = nil
    return operation
  }

  private func accepts(_ operation: UUID) async -> Bool {
    guard isAttached, self.operation == operation else { return false }
    guard (try? await api.authenticatedSessionGeneration()) == session else {
      detach()
      phase = .denied
      message =
        "Your session changed. Close this dialog and reopen the book in your current account."
      return false
    }
    return isAttached && self.operation == operation
  }

  private func fail(_ error: any Error, operation: UUID) async {
    guard await accepts(operation) else { return }
    hasUnconfirmedWrite =
      (try? await api.bookFileWriteIsUnconfirmed(bookID, session: session)) ?? didAttemptWrite
    if case ConnectionError.denied = error {
      book = nil
      phase = .denied
      message =
        "This account needs permission to edit metadata and access to this book. Reload to check current access."
    } else if case ConnectionError.http(404) = error {
      book = nil
      phase = .denied
      message = "This book is no longer available to your account."
    } else if result != nil {
      phase = .finished
      message =
        "The server acknowledged the result below. Current file details could not be reloaded. Reload status without sending another write. \(error.localizedDescription)"
    } else {
      phase = hasUnconfirmedWrite ? .uncertain : .failed
      message = hasUnconfirmedWrite ? uncertaintyMessage : error.localizedDescription
    }
  }
}
