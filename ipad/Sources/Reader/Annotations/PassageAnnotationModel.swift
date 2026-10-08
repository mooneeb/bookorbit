import Foundation
import Observation
import PencilKit

struct PassageAnnotationPresentation: Identifiable {
  let id = UUID()
  let passage: EPUBSelectedPassage
  let item: NativeAnnotationItem?
}

@MainActor @Observable
final class PassageAnnotationModel {
  let reader: EPUBReaderModel
  let mode = PencilReaderMode()
  var presentation: PassageAnnotationPresentation?
  var kind = "highlight"
  var note = ""
  var drawing = PKDrawing()
  var fixtureGeneration = 0
  var scribbleFixtureGeneration = 0
  private(set) var repository: NativeAnnotationRepository?
  private(set) var items: [NativeAnnotationItem] = []
  private(set) var isSaving = false
  private(set) var lastOperationID: UUID?
  private(set) var error: String?

  init(reader: EPUBReaderModel) { self.reader = reader }

  func load() async {
    do {
      let repository = try await NativeAnnotationRepository.shared(api: reader.api)
      if self.repository == nil {
        do { try await repository.synchronize(bookID: reader.bookID) } catch {
          self.error = error.localizedDescription
        }
      }
      self.repository = repository
      items = try await repository.load(bookID: reader.bookID).filter {
        $0.jumpFileId == reader.file.id && $0.deletedAt == nil && $0.kind != "pdf_ink"
      }
      await refreshHighlights()
    } catch { self.error = error.localizedDescription }
  }

  func preview(language: String?) {
    guard let passage = reader.selectedPassage(language: language) else { return }
    open(passage, item: nil)
  }

  func edit(_ item: NativeAnnotationItem) {
    guard let cfi = item.cfi, item.deletedAt == nil else { return }
    open(
      .init(publicationID: reader.publicationID, cfi: cfi, text: item.text, language: "en"),
      item: item)
  }

  private func open(_ passage: EPUBSelectedPassage, item: NativeAnnotationItem?) {
    kind = item?.kind ?? "highlight"
    note = item?.note ?? ""
    drawing =
      item?.drawing?.nativeData.flatMap { Data(base64Encoded: $0) }.flatMap {
        try? PKDrawing(data: $0)
      } ?? PKDrawing()
    fixtureGeneration = 0
    scribbleFixtureGeneration = 0
    error = nil
    mode.isWriting = true
    reader.setAnnotationWriting(true)
    presentation = .init(passage: passage, item: item)
  }

  func cancel() {
    guard !isSaving else { return }
    presentation = nil
    reader.setAnnotationWriting(mode.isWriting)
  }

  var canSave: Bool {
    guard let presentation else { return false }
    return repository != nil && !isSaving
      && reader.publicationID == presentation.passage.publicationID
      && (kind != "text_note" || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      && (kind != "handwriting" || !drawing.strokes.isEmpty)
      && drawing.strokes.count <= 256 && drawing.dataRepresentation().count <= 1_400_000
      && drawing.strokes.reduce(0, { $0 + $1.path.count }) <= 10_000
  }

  func save() {
    Task {
      guard canSave, let presentation, let repository else { return }
      isSaving = true
      defer { isSaving = false }
      do {
        var payload = NativeAnnotationPayload()
        payload.cfi = presentation.passage.cfi
        payload.bookFileId = reader.file.id
        payload.text = presentation.passage.text
        payload.kind = kind
        payload.color = "#FACC15"
        payload.style = "highlight"
        payload.chapterTitle = reader.visibleLocation?.chapterLabel
        if kind == "text_note" { payload.note = note }
        if kind == "handwriting" { payload.drawing = try serializedDrawing() }
        if let item = presentation.item {
          _ = try await repository.mutate(item, action: "update", payload: payload)
        } else {
          _ = try await repository.create(bookID: reader.bookID, payload: payload)
        }
        lastOperationID = repository.lastOperationID
        self.presentation = nil
        await load()
      } catch { self.error = error.localizedDescription }
    }
  }

  func delete() {
    Task {
      guard let item = presentation?.item, let repository, !isSaving else { return }
      isSaving = true
      defer { isSaving = false }
      do {
        lastOperationID = try await repository.mutate(item, action: "delete")
        presentation = nil
        await load()
      } catch { self.error = error.localizedDescription }
    }
  }

  func undo() {
    Task {
      guard let repository, let operation = lastOperationID, !isSaving else { return }
      do {
        let outcome = try await repository.undo(operationID: operation)
        if case .queued = outcome { self.error = outcome.message }
        lastOperationID = nil
        await load()
      } catch { self.error = error.localizedDescription }
    }
  }

  func addFixtureStroke() { fixtureGeneration += 1 }
  func completeFixtureScribble() { scribbleFixtureGeneration += 1 }

  private func serializedDrawing() throws -> NativeAnnotationDrawing {
    let oldIDs = presentation?.item?.drawing?.strokes.map(\.id) ?? []
    let strokes = drawing.strokes.enumerated().map { index, stroke in
      NativeInkStroke(
        id: index < oldIDs.count ? oldIDs[index] : UUID().uuidString,
        points: stroke.path.map { point in
          let transformed = point.location.applying(stroke.transform)
          return NativeInkPoint(
            x: Double(transformed.x), y: Double(transformed.y),
            pressure: min(1, max(0, Double(point.force))))
        }, color: "#111111", width: min(100, max(0.01, Double(stroke.path.first?.size.width ?? 3))))
    }
    return NativeAnnotationDrawing(
      format: "bookorbit-ink-v1", strokes: strokes,
      nativeData: drawing.dataRepresentation().base64EncodedString())
  }

  func refreshHighlights() async {
    await reader.setPassageAnnotations(items)
  }

  func synchronize() async {
    guard let repository else { return }
    do {
      try await repository.synchronize(bookID: reader.bookID)
      await load()
    } catch { self.error = error.localizedDescription }
  }
}
