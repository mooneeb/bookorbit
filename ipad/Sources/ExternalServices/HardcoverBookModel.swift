import Foundation
import Observation

@MainActor @Observable
final class HardcoverBookModel {
  let api: BookOrbitAPI
  let bookID: Int
  var editionID = ""
  private(set) var state: HardcoverBookSyncState?
  private(set) var editions: HardcoverEditionsResult?
  private(set) var busy = false
  private(set) var error: String?
  private(set) var message: String?

  private static let noMatchMessage =
    "No matching Hardcover book was found. No reading record was sent."

  var lastActivityTitle: String {
    if state?.syncError == "no_match" { return "Last checked (no match)" }
    return state?.syncError == nil ? "Last synced" : "Last checked"
  }

  var syncFeedback: String? {
    guard let syncError = state?.syncError else { return nil }
    return syncError == "no_match" ? Self.noMatchMessage : syncError
  }

  init(api: BookOrbitAPI, bookID: Int) {
    self.api = api
    self.bookID = bookID
  }

  func load() async {
    guard !busy else { return }
    busy = true
    error = nil
    message = nil
    defer { busy = false }
    do {
      state = try await api.hardcoverBookState(bookID)
      try Task.checkCancellation()
    } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
  }

  func changeInclusion() async {
    guard !busy, let state else { return }
    busy = true
    error = nil
    message = nil
    defer { busy = false }
    do {
      self.state = try await api.setHardcoverBookEnabled(bookID, enabled: !state.syncEnabled)
      message = "Book selection confirmed. Refresh to check any resulting sync."
    } catch { self.error = "Book selection could not be confirmed. \(error.localizedDescription)" }
  }

  func sync() async {
    guard !busy else { return }
    busy = true
    error = nil
    message = nil
    defer { busy = false }
    do {
      let result = try await api.syncHardcoverBook(bookID)
      state = result.state
      switch result.result {
      case "synced": message = "Reading record confirmed by Hardcover."
      case "skipped":
        message =
          result.state.syncError == "no_match"
          ? Self.noMatchMessage
          : "No new record was sent. Review this book's eligibility, mapping and last sync check."
      default:
        error =
          result.state.syncError
          ?? "Hardcover did not confirm this record. Check your token and connection, then retry."
      }
    } catch {
      self.error =
        "Reading record could not be confirmed. Refresh before retrying. \(error.localizedDescription)"
    }
  }

  func loadEditions() async {
    guard !busy else { return }
    busy = true
    error = nil
    defer { busy = false }
    do { editions = try await api.hardcoverEditions(bookID) } catch {
      self.error =
        "Editions unavailable. Sync this book to resolve its Hardcover match first. \(error.localizedDescription)"
    }
  }

  func selectEdition(_ value: Int) async {
    guard !busy, value > 0 else { return }
    busy = true
    error = nil
    message = nil
    defer { busy = false }
    do {
      let result = try await api.setHardcoverEdition(bookID, editionID: value)
      guard result.success else { throw ConnectionError.invalidResponse }
      state = try await api.hardcoverBookState(bookID)
      message = "Edition \(value) selected."
      if let syncError = state?.syncError {
        error = "Edition selected, but sync was not confirmed: \(syncError)"
      }
    } catch {
      self.error =
        "Edition selection could not be confirmed. Refresh before retrying. \(error.localizedDescription)"
    }
  }
}
