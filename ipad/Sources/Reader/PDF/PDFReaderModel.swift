import Foundation
import Observation
import PDFKit

@MainActor @Observable
final class PDFReaderModel {
  let api: BookOrbitAPI
  let file: BookDetailFile
  private(set) var document: PDFDocument?
  private(set) var pageIndex = 0
  private(set) var searchSelection: PDFSelection?
  private(set) var status = ""
  private(set) var error: String?
  private(set) var isClosing = false
  var hasUnsavedPosition: Bool { pendingPage != nil && saveTask == nil }
  private var localFile: URL?
  private var pendingPage: Int?
  private var saveTask: Task<Void, Never>?
  private var isClosed = false
  private var isLoading = false

  init(api: BookOrbitAPI, file: BookDetailFile) {
    self.api = api
    self.file = file
  }

  func load() async {
    guard document == nil, !isLoading, !isClosed else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      let progress: FileReadingProgress = try await api.send("books/files/\(file.id)/progress")
      guard let size = file.sizeBytes else { throw ConnectionError.invalidResponse }
      let url = try await api.deliveredFile(
        fileID: file.id, expectedSize: size, mimeType: "application/pdf")
      if isClosed || Task.isCancelled {
        try? FileManager.default.removeItem(at: url)
        return
      }
      localFile = url
      guard let pdf = PDFDocument(url: url), pdf.pageCount > 0 else {
        throw ConnectionError.invalidResponse
      }
      if let page = progress.pageNumber, page.isFinite, page >= 1, page <= Double(pdf.pageCount) {
        pageIndex = Int(page.rounded(.down)) - 1
      }
      document = pdf
    } catch is CancellationError {
      removeLocalFile()
    } catch {
      self.error = error.localizedDescription
      removeLocalFile()
    }
  }

  func didTurn(to index: Int) {
    guard !isClosed, !isClosing, let document, (0..<document.pageCount).contains(index),
      index != pageIndex
    else {
      return
    }
    pageIndex = index
    searchSelection = nil
    pendingPage = index + 1
    status = "Saving position…"
    if saveTask == nil { saveTask = Task { await savePendingPosition() } }
  }

  func openSearchMatch(_ match: PDFSearchMatch) {
    guard !isClosed, !isClosing, let document, let page = document.page(at: match.pageIndex)
    else { return }
    didTurn(to: match.pageIndex)
    let selection = PDFSelection(document: document)
    for range in match.ranges {
      if let part = page.selection(for: range) { selection.add(part) }
    }
    searchSelection = selection
  }

  func openContentsPage(_ index: Int) {
    guard !isClosed, !isClosing, let document, (0..<document.pageCount).contains(index)
    else { return }
    searchSelection = nil
    didTurn(to: index)
  }

  private func savePendingPosition() async {
    defer { saveTask = nil }
    while let page = pendingPage, !isClosed, !Task.isCancelled, let document {
      pendingPage = nil
      do {
        var payload = SaveFileProgressPayload(
          percentage: Double(page) / Double(document.pageCount) * 100)
        payload.source = "text"
        payload.pageNumber = Double(page)
        try Task.checkCancellation()
        guard !isClosed else { return }
        try await api.sendEmpty(
          "books/files/\(file.id)/progress", body: JSONEncoder().encode(payload))
        guard !isClosed else { return }
        if pendingPage == nil {
          status = "Position saved"
          error = nil
        }
      } catch {
        guard !isClosed else { return }
        if pendingPage == nil { pendingPage = page }
        self.error = error.localizedDescription
        status = "Position could not be saved."
        return
      }
    }
  }

  func prepareToClose() async -> Bool {
    guard !isClosing, !isClosed else { return false }
    isClosing = true
    defer { isClosing = false }
    retrySaving()
    await saveTask?.value
    return pendingPage == nil
  }

  func retrySaving() {
    guard !isClosed, saveTask == nil, pendingPage != nil else { return }
    status = "Saving position…"
    error = nil
    saveTask = Task { await savePendingPosition() }
  }

  func close() {
    isClosed = true
    saveTask?.cancel()
    searchSelection = nil
    document = nil
    removeLocalFile()
  }

  private func removeLocalFile() {
    guard let localFile else { return }
    try? FileManager.default.removeItem(at: localFile)
    self.localFile = nil
  }
}
