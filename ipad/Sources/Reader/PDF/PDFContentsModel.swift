import Foundation
import Observation
import PDFKit

struct PDFContentsEntry: Identifiable {
  let id: Int
  let title: String
  let pageIndex: Int?
  let outline: PDFOutline
  var hasChildren: Bool { outline.numberOfChildren > 0 }
}

@MainActor @Observable
final class PDFContentsModel {
  private let document: PDFDocument
  private var levels: [(outline: PDFOutline, offset: Int)] = []
  private(set) var entries: [PDFContentsEntry] = []
  private(set) var error: String?
  private let pageSize = 100

  init(document: PDFDocument) {
    self.document = document
    if let root = document.outlineRoot { levels = [(root, 0)] }
    loadEntries()
  }

  var canGoBack: Bool { levels.count > 1 }
  var canGoPrevious: Bool { (levels.last?.offset ?? 0) > 0 }
  var canGoNext: Bool {
    guard let level = levels.last else { return false }
    return level.outline.numberOfChildren - level.offset > pageSize
  }
  var sectionTitle: String? {
    guard canGoBack, let outline = levels.last?.outline else { return nil }
    return title(for: outline)
  }

  func openChildren(_ entry: PDFContentsEntry) {
    guard entry.hasChildren else { return }
    guard levels.count < 64, !levels.contains(where: { $0.outline === entry.outline }) else {
      error = "These sections cannot be opened. Choose a different section."
      return
    }
    levels.append((entry.outline, 0))
    loadEntries()
  }

  func goBack() {
    guard canGoBack else { return }
    levels.removeLast()
    loadEntries()
  }

  func previousSections() {
    guard canGoPrevious else { return }
    levels[levels.count - 1].offset -= pageSize
    loadEntries()
  }

  func nextSections() {
    guard canGoNext else { return }
    levels[levels.count - 1].offset += pageSize
    loadEntries()
  }

  private func loadEntries() {
    entries = []
    error = nil
    guard let level = levels.last else { return }
    let end = min(level.offset + pageSize, level.outline.numberOfChildren)
    for index in level.offset..<end {
      guard let outline = level.outline.child(at: index) else { continue }
      let destination = (outline.action as? PDFActionGoTo)?.destination ?? outline.destination
      let pageIndex = (destination?.page).map { document.index(for: $0) }
      entries.append(
        PDFContentsEntry(
          id: index, title: title(for: outline),
          pageIndex: pageIndex.flatMap { (0..<document.pageCount).contains($0) ? $0 : nil },
          outline: outline))
    }
  }

  private func title(for outline: PDFOutline) -> String {
    let label = outline.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return label.isEmpty ? "Untitled section" : String(label.prefix(200))
  }
}
