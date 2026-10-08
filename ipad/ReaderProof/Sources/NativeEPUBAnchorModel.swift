import Foundation
import Observation

@MainActor @Observable
final class NativeEPUBAnchorModel {
  let api: BookOrbitAPI
  let bookID: Int
  let file: BookDetailFile
  var anchorDraft = ""
  private(set) var document: NativeEPUBTextDocument?
  private(set) var highlights: [AnnotationItem] = []
  private(set) var selection: NSRange?
  private(set) var selectionRevision = 0
  private(set) var selectionText = ""
  private(set) var selectionCFI = ""
  private(set) var error: String?
  private(set) var status = "Opening publication…"
  private(set) var isBusy = false
  private(set) var isLoading = false
  private(set) var uncertainHighlight = false
  private var package: NativeEPUBPackage?
  private var progress: FileReadingProgress?
  private var generation: UUID?
  private var pendingHighlight: CreateAnnotationPayload?
  private var operation: Task<Void, Never>?
  private var isClosed = false

  init(api: BookOrbitAPI, bookID: Int, file: BookDetailFile) {
    self.api = api
    self.bookID = bookID
    self.file = file
  }

  var canSaveHighlight: Bool {
    !isBusy && !uncertainHighlight && !selectionText.isEmpty && !selectionCFI.isEmpty
  }

  var canSavePosition: Bool { !isBusy && selection != nil && !selectionCFI.isEmpty }

  func load() async {
    guard document == nil, !isLoading, !isClosed else { return }
    isLoading = true
    error = nil
    defer { isLoading = false }
    do {
      let session = try await api.authenticatedSessionGeneration()
      generation = session
      let info: EpubBookInfo = try await api.boundedJSON(
        "epub/\(bookID)/info", query: [URLQueryItem(name: "fileId", value: String(file.id))],
        session: session)
      guard info.spine.count <= 4096, info.manifest.count <= 4096,
        let first = info.spine.first(where: \.linear), first.mediaType == "application/xhtml+xml",
        let resource = info.manifest.first(where: { $0.id == first.idref }),
        resource.href == first.href, resource.mediaType == first.mediaType,
        Self.validPath(info.containerPath), Self.validPath(resource.href)
      else { throw NativeEPUBError.unsupported }
      let opf = try await api.epubResource(
        bookID: bookID, fileID: file.id, path: info.containerPath, expectedSize: nil,
        byteLimit: 256 * 1024, session: session)
      let resolved = try NativeEPUBPackage.resolve(
        NativeEPUBSource.parse(opf, limit: 256 * 1024), info: info, idref: first.idref)
      let chapter = try await api.epubResource(
        bookID: bookID, fileID: file.id, path: resource.href, expectedSize: resource.size,
        byteLimit: 64 * 1024, session: session)
      let text = try NativeEPUBTextDocument.build(NativeEPUBSource.parse(chapter, limit: 64 * 1024))
      let saved: FileReadingProgress = try await api.boundedJSON(
        "books/files/\(file.id)/progress", session: session)
      guard saved.percentage.isFinite, (0...100).contains(saved.percentage) else {
        throw ConnectionError.invalidResponse
      }
      try Task.checkCancellation()
      guard !isClosed else { return }
      package = resolved
      document = text
      progress = saved
      status = "Select a passage or enter a saved location."
      if let cfi = saved.cfi {
        anchorDraft = cfi
        resolveAnchor()
      }
      try await refreshHighlights()
    } catch is CancellationError {
      close()
    } catch {
      if !isClosed { self.error = error.localizedDescription }
    }
  }

  func resolveAnchor() {
    guard !isBusy, let document, let package else { return }
    do {
      let cfi = try NativeEPUBCFI.parse(anchorDraft)
      try package.validate(cfi)
      let range = try document.range(for: cfi)
      selectionChanged([range])
      selectionRevision += 1
      error = nil
      status = range.length > 0 ? "Passage selected" : "Position restored"
    } catch {
      selection = nil
      selectionText = ""
      selectionCFI = ""
      selectionRevision += 1
      self.error = error.localizedDescription
    }
  }

  func selectionChanged(_ ranges: [NSRange]) {
    guard !isBusy, let document, let package else { return }
    do {
      guard ranges.count == 1, let range = ranges.first else {
        throw NativeEPUBError.unmappedSelection
      }
      let cfi = try document.anchor(for: range, package: package.path).encoded
      guard cfi.utf16.count <= AnnotationVocabulary.cfiMaximum else {
        throw NativeEPUBError.tooLarge
      }
      selectionText = try document.selectedText(in: range)
      selection = range
      selectionCFI = cfi
    } catch {
      selection = nil
      selectionText = ""
      selectionCFI = ""
      status = error.localizedDescription
    }
  }

  func openHighlight(_ highlight: AnnotationItem) {
    guard !isBusy, let cfi = highlight.cfi else { return }
    anchorDraft = cfi
    resolveAnchor()
    if selection != nil, !selectionText.utf16.elementsEqual(highlight.text.utf16) {
      error = "The saved passage does not match this delivered chapter."
      selection = nil
      selectionCFI = ""
      selectionText = ""
      selectionRevision += 1
    }
  }

  func saveHighlight() {
    guard canSaveHighlight, !isClosed else { return }
    let payload = CreateAnnotationPayload(
      cfi: selectionCFI, bookFileId: file.id, text: selectionText)
    pendingHighlight = payload
    isBusy = true
    error = nil
    operation = Task {
      defer {
        isBusy = false
        operation = nil
      }
      do {
        let saved: AnnotationItem = try await api.boundedJSON(
          "books/\(bookID)/annotations", method: "POST", body: JSONEncoder().encode(payload),
          byteLimit: 128 * 1024, session: generation)
        try validateHighlight(saved, payload: payload)
        guard !isClosed else { return }
        acceptHighlight(saved)
        status = "Highlight saved"
      } catch {
        if !isClosed {
          uncertainHighlight = true
          status = "The save could not be confirmed. Check saved highlights before trying again."
          self.error = error.localizedDescription
        }
      }
    }
  }

  func checkHighlight() {
    guard !isBusy, uncertainHighlight, let pendingHighlight, !isClosed else { return }
    isBusy = true
    error = nil
    operation = Task {
      defer {
        isBusy = false
        operation = nil
      }
      do {
        try await refreshHighlights()
        if let saved = highlights.first(where: {
          $0.cfi == pendingHighlight.cfi && $0.jumpFileId == file.id
            && $0.text.utf16.elementsEqual(pendingHighlight.text.utf16)
        }) {
          try validateHighlight(saved, payload: pendingHighlight)
          status = "A matching highlight is on the server. The original save remains unconfirmed."
        } else {
          status = "The save remains unconfirmed. Reopen the book and inspect its highlights."
        }
      } catch { if !isClosed { self.error = error.localizedDescription } }
    }
  }

  func savePosition() {
    guard canSavePosition, let selection, let document, let package, let progress, !isClosed else {
      return
    }
    isBusy = true
    error = nil
    operation = Task {
      defer {
        isBusy = false
        operation = nil
      }
      do {
        let point = try document.anchor(
          for: NSRange(location: selection.location, length: 0), package: package.path
        ).encoded
        var payload = SaveFileProgressPayload(percentage: progress.percentage)
        payload.source = "text"
        payload.cfi = point
        try await api.sendEmpty(
          "books/files/\(file.id)/progress", body: JSONEncoder().encode(payload),
          session: generation)
        let saved: FileReadingProgress = try await api.boundedJSON(
          "books/files/\(file.id)/progress", session: generation)
        guard saved.cfi == point, saved.percentage == payload.percentage else {
          throw ConnectionError.invalidResponse
        }
        guard !isClosed else { return }
        self.progress = saved
        status = "Position saved"
      } catch { if !isClosed { self.error = error.localizedDescription } }
    }
  }

  func close() {
    isClosed = true
    operation?.cancel()
    operation = nil
    document = nil
    package = nil
    selection = nil
    highlights = []
  }

  private func refreshHighlights() async throws {
    let page: AnnotationListResponse = try await api.boundedJSON(
      "books/\(bookID)/annotations",
      query: [
        URLQueryItem(name: "bookFileId", value: String(file.id)),
        URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "pageSize", value: "20"),
        URLQueryItem(name: "sortBy", value: "createdAt"),
        URLQueryItem(name: "sortDir", value: "desc"),
      ], byteLimit: 512 * 1024, session: generation)
    guard page.page == 1, page.pageSize == 20, page.items.count <= 20,
      page.total >= page.items.count,
      page.items.allSatisfy({ $0.id > 0 && $0.bookId == bookID && $0.jumpFileId == file.id })
    else { throw ConnectionError.invalidResponse }
    try Task.checkCancellation()
    if !isClosed { highlights = page.items }
  }

  private func validateHighlight(_ saved: AnnotationItem, payload: CreateAnnotationPayload) throws {
    guard saved.id > 0, saved.bookId == bookID, saved.jumpFileId == file.id,
      saved.cfi == payload.cfi, saved.text.utf16.elementsEqual(payload.text.utf16),
      saved.positionStatus == "exact"
    else { throw ConnectionError.invalidResponse }
  }

  private func acceptHighlight(_ saved: AnnotationItem) {
    highlights.removeAll { $0.id == saved.id }
    highlights.insert(saved, at: 0)
    highlights = Array(highlights.prefix(20))
    pendingHighlight = nil
    uncertainHighlight = false
  }

  private static func validPath(_ path: String) -> Bool {
    !path.isEmpty && path.utf16.count <= 4096 && !path.hasPrefix("/")
      && !path.contains("\\") && !path.contains(":") && !path.contains("?") && !path.contains("#")
      && !path.split(separator: "/").contains("..")
  }
}
