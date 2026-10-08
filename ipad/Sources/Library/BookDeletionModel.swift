import Foundation
import Observation

enum BookDeletionOutcome: Equatable {
  case deleted, unavailable

  var message: String {
    switch self {
    case .deleted: "Book deleted."
    case .unavailable: "This book is no longer available to your account."
    }
  }
}

@MainActor @Observable
final class BookDeletionModel: Identifiable {
  enum Phase: Equatable {
    case checking, confirmation, deleting, uncertain, denied, failed, resolved
  }

  let id = UUID()
  let api: BookOrbitAPI
  let bookID: Int
  let userID: Int
  private(set) var book: BookDetail?
  private(set) var phase = Phase.checking
  private(set) var message: String?
  private(set) var outcome: BookDeletionOutcome?
  private(set) var didAttemptDeletion = false
  private(set) var session: UUID?
  private var operation = UUID()
  private var isAttached = true

  init(api: BookOrbitAPI, bookID: Int, userID: Int) {
    self.api = api
    self.bookID = bookID
    self.userID = userID
  }

  var isBusy: Bool { phase == .checking || phase == .deleting }
  var canConfirm: Bool { phase == .confirmation && book != nil }
  var canReload: Bool { isAttached && !isBusy && outcome == nil }

  func prepare() async {
    guard isAttached, !didAttemptDeletion else { return }
    do {
      if session == nil { session = try await api.authenticatedSessionGeneration() }
      await reload()
    } catch {
      guard isAttached else { return }
      phase = .failed
      message = error.localizedDescription
    }
  }

  func confirm() async {
    guard isAttached, canConfirm, let session else { return }
    let operation = UUID()
    self.operation = operation
    phase = .deleting
    message = nil
    do {
      try Task.checkCancellation()
      guard try await api.authenticatedSessionGeneration() == session else {
        throw ConnectionError.expiredSession
      }
      didAttemptDeletion = true
      try await api.deleteBook(bookID, session: session)
      guard await accepts(operation, session: session) else { return }
      resolve(.deleted)
    } catch {
      guard await accepts(operation, session: session) else { return }
      if case ConnectionError.http(404) = error {
        phase = .uncertain
        await reload()
      } else if case ConnectionError.denied = error {
        book = nil
        phase = .denied
        message = "Your account cannot delete this book. Reload to check its current availability."
      } else {
        phase = .uncertain
        message =
          "The deletion could not be confirmed. The server may have completed it. Reload the book's status before trying again."
      }
    }
  }

  func reload() async {
    guard isAttached, phase != .deleting, let session else { return }
    let operation = UUID()
    self.operation = operation
    phase = .checking
    message = nil
    do {
      let user: AuthUser = try await api.boundedJSON("auth/me", session: session)
      guard await accepts(operation, session: session) else { return }
      guard user.id == userID else {
        invalidateSession()
        return
      }
      guard user.hasPermission(.libraryDeleteBooks) else {
        phase = .denied
        book = nil
        message = "Your account does not have permission to delete books."
        return
      }
      let book: BookDetail = try await api.boundedJSON("books/\(bookID)", session: session)
      guard await accepts(operation, session: session) else { return }
      guard book.id == bookID else { throw ConnectionError.invalidResponse }
      self.book = book
      phase = .confirmation
      if didAttemptDeletion {
        message =
          "The book is currently available. The earlier request was not confirmed and may still be finishing. A new confirmation deletes this same book."
      }
    } catch {
      guard await accepts(operation, session: session) else { return }
      if case ConnectionError.http(404) = error {
        resolve(.unavailable)
      } else if case ConnectionError.denied = error {
        resolve(.unavailable)
      } else {
        phase = didAttemptDeletion ? .uncertain : .failed
        message =
          didAttemptDeletion
          ? "The deletion outcome is still unknown. Reload when connected. \(error.localizedDescription)"
          : "Could not check this book. \(error.localizedDescription)"
      }
    }
  }

  func belongsToCurrentSession() async -> Bool {
    guard let session else { return false }
    return (try? await api.authenticatedSessionGeneration()) == session
  }

  func detach() {
    isAttached = false
    operation = UUID()
    book = nil
    message = nil
  }

  private func accepts(_ operation: UUID, session: UUID) async -> Bool {
    guard isAttached, self.operation == operation else { return false }
    guard (try? await api.authenticatedSessionGeneration()) == session else {
      invalidateSession()
      return false
    }
    return isAttached && self.operation == operation
  }

  private func invalidateSession() {
    detach()
    phase = .denied
    message = "Your session changed. Close this dialog and sign in again to check the book."
  }

  private func resolve(_ outcome: BookDeletionOutcome) {
    book = nil
    phase = .resolved
    self.outcome = outcome
    message = outcome.message
  }
}
