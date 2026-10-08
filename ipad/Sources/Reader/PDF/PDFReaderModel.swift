import Foundation
import Observation
import PDFKit

@MainActor @Observable
final class PDFReaderModel {
  let api: BookOrbitAPI
  let file: BookDetailFile
  let position: NativeFilePositionModel
  private(set) var document: PDFDocument?
  private(set) var sourceRevision: String?
  private(set) var pageIndex = 0
  private(set) var searchSelection: PDFSelection?
  private(set) var status = ""
  private(set) var error: String?
  private(set) var isPositionResetting = false
  private(set) var isClosing = false
  private(set) var isUnlocking = false
  private(set) var passwordError: String?
  var requiresPassword: Bool { lockedDocument != nil }
  var hasUnsavedPosition: Bool {
    (pendingPage != nil || position.conflict.isBlocked) && saveTask == nil
  }
  private var lockedDocument: PDFDocument?
  private var openingPageNumber: Double?
  private var session: UUID?
  private var localFile: URL?
  private var pendingPage: Int?
  private var saveTask: Task<Void, Never>?
  private var isClosed = false
  private var isLoading = false
  private var isRefreshingSource = false
  private var sourceBook: BookDetail?
  private var sourceRecoveryRetained = false

  init(api: BookOrbitAPI, file: BookDetailFile) {
    self.api = api
    self.file = file
    position = NativeFilePositionModel(
      api: api, fileID: file.id,
      sourceIdentity: file.absolutePath)
  }

  func load(bookID: Int? = nil) async {
    guard document == nil, lockedDocument == nil, !isLoading, !isClosed else { return }
    isLoading = true
    error = nil
    defer { isLoading = false }
    do {
      let session = try await api.authenticatedSessionGeneration()
      try Task.checkCancellation()
      guard !isClosed else { return }
      self.session = session
      if let bookID {
        sourceBook = try await api.boundedJSON(
          "books/\(bookID)", byteLimit: 2 * 1024 * 1024, session: session)
      }
      let progress: FileReadingProgress = try await api.boundedJSON(
        "books/files/\(file.id)/progress", byteLimit: 16 * 1024, session: session)
      try await checkSession()
      try await position.accept(progress, session: session)
      let cached = try await api.offlineStore().sourceResource(fileID: file.id)
      guard let size = cached?.expectedBytes.map(Double.init) ?? file.sizeBytes else {
        throw ConnectionError.invalidResponse
      }
      let url = try await api.deliveredFile(
        fileID: file.id, expectedSize: size, mimeType: "application/pdf", session: session)
      if isClosed || Task.isCancelled {
        try? FileManager.default.removeItem(at: url)
        return
      }
      localFile = url
      sourceRevision = try await PDFSourceInkSource.revision(of: url)
      try await position.bindSourceRevision(sourceRevision)
      try await checkSession()
      guard let pdf = PDFDocument(url: url) else {
        throw ConnectionError.invalidResponse
      }
      try await checkSession()
      openingPageNumber = position.resumePageNumber
      if pdf.isLocked {
        lockedDocument = pdf
      } else {
        try open(pdf)
      }
    } catch is CancellationError {
      discardOpeningDocument()
    } catch {
      discardOpeningDocument()
      guard !isClosed, !Task.isCancelled else { return }
      self.error = error.localizedDescription
    }
  }

  func unlock(withPassword password: String) async {
    guard !isClosed, !isUnlocking, let pdf = lockedDocument, !password.isEmpty else { return }
    isUnlocking = true
    passwordError = nil
    defer { isUnlocking = false }
    do {
      try await checkSession()
      guard pdf.unlock(withPassword: password), !pdf.isLocked else {
        passwordError = "That password did not unlock the PDF. Try again."
        return
      }
      try await checkSession()
      try open(pdf)
    } catch is CancellationError {
      discardOpeningDocument()
    } catch {
      discardOpeningDocument()
      guard !isClosed, !Task.isCancelled else { return }
      self.error = error.localizedDescription
    }
  }

  private func open(_ pdf: PDFDocument) throws {
    guard !pdf.isLocked, pdf.pageCount > 0 else { throw ConnectionError.invalidResponse }
    if let page = openingPageNumber, page.isFinite, page >= 1, page <= Double(pdf.pageCount) {
      pageIndex = Int(page.rounded(.down)) - 1
    }
    document = pdf
    var beginning = SaveFileProgressPayload(percentage: 100 / Double(pdf.pageCount))
    beginning.pageNumber = 1
    position.setBeginning(beginning)
    lockedDocument = nil
    openingPageNumber = nil
    passwordError = nil
    error = nil
  }

  private func checkSession() async throws {
    try Task.checkCancellation()
    guard !isClosed else { throw CancellationError() }
    guard let session, session == (try await api.authenticatedSessionGeneration()) else {
      throw ConnectionError.expiredSession
    }
    try Task.checkCancellation()
    guard !isClosed else { throw CancellationError() }
  }

  func didTurn(to index: Int) {
    guard !isClosed, !isPositionResetting, !isClosing, !position.conflict.isBlocked, let document,
      (0..<document.pageCount).contains(index),
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

  func reveal(page index: Int) {
    guard !isClosed, let document, (0..<document.pageCount).contains(index) else { return }
    pageIndex = index
    searchSelection = nil
  }

  func openSearchMatch(_ match: PDFSearchMatch) {
    guard !isClosed, !isPositionResetting, !isClosing, let document,
      let page = document.page(at: match.pageIndex)
    else { return }
    didTurn(to: match.pageIndex)
    let selection = PDFSelection(document: document)
    for range in match.ranges {
      if let part = page.selection(for: range) { selection.add(part) }
    }
    searchSelection = selection
  }

  func openContentsPage(_ index: Int) {
    guard !isClosed, !isPositionResetting, !isClosing, let document,
      (0..<document.pageCount).contains(index)
    else { return }
    searchSelection = nil
    didTurn(to: index)
  }

  func authorizeThumbnails(in document: PDFDocument) async -> Bool {
    do {
      try await checkSession()
      return !isClosed && !isPositionResetting && !isClosing && self.document === document
        && !document.isLocked
    } catch { return false }
  }

  func openThumbnailPage(_ index: Int) async -> Bool {
    guard let document, await authorizeThumbnails(in: document),
      !position.conflict.isBlocked, !position.isResolving,
      (0..<document.pageCount).contains(index)
    else { return false }
    openContentsPage(index)
    return pageIndex == index
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
        guard let saved = await position.save(payload) else {
          if pendingPage == nil { pendingPage = page }
          error = position.message
          status = "Position could not be saved."
          return
        }
        if saved.pageNumber != Double(page) {
          if pendingPage == nil { pendingPage = page }
          continue
        }
        guard !isClosed else { return }
        if pendingPage == nil {
          status = position.hasPendingSync ? "Position saved on this iPad" : "Position saved"
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

  func refreshPosition() async {
    guard !isClosed, !isPositionResetting, !isClosing, saveTask == nil, let document,
      document.pageCount > 0
    else { return }
    var local = SaveFileProgressPayload(
      percentage: Double(pageIndex + 1) / Double(document.pageCount) * 100)
    local.pageNumber = Double(pageIndex + 1)
    await position.refresh(local)
  }

  func refreshPublishedSource(
    bookID: Int, proof: NativePdfPageSource, canReload: @MainActor () -> Bool
  ) async {
    guard !isClosed, !isRefreshingSource, let session, let sourceRevision, let document,
      proof.sourceRevision != sourceRevision,
      proof.matchedSourceRevision == sourceRevision, canReload()
    else { return }
    isRefreshingSource = true
    defer { isRefreshingSource = false }
    var replacement: URL?
    do {
      let book: BookDetail = try await api.boundedJSON(
        "books/\(bookID)", byteLimit: 2 * 1024 * 1024, session: session)
      try await checkSession()
      guard let current = book.files.first(where: { $0.id == file.id }),
        current.absolutePath == file.absolutePath, current.format?.lowercased() == "pdf"
      else { throw ConnectionError.fileChanged }
      let url = try await api.deliveredFile(
        fileID: file.id, expectedSize: current.sizeBytes, mimeType: "application/pdf",
        maximumSize: 100 * 1024 * 1024, session: session)
      replacement = url
      let revision = try await PDFSourceInkSource.revision(of: url)
      try await checkSession()
      try Task.checkCancellation()
      guard !isClosed, revision == proof.sourceRevision,
        let refreshed = PDFDocument(url: url), !refreshed.isLocked,
        refreshed.pageCount == document.pageCount
      else { throw ConnectionError.fileChanged }
      guard canReload() else {
        try? FileManager.default.removeItem(at: url)
        return
      }
      try await position.bindSourceRevision(revision, matchedRevision: proof.matchedSourceRevision)
      try await checkSession()
      guard canReload() else {
        try? FileManager.default.removeItem(at: url)
        return
      }
      removeLocalFile()
      localFile = url
      replacement = nil
      self.document = refreshed
      self.sourceRevision = revision
      searchSelection = nil
    } catch is CancellationError {
    } catch {
      self.error = error.localizedDescription
    }
    if let replacement { try? FileManager.default.removeItem(at: replacement) }
  }

  func retainChangedSource(reason: String) async {
    guard !sourceRecoveryRetained, let sourceBook, let localFile, let sourceRevision,
      let session
    else { return }
    do {
      try await api.retainOpenedPdfSource(
        book: sourceBook, fileID: file.id, source: localFile,
        revision: sourceRevision, reason: reason, session: session)
      sourceRecoveryRetained = true
    } catch { self.error = error.localizedDescription }
  }

  func choosePosition(local: Bool) async {
    guard !isClosed, !isPositionResetting, !isClosing, saveTask == nil, let document,
      let saved = await position.choose(local: local),
      let page = saved.pageNumber, page.isFinite, page >= 1, page <= Double(document.pageCount)
    else { return }
    pageIndex = Int(page) - 1
    pendingPage = nil
    status =
      position.hasPendingSync
      ? "Chosen position saved on this iPad." : "Chosen reading position saved."
    error = nil
    searchSelection = nil
  }

  func prepareToClose() async -> Bool {
    guard !isClosing, !isClosed else { return false }
    isClosing = true
    defer { isClosing = false }
    retrySaving()
    await saveTask?.value
    return pendingPage == nil && !position.conflict.isBlocked
  }

  func retrySaving() {
    guard !isClosed, !isPositionResetting, saveTask == nil, pendingPage != nil,
      !position.conflict.isBlocked
    else { return }
    status = "Saving position…"
    error = nil
    saveTask = Task { await savePendingPosition() }
  }

  func beginPositionReset() async throws {
    guard !isClosed, !isClosing else { throw CancellationError() }
    isPositionResetting = true
    position.suspendForReset(true)
    try await NativePositionResetWait.drain {
      self.saveTask != nil || self.position.isSaving || self.position.isResolving
    }
  }

  func cancelPositionReset() {
    isPositionResetting = false
    position.suspendForReset(false)
  }

  func acknowledgePositionReset() {
    pendingPage = nil
    position.acknowledgeReset()
  }

  func close() {
    isClosed = true
    position.close()
    saveTask?.cancel()
    searchSelection = nil
    document = nil
    sourceRevision = nil
    session = nil
    discardOpeningDocument()
  }

  private func discardOpeningDocument() {
    lockedDocument = nil
    openingPageNumber = nil
    passwordError = nil
    removeLocalFile()
  }

  private func removeLocalFile() {
    guard let localFile else { return }
    try? FileManager.default.removeItem(at: localFile)
    self.localFile = nil
  }
}
