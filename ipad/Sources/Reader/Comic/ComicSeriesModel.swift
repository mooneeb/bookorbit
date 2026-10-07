import Foundation
import Observation

struct ComicReaderTarget: Sendable {
  let bookID: Int
  let file: BookDetailFile
  let title: String
}

@MainActor @Observable
final class ComicSeriesModel {
  let api: BookOrbitAPI
  let bookID: Int
  private(set) var next: SeriesNextBook?
  private(set) var isLoading = false
  private(set) var isOpening = false
  private(set) var hasLoaded = false
  private(set) var error: String?
  private var session: UUID?
  private var isClosed = false

  init(api: BookOrbitAPI, bookID: Int) {
    self.api = api
    self.bookID = bookID
  }

  func load() async {
    guard !isClosed, !isLoading, !hasLoaded else { return }
    isLoading = true
    error = nil
    defer { isLoading = false }
    do {
      let session = try await api.authenticatedSessionGeneration()
      self.session = session
      let book: BookDetail = try await api.boundedJSON("books/\(bookID)", session: session)
      try Task.checkCancellation()
      guard !isClosed, book.id == bookID else { throw ConnectionError.invalidResponse }
      if let seriesID = book.seriesId {
        guard seriesID > 0 else { throw ConnectionError.invalidResponse }
        let response: SeriesNextBookResponse = try await api.boundedJSON(
          "series/\(seriesID)/books/\(bookID)/next",
          query: [URLQueryItem(name: "formatGroup", value: "cbx")], session: session)
        try Task.checkCancellation()
        guard !isClosed else { return }
        if let next = response.next {
          guard next.bookId > 0, next.bookId != bookID, next.fileId > 0,
            ["cbz", "cbr", "cb7"].contains(next.format.lowercased())
          else { throw ConnectionError.invalidResponse }
        }
        next = response.next
      } else {
        next = nil
      }
      hasLoaded = true
    } catch is CancellationError {
    } catch {
      if !isClosed { self.error = error.localizedDescription }
    }
  }

  func target() async -> ComicReaderTarget? {
    guard !isClosed, !isOpening, let next, let session else { return nil }
    isOpening = true
    error = nil
    defer { isOpening = false }
    do {
      let book: BookDetail = try await api.boundedJSON("books/\(next.bookId)", session: session)
      try Task.checkCancellation()
      guard !isClosed, book.id == next.bookId,
        let file = book.files.first(where: { $0.id == next.fileId }),
        file.format?.lowercased() == next.format.lowercased(),
        ["cbz", "cbr", "cb7"].contains(file.format?.lowercased() ?? "")
      else { throw ConnectionError.fileChanged }
      return ComicReaderTarget(bookID: book.id, file: file, title: book.title ?? "Comic reader")
    } catch {
      if !isClosed { self.error = error.localizedDescription }
      return nil
    }
  }

  func close() { isClosed = true }
}
