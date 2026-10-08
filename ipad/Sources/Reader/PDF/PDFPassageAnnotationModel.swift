import Foundation
import Observation
import PDFKit
import PencilKit

struct PDFPassageAnnotationPresentation: Identifiable {
  let id = UUID()
  let preview: PDFPassageRepairPreview
  let item: NativeAnnotationItem?
}

@MainActor @Observable
final class PDFPassageAnnotationModel {
  let api: BookOrbitAPI
  let bookID: Int
  let fileID: Int
  let mode = PencilReaderMode()
  private(set) var repository: NativeAnnotationRepository?
  private(set) var items: [NativeAnnotationItem] = []
  private(set) var selectedText = ""
  private(set) var canManage = false
  private(set) var isBusy = false
  private(set) var error: String?
  private(set) var notice: String?
  var presentation: PDFPassageAnnotationPresentation?
  var kind = "highlight"
  var note = ""
  var color = "#FACC15"
  var drawing = PKDrawing()
  var fixtureGeneration = 0
  var scribbleFixtureGeneration = 0
  var selectionFixtureGeneration = 0
  private var selection: PDFSelection?
  private var document: PDFDocument?
  private var source: PDFSourceInkEditor?
  private var fingerprints: [Int: String] = [:]
  private var visiblePages: Set<Int> = []
  private var lastOperationID: UUID?

  init(api: BookOrbitAPI, bookID: Int, fileID: Int) {
    self.api = api
    self.bookID = bookID
    self.fileID = fileID
  }

  var canPreview: Bool { canManage && !isBusy && !selectedText.isEmpty && presentation == nil }
  var canUndo: Bool { canManage && !isBusy && lastOperationID != nil }
  var visibleNotes: [NativeAnnotationItem] {
    Array(
      items.lazy.filter { item in
        guard let page = item.pdf?.page else { return false }
        return item.pageFingerprint == self.fingerprints[page]
      }.prefix(500))
  }

  func beginSelection() { source?.mode.isWriting = false }
  var canSave: Bool {
    canManage && !isBusy && presentation != nil && repository != nil
      && (kind != "text_note" || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      && note.utf16.count <= 16_000
      && (kind != "handwriting" || !drawing.strokes.isEmpty)
      && drawing.strokes.count <= 256 && drawing.dataRepresentation().count <= 1_400_000
      && drawing.strokes.reduce(0, { $0 + $1.path.count }) <= 10_000
  }

  func bind(document: PDFDocument, source: PDFSourceInkEditor) {
    self.document = document
    self.source = source
  }

  func load() async {
    do {
      let repository = try await NativeAnnotationRepository.shared(api: api)
      self.repository = repository
      let user: AuthUser = try await api.boundedJSON("auth/me", byteLimit: 1024 * 1024)
      canManage =
        user.isSuperuser || user.permissions.contains(Permission.annotationManageOwn.rawValue)
      try? await repository.synchronize(bookID: bookID)
      await reloadItems()
    } catch { self.error = error.localizedDescription }
  }

  func reloadItems() async {
    guard let repository else { return }
    do {
      let pages = visiblePages
      var loaded: [NativeAnnotationItem] = []
      for page in pages.sorted().prefix(4) {
        loaded += try await repository.loadPDFPassages(bookID: bookID, fileID: fileID, page: page)
      }
      guard pages == visiblePages else { return }
      items = loaded.filter { $0.deletedAt == nil && $0.positionStatus != "failed" }
      if let syncError = repository.error { error = syncError }
    } catch { self.error = error.localizedDescription }
  }

  func preparePages(_ pages: Set<Int>) async {
    guard let source else { return }
    visiblePages = Set(pages.sorted().prefix(4))
    for page in visiblePages.sorted() {
      do {
        fingerprints[page] = try await source.sourceForPassageRepair(page: page).pageFingerprint
      } catch { self.error = error.localizedDescription }
    }
    if fingerprints.count > 8 { fingerprints = fingerprints.filter { pages.contains($0.key) } }
    await reloadItems()
  }

  func items(on page: Int) -> [NativeAnnotationItem] {
    Array(
      items.lazy.filter {
        $0.pdf?.page == page && $0.pageFingerprint == self.fingerprints[page]
      }.prefix(500))
  }

  func selected(_ value: PDFSelection?) {
    guard presentation == nil, !isBusy else { return }
    selection = value?.copy() as? PDFSelection
    selectedText = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  func previewSelection() {
    guard canPreview, let selection, let document, let source else { return }
    isBusy = true
    Task {
      defer { isBusy = false }
      do {
        guard selection.pages.count == 1, let page = selection.pages.first,
          selectedText.utf16.count <= 10_000
        else {
          throw PDFPassageRepairError(message: "Select a shorter passage on one PDF page.")
        }
        let index = document.index(for: page)
        guard index != NSNotFound else { throw ConnectionError.invalidResponse }
        let proof = try await source.sourceForPassageRepair(page: index)
        let position = try PDFPassageRepairGeometry.position(
          selection: selection, page: page, index: index, source: proof)
        open(
          PDFPassageRepairPreview(
            page: index, text: selectedText, position: position, selection: selection,
            sourceRevision: proof.sourceRevision, pageFingerprint: proof.pageFingerprint), item: nil
        )
      } catch { self.error = error.localizedDescription }
    }
  }

  func open(_ item: NativeAnnotationItem) {
    guard !isBusy, item.kind != "pdf_ink", let position = item.pdf,
      let document, let page = document.page(at: position.page), let source
    else { return }
    isBusy = true
    Task {
      defer { isBusy = false }
      do {
        let proof = try await source.sourceForPassageRepair(page: position.page)
        guard proof.pageFingerprint == item.pageFingerprint else {
          throw PDFPassageRepairError(
            message: "This passage changed. Repair its location from Annotations.")
        }
        let selection =
          page.selection(for: page.bounds(for: .cropBox)) ?? PDFSelection(document: document)
        open(
          PDFPassageRepairPreview(
            page: position.page, text: item.text, position: position, selection: selection,
            sourceRevision: proof.sourceRevision, pageFingerprint: proof.pageFingerprint),
          item: item)
      } catch { self.error = error.localizedDescription }
    }
  }

  private func open(_ preview: PDFPassageRepairPreview, item: NativeAnnotationItem?) {
    kind = item?.kind ?? "highlight"
    note = item?.note ?? ""
    color = item?.color ?? "#FACC15"
    drawing = item?.drawing.flatMap(PDFSourceInkDrawing.decode) ?? PKDrawing()
    fixtureGeneration = 0
    scribbleFixtureGeneration = 0
    mode.isWriting = true
    error = nil
    presentation = .init(preview: preview, item: item)
  }

  func cancel() { if !isBusy { presentation = nil } }
  func feedSelection() { selectionFixtureGeneration += 1 }
  func addFixtureStroke() { fixtureGeneration += 1 }
  func completeFixtureScribble() { scribbleFixtureGeneration += 1 }

  func save() {
    guard canSave, let presentation, let repository, let source else { return }
    isBusy = true
    Task {
      defer { isBusy = false }
      do {
        let proof = try await source.sourceForPassageRepair(page: presentation.preview.page)
        guard proof.pageFingerprint == presentation.preview.pageFingerprint else {
          throw ConnectionError.fileChanged
        }
        var payload = NativeAnnotationPayload()
        payload.bookFileId = fileID
        payload.pdf = presentation.preview.position
        payload.sourceRevision = proof.sourceRevision
        payload.pageFingerprint = proof.pageFingerprint
        payload.kind = kind
        payload.text = presentation.preview.text
        payload.color = color
        payload.style = "highlight"
        if kind == "text_note" { payload.note = note }
        if kind == "handwriting" {
          payload.drawing = try NativeDrawingEncoding.encode(
            drawing, prior: presentation.item?.drawing)
        }
        if let item = presentation.item {
          lastOperationID = try await repository.mutate(item, action: "update", payload: payload)
        } else {
          _ = try await repository.create(bookID: bookID, payload: payload)
          lastOperationID = repository.lastOperationID
        }
        self.presentation = nil
        notice = "Private passage annotation saved on this iPad."
        await reloadItems()
      } catch { self.error = error.localizedDescription }
    }
  }

  func delete() {
    guard canManage, !isBusy, let item = presentation?.item, let repository else { return }
    isBusy = true
    Task {
      defer { isBusy = false }
      do {
        lastOperationID = try await repository.mutate(item, action: "delete")
        presentation = nil
        await reloadItems()
      } catch { self.error = error.localizedDescription }
    }
  }

  func undo() {
    guard canUndo, let operation = lastOperationID, let repository else { return }
    isBusy = true
    Task {
      defer { isBusy = false }
      do {
        let outcome = try await repository.undo(operationID: operation)
        notice = outcome.message
        lastOperationID = nil
        await reloadItems()
      } catch { self.error = error.localizedDescription }
    }
  }
}
