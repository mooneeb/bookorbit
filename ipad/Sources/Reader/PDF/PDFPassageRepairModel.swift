import Foundation
import Observation
import PDFKit

struct PDFPassageRepairPreview {
  let page: Int
  let text: String
  let position: AnnotationPdfPosition
  let selection: PDFSelection
  let sourceRevision: String
  let pageFingerprint: String
}

@MainActor @Observable
final class PDFPassageRepairModel {
  let original: NativeAnnotationItem
  private(set) var preview: PDFPassageRepairPreview?
  private(set) var selectedText = ""
  private(set) var error: String?
  private(set) var isPreparing = false
  private(set) var isConfirmed = false
  var fixtureGeneration = 0
  private var selection: PDFSelection?
  private var document: PDFDocument?
  private var generation = UUID()
  private var source: PDFSourceInkEditor?

  init(original: NativeAnnotationItem) { self.original = original }

  var canPreview: Bool {
    !selectedText.isEmpty && preview == nil && !isPreparing && !isConfirmed
  }
  var locksPage: Bool { preview != nil || isPreparing }

  func bind(document: PDFDocument, source: PDFSourceInkEditor) {
    self.document = document
    self.source = source
  }

  func selected(_ value: PDFSelection?) {
    guard preview == nil, !isPreparing, !isConfirmed else { return }
    selection = value?.copy() as? PDFSelection
    selectedText = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    error = nil
  }

  func previewSelection() {
    guard canPreview, let selection, let document, let source else { return }
    let attempt = UUID()
    generation = attempt
    isPreparing = true
    Task {
      defer { if generation == attempt { isPreparing = false } }
      do {
        guard selection.pages.count == 1, let page = selection.pages.first else {
          throw PDFPassageRepairError(message: "Select a passage on one PDF page.")
        }
        guard selectedText.utf16.count <= 10_000 else {
          throw PDFPassageRepairError(
            message: "Select a shorter passage before repairing its location.")
        }
        let index = document.index(for: page)
        guard index != NSNotFound, (0..<document.pageCount).contains(index) else {
          throw PDFPassageRepairError(message: "Select a passage in this document.")
        }
        let descriptor = try await source.sourceForPassageRepair(page: index)
        guard generation == attempt, !isConfirmed else { return }
        let position = try PDFPassageRepairGeometry.position(
          selection: selection, page: page,
          index: index, source: descriptor)
        preview = PDFPassageRepairPreview(
          page: index, text: selectedText,
          position: position, selection: selection, sourceRevision: descriptor.sourceRevision,
          pageFingerprint: descriptor.pageFingerprint)
        error = nil
      } catch {
        if generation == attempt { self.error = error.localizedDescription }
      }
    }
  }

  func confirmedPayload() async -> NativeAnnotationPayload? {
    guard !isConfirmed, !isPreparing, let preview, let source else { return nil }
    isPreparing = true
    defer { isPreparing = false }
    do {
      let descriptor = try await source.sourceForPassageRepair(page: preview.page)
      guard descriptor.pageFingerprint == preview.pageFingerprint else {
        throw PDFPassageRepairError(message: "The page changed. Select the passage again.")
      }
      var payload = NativeAnnotationPayload()
      payload.text = preview.text
      payload.bookFileId = source.fileID
      payload.pdf = preview.position
      payload.sourceRevision = descriptor.sourceRevision
      payload.pageFingerprint = descriptor.pageFingerprint
      isConfirmed = true
      return payload
    } catch {
      self.error = error.localizedDescription
      return nil
    }
  }

  func cancelPreview() {
    generation = UUID()
    isPreparing = false
    preview = nil
    selectedText = ""
    selection = nil
    error = nil
  }

  func changedPage() {
    if !isConfirmed { cancelPreview() }
  }

  func feedFixtureSelection() {
    cancelPreview()
    fixtureGeneration += 1
  }
}

struct PDFPassageRepairError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

enum PDFPassageRepairGeometry {
  static func position(
    selection: PDFSelection, page: PDFPage, index: Int,
    source: NativePdfPageSource
  ) throws -> AnnotationPdfPosition {
    let crop = page.bounds(for: .cropBox)
    let rotation = ((page.rotation % 360) + 360) % 360
    func point(_ value: CGPoint) -> CGPoint {
      switch rotation {
      case 90: return CGPoint(x: value.y - crop.minY, y: value.x - crop.minX)
      case 180: return CGPoint(x: crop.maxX - value.x, y: value.y - crop.minY)
      case 270: return CGPoint(x: crop.maxY - value.y, y: crop.maxX - value.x)
      default: return CGPoint(x: value.x - crop.minX, y: crop.maxY - value.y)
      }
    }
    func normalized(_ value: CGRect) -> AnnotationRect? {
      let rect = value.intersection(crop)
      guard !rect.isNull, !rect.isEmpty else { return nil }
      let corners = [
        CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
        CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
      ].map(point)
      let xs = corners.map(\.x)
      let ys = corners.map(\.y)
      guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(),
        [minX, maxX, minY, maxY].allSatisfy(\.isFinite),
        minX >= 0, minY >= 0, maxX <= source.width + 0.01, maxY <= source.height + 0.01
      else { return nil }
      return AnnotationRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
    guard let bounds = normalized(selection.bounds(for: page)) else {
      throw PDFPassageRepairError(message: "The selected passage is outside this page.")
    }
    let lines = selection.selectionsByLine()
    guard lines.count <= 500 else {
      throw PDFPassageRepairError(
        message: "Select a shorter passage before repairing its location.")
    }
    let rects = lines.compactMap { normalized($0.bounds(for: page)) }
    guard !rects.isEmpty else {
      throw PDFPassageRepairError(
        message: "Select readable PDF text before repairing its location.")
    }
    return AnnotationPdfPosition(page: index, rect: bounds, rects: rects)
  }
}
