import Foundation
import Observation
import PDFKit
import PencilKit
import UIKit

enum PDFSourceInkTool { case draw, select, lasso }

@MainActor @Observable
final class PDFSourceInkEditor {
  let mode = PencilReaderMode()
  let api: BookOrbitAPI
  let bookID: Int
  let fileID: Int
  var tool = PDFSourceInkTool.draw
  var currentPage = 0
  var loadedSourceRevision: String?
  private(set) var repository: NativeAnnotationRepository?
  private(set) var items: [NativeAnnotationItem] = []
  private(set) var selectedIdentity: String?
  private(set) var selectedStrokeIDs: Set<String> = []
  private var strokeSelectionIdentity: String?
  private(set) var isTransformingSelection = false
  private(set) var draft = PKDrawing()
  private(set) var draftPage: Int?
  private(set) var canEdit = false
  private(set) var isSaving = false
  private(set) var status = ""
  private(set) var error: String?
  private(set) var fixtureGeneration = 0
  @ObservationIgnored var fixtureLassoInput: (@MainActor () -> Void)?
  private var sources: [Int: NativePdfPageSource] = [:]
  private var autosave: Task<Void, Never>?
  private var undoOperations: [UUID] = []
  private var copy: NativeAnnotationDrawing?
  private var strokeActive = false
  private var loaded = false
  private var isRefreshingRemote = false
  private var sourceRecoveryRequired = false
  private var retainedSourceReason = "source_replaced"

  init(api: BookOrbitAPI, bookID: Int, fileID: Int) {
    self.api = api
    self.bookID = bookID
    self.fileID = fileID
  }

  var selected: NativeAnnotationItem? {
    items.first { identity($0) == selectedIdentity && $0.deletedAt == nil }
  }
  var canUndo: Bool { !draft.strokes.isEmpty || !undoOperations.isEmpty }
  var canPaste: Bool {
    canEdit && !isSaving
      && (copy != nil
        || UIPasteboard.general.contains(pasteboardTypes: ["com.bookorbit.source-ink"]))
  }
  var pendingCount: Int { repository?.pendingCount ?? 0 }
  var repositoryGeneration: Int { repository?.generation ?? 0 }
  var hasUncommittedDrawing: Bool {
    strokeActive || isTransformingSelection || !draft.strokes.isEmpty || isSaving
  }
  var isDrawingStroke: Bool { strokeActive }
  var selectedStrokeCount: Int {
    guard let selected, let retained = selected.drawing else { return 0 }
    return strokeSelectionIdentity == identity(selected)
      ? retained.strokes.filter { selectedStrokeIDs.contains($0.id) }.count : retained.strokes.count
  }
  var selectedGroupStrokeCount: Int { selected?.drawing?.strokes.count ?? 0 }
  var sourceRecoveryReason: String? { sourceRecoveryRequired ? retainedSourceReason : nil }

  func identity(_ item: NativeAnnotationItem) -> String { item.clientId ?? String(item.id) }

  func groups(on page: Int) -> [NativeAnnotationItem] {
    items.filter { $0.deletedAt == nil && $0.pdf?.page == page && matchesSource($0) }
  }

  func load() async {
    guard !loaded else { return }
    do {
      repository = try await NativeAnnotationRepository.shared(api: api)
      try await refreshSource(page: currentPage)
      try? await repository?.synchronizeSourceInk(bookID: bookID, fileID: fileID)
      await refreshItems()
      loaded = true
    } catch { self.error = error.localizedDescription }
  }

  func refreshItems() async {
    guard let repository else { return }
    do {
      items = try await repository.loadSourceInk(bookID: bookID, fileID: fileID)
      if let selectedIdentity,
        !items.contains(where: {
          identity($0) == selectedIdentity && $0.deletedAt == nil && matchesSource($0)
        })
      {
        self.selectedIdentity = nil
      }
      if let syncError = repository.error { self.error = syncError }
      if pendingCount == 0 && loaded && repository.error == nil { status = "Ink synchronized" }
    } catch { self.error = error.localizedDescription }
  }

  func refreshRemote() async -> NativePdfPageSource? {
    guard loaded, !isRefreshingRemote, let repository else { return nil }
    isRefreshingRemote = true
    defer { isRefreshingRemote = false }
    do {
      try await refreshSource(page: currentPage)
      try Task.checkCancellation()
      try await repository.refreshSourceInk(bookID: bookID, fileID: fileID)
      await refreshItems()
      return sources[currentPage]
    } catch is CancellationError {
      return nil
    } catch {
      if case ConnectionError.http(404) = error {
        sourceRecoveryRequired = true
        retainedSourceReason = "source_deleted"
        canEdit = false
        try? await repository.retainSourceRecovery(
          bookID: bookID, fileID: fileID, reason: "source_deleted")
      }
      self.error = error.localizedDescription
      return nil
    }
  }

  private func refreshSource(page: Int) async throws {
    guard let loadedSourceRevision else { throw ConnectionError.invalidResponse }
    let path = "annotations/native/files/\(fileID)/source"
    let query = [
      URLQueryItem(name: "bookId", value: String(bookID)),
      URLQueryItem(name: "page", value: String(page)),
    ]
    let source: NativePdfPageSource
    do {
      source = try await api.boundedJSON(
        path,
        query: query + [URLQueryItem(name: "sourceRevision", value: loadedSourceRevision)],
        byteLimit: 16 * 1024)
    } catch is URLError {
      source = try await api.boundedJSON(path, query: query, byteLimit: 16 * 1024)
    }
    guard
      source.sourceRevision == loadedSourceRevision
        || source.matchedSourceRevision == loadedSourceRevision
    else {
      sourceRecoveryRequired = true
      canEdit = false
      status = "The source PDF changed. Reopen it before creating new ink."
      try await repository?.retainSourceRecovery(
        bookID: bookID, fileID: fileID, reason: "source_replaced")
      throw ConnectionError.fileChanged
    }
    sources[page] = source
    if sources.count > 64 {
      let distant = sources.keys.sorted { abs($0 - page) > abs($1 - page) }
      for key in distant.prefix(sources.count - 64) { sources.removeValue(forKey: key) }
    }
    canEdit = source.canEditPdfInk
    if !canEdit { status = "Source ink editing requires permission" }
  }

  func openPage(_ page: Int) async {
    guard page >= 0, loadedSourceRevision != nil else { return }
    if draftPage != nil && draftPage != page { await saveDraft() }
    currentPage = page
    do {
      try await refreshSource(page: page)
      error = nil
    } catch {
      canEdit = error is URLError && sources[page]?.canEditPdfInk == true
      if !canEdit { self.error = error.localizedDescription }
    }
  }

  func preparePages(_ pages: Set<Int>) async {
    guard repository != nil, loadedSourceRevision != nil else { return }
    for page in pages.sorted().prefix(8) where sources[page] == nil {
      do { try await refreshSource(page: page) } catch { self.error = error.localizedDescription }
    }
  }

  func sourceForPassageRepair(page: Int) async throws -> NativePdfPageSource {
    try await refreshSource(page: page)
    guard let descriptor = sources[page] else { throw ConnectionError.invalidResponse }
    return descriptor
  }

  private func matchesSource(_ item: NativeAnnotationItem) -> Bool {
    guard let page = item.pdf?.page, let descriptor = sources[page]
    else { return false }
    return item.pageFingerprint == descriptor.pageFingerprint
  }

  func select(identity: String?, strokeIndices: Set<Int>? = nil) {
    selectedIdentity = identity
    strokeSelectionIdentity = identity
    if let retained = selected?.drawing {
      selectedStrokeIDs = Set(
        retained.strokes.enumerated().compactMap { index, stroke in
          strokeIndices == nil || strokeIndices?.contains(index) == true ? stroke.id : nil
        })
    } else {
      selectedStrokeIDs = []
    }
    tool = .select
  }

  func select(_ item: NativeAnnotationItem) {
    guard item.jumpFileId == fileID, item.deletedAt == nil, matchesSource(item) else {
      error =
        "This ink belongs to an earlier source. Open recovery to export or attach it explicitly."
      return
    }
    currentPage = item.pdf?.page ?? currentPage
    select(identity: identity(item))
    mode.isWriting = true
    tool = .select
  }

  func draw() {
    tool = .draw
    mode.isWriting = true
  }
  func selectTool() {
    tool = .select
    mode.isWriting = true
  }
  func lassoTool() {
    tool = .lasso
    mode.isWriting = true
  }

  func beginSelectionTransform() { isTransformingSelection = true }
  func endSelectionTransform() { isTransformingSelection = false }

  func beginStroke() {
    strokeActive = true
    if !isSaving { autosave?.cancel() }
  }
  func endStroke() {
    strokeActive = false
    scheduleDraft()
  }

  func preview(_ drawing: PKDrawing, page: Int) {
    guard canEdit || sourceRecoveryRequired else { return }
    guard draftPage == nil || draftPage == page else { return }
    draft = drawing
    draftPage = page
    status = drawing.strokes.isEmpty ? "" : "Ink preview"
    error = nil
    if !strokeActive { scheduleDraft() }
  }

  private func scheduleDraft() {
    guard !isSaving else { return }
    autosave?.cancel()
    guard !draft.strokes.isEmpty else {
      draftPage = nil
      return
    }
    autosave = Task {
      guard !Task.isCancelled else { return }
      await saveDraft()
    }
  }

  func saveDraft() async {
    guard canEdit || sourceRecoveryRequired, !isSaving, !strokeActive, let page = draftPage,
      let repository,
      let payload = payload(for: draft, page: page)
    else { return }
    isSaving = true
    let savingDrawing = draft
    var saved = false
    defer {
      isSaving = false
      if saved && !draft.strokes.isEmpty && !strokeActive { scheduleDraft() }
    }
    do {
      let item = try await repository.create(bookID: bookID, payload: payload)
      if sourceRecoveryRequired {
        try await repository.retainSourceRecovery(
          bookID: bookID, fileID: fileID, reason: retainedSourceReason)
      }
      saved = true
      rememberOperation()
      selectedIdentity = identity(item)
      if draft.dataRepresentation() == savingDrawing.dataRepresentation() {
        draft = PKDrawing()
        draftPage = nil
      } else if draft.strokes.count >= savingDrawing.strokes.count {
        draft = PKDrawing(strokes: Array(draft.strokes.dropFirst(savingDrawing.strokes.count)))
      }
      status = sourceRecoveryRequired ? "Ink retained for source recovery" : "Ink saved locally"
      await refreshItems()
    } catch { self.error = error.localizedDescription }
  }

  private func payload(for drawing: PKDrawing, page: Int, previous: NativeAnnotationDrawing? = nil)
    -> NativeAnnotationPayload?
  {
    guard let descriptor = sources[page],
      !drawing.bounds.isNull,
      drawing.bounds.minX >= 0, drawing.bounds.minY >= 0,
      drawing.bounds.maxX <= Double(descriptor.width),
      drawing.bounds.maxY <= Double(descriptor.height)
    else {
      error = "Keep the ink inside this page. The drawing remains available to retry."
      return nil
    }
    let retained: NativeAnnotationDrawing
    do {
      guard let encoded = try PDFSourceInkDrawing.encode(drawing, preserving: previous) else {
        error = "This ink could not be saved. Your drawing remains available to edit and retry."
        return nil
      }
      retained = encoded
    } catch {
      self.error = error.localizedDescription
      return nil
    }
    let bounds = drawing.bounds
    var payload = NativeAnnotationPayload()
    payload.kind = "pdf_ink"
    payload.bookFileId = fileID
    payload.text = ""
    payload.drawing = retained
    payload.sourceRevision = loadedSourceRevision
    payload.pageFingerprint = descriptor.pageFingerprint
    payload.pdf = AnnotationPdfPosition(
      page: page,
      rect: AnnotationRect(
        x: bounds.minX, y: bounds.minY,
        width: bounds.width, height: bounds.height), rects: [])
    return payload
  }

  func replaceSelected(
    with drawing: PKDrawing, expectedIdentity: String? = nil, expectedVersion: Int? = nil
  ) {
    if let expectedIdentity, selectedIdentity != expectedIdentity {
      error = "The selected ink changed. Select it again before editing."
      return
    }
    if let expectedVersion, selected?.version != expectedVersion {
      error = "The selected ink changed. Select it again before editing."
      return
    }
    guard canEdit, !isSaving, let selected, let retained = selected.drawing,
      let original = PDFSourceInkDrawing.decode(retained), let page = selected.pdf?.page,
      original.strokes.count == drawing.strokes.count
    else { return }
    let indices = selectedStrokeIndices(in: original)
    guard !indices.isEmpty else { return }
    let combined = PKDrawing(
      strokes: original.strokes.enumerated().map { index, stroke in
        indices.contains(index) ? drawing.strokes[index] : stroke
      })
    guard var replacement = payload(for: combined, page: page, previous: retained),
      var encoded = replacement.drawing
    else { return }
    for index in retained.strokes.indices where !indices.contains(index) {
      encoded.strokes[index] = retained.strokes[index]
    }
    replacement.drawing = encoded
    mutate(selected, action: "update", payload: replacement)
  }

  func deleteSelected() {
    guard canEdit, !isSaving, let selected, let retained = selected.drawing,
      let drawing = PDFSourceInkDrawing.decode(retained), let page = selected.pdf?.page
    else { return }
    let indices = selectedStrokeIndices(in: drawing)
    guard !indices.isEmpty else { return }
    if indices.count == drawing.strokes.count {
      mutate(selected, action: "delete")
      return
    }
    let survivors = drawing.strokes.indices.filter { !indices.contains($0) }
    let remaining = PKDrawing(strokes: survivors.map { drawing.strokes[$0] })
    var previous = retained
    previous.strokes = survivors.map { retained.strokes[$0] }
    guard var replacement = payload(for: remaining, page: page, previous: previous),
      var encoded = replacement.drawing
    else { return }
    encoded.strokes = previous.strokes
    replacement.drawing = encoded
    mutate(selected, action: "update", payload: replacement)
  }

  func selectedStrokeIndices(in drawing: PKDrawing) -> Set<Int> {
    guard let selected, let retained = selected.drawing,
      retained.strokes.count == drawing.strokes.count
    else { return [] }
    return Set(
      retained.strokes.indices.filter {
        strokeSelectionIdentity != identity(selected)
          || selectedStrokeIDs.contains(retained.strokes[$0].id)
      })
  }

  func selectedDrawing(in drawing: PKDrawing) -> PKDrawing {
    let indices = selectedStrokeIndices(in: drawing)
    return PKDrawing(
      strokes: drawing.strokes.enumerated().compactMap { index, stroke in
        indices.contains(index) ? stroke : nil
      })
  }

  func transformingSelectedStrokes(in drawing: PKDrawing, using transform: CGAffineTransform)
    -> PKDrawing
  {
    let indices = selectedStrokeIndices(in: drawing)
    return PKDrawing(
      strokes: drawing.strokes.enumerated().map { index, stroke in
        indices.contains(index)
          ? PKDrawing(strokes: [stroke]).transformed(using: transform).strokes[0] : stroke
      })
  }

  private func mutate(
    _ item: NativeAnnotationItem, action: String,
    payload: NativeAnnotationPayload? = nil
  ) {
    guard !isSaving, let repository else { return }
    isSaving = true
    Task {
      defer { isSaving = false }
      do {
        let operation = try await repository.mutate(item, action: action, payload: payload)
        undoOperations.append(operation)
        trimUndo()
        status = "Ink saved locally"
        await refreshItems()
      } catch { self.error = error.localizedDescription }
    }
  }

  func copySelected() {
    guard let selected, let retained = selected.drawing,
      let drawing = PDFSourceInkDrawing.decode(retained)
    else { return }
    let indices = selectedStrokeIndices(in: drawing)
    guard !indices.isEmpty else { return }
    var previous = retained
    previous.strokes = retained.strokes.enumerated().compactMap { index, stroke in
      indices.contains(index) ? stroke : nil
    }
    do {
      guard
        var copied = try PDFSourceInkDrawing.encode(
          selectedDrawing(in: drawing), preserving: previous)
      else { return }
      copied.strokes = previous.strokes
      copy = copied
    } catch {
      self.error = error.localizedDescription
      return
    }
    if let copy, let data = try? JSONEncoder().encode(copy) {
      UIPasteboard.general.setData(data, forPasteboardType: "com.bookorbit.source-ink")
    }
    status = "Ink copied"
  }

  func paste() {
    let pasted: NativeAnnotationDrawing?
    if let retained = copy {
      pasted = retained
    } else if let data = UIPasteboard.general.data(forPasteboardType: "com.bookorbit.source-ink"),
      data.count <= 4 * 1024 * 1024
    {
      pasted = try? JSONDecoder().decode(NativeAnnotationDrawing.self, from: data)
    } else {
      pasted = nil
    }
    guard canPaste, let retained = pasted,
      let drawing = PDFSourceInkDrawing.decode(retained), let repository,
      let payload = payload(
        for: drawing.transformed(
          using:
            CGAffineTransform(translationX: 16, y: 16)), page: currentPage)
    else { return }
    isSaving = true
    Task {
      defer { isSaving = false }
      do {
        let item = try await repository.create(bookID: bookID, payload: payload)
        rememberOperation()
        selectedIdentity = identity(item)
        status = "Ink saved locally"
        await refreshItems()
      } catch { self.error = error.localizedDescription }
    }
  }

  func moveRight() {
    guard let drawing = selected?.drawing.flatMap(PDFSourceInkDrawing.decode) else { return }
    replaceSelected(
      with: transformingSelectedStrokes(
        in: drawing, using: CGAffineTransform(translationX: 12, y: 0)))
  }

  func grow() {
    guard let drawing = selected?.drawing.flatMap(PDFSourceInkDrawing.decode) else { return }
    let bounds = selectedDrawing(in: drawing).bounds
    guard !bounds.isNull else { return }
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    let transform = CGAffineTransform(translationX: -center.x, y: -center.y)
      .concatenating(CGAffineTransform(scaleX: 1.1, y: 1.1))
      .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
    replaceSelected(with: transformingSelectedStrokes(in: drawing, using: transform))
  }

  func undo() {
    guard !isSaving else { return }
    if !draft.strokes.isEmpty {
      autosave?.cancel()
      draft = PKDrawing()
      draftPage = nil
      status = "Ink preview canceled"
      return
    }
    guard let operation = undoOperations.last, let repository else { return }
    isSaving = true
    Task {
      defer { isSaving = false }
      do {
        let outcome = try await repository.undo(operationID: operation)
        undoOperations.removeLast()
        status = outcome.message
        await refreshItems()
      } catch { self.error = error.localizedDescription }
    }
  }

  func feedFixture() {
    draw()
    fixtureGeneration += 1
  }

  func feedFixtureLasso() {
    guard ProcessInfo.processInfo.environment["BOOKORBIT_ANNOTATION_INPUT_FIXTURE"] == "1",
      ProcessInfo.processInfo.arguments.contains("--annotation-input-driver"),
      canEdit, !isSaving
    else { return }
    lassoTool()
    fixtureLassoInput?()
  }

  func retryDraft() { Task { await saveDraft() } }

  func retrySynchronization() {
    guard let repository else { return }
    Task {
      do {
        try await repository.synchronizeSourceInk(bookID: bookID, fileID: fileID)
        await refreshItems()
      } catch { self.error = error.localizedDescription }
    }
  }

  private func rememberOperation() {
    if let operation = repository?.lastOperationID {
      undoOperations.append(operation)
      trimUndo()
    }
  }
  private func trimUndo() {
    if undoOperations.count > 100 { undoOperations.removeFirst(undoOperations.count - 100) }
  }

  func close() {
    if !isSaving { autosave?.cancel() }
    if !draft.strokes.isEmpty { Task { await saveDraft() } }
  }

  func repairPayload(_ item: NativeAnnotationItem, page: Int) -> NativeAnnotationPayload? {
    guard let retained = item.drawing, let drawing = PDFSourceInkDrawing.decode(retained) else {
      return nil
    }
    return payload(for: drawing, page: page, previous: retained)
  }
}
