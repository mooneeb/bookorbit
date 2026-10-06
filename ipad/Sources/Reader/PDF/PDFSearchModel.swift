import Foundation
import Observation
import PDFKit

struct PDFSearchMatch: Identifiable, Sendable {
  let id: Int
  let pageIndex: Int
  let text: String
  let ranges: [NSRange]
}

@MainActor @Observable
final class PDFSearchModel {
  private(set) var matches: [PDFSearchMatch] = []
  private(set) var isSearching = false
  private(set) var hasSearched = false
  private(set) var reachedLimit = false
  private(set) var error: String?
  private let source: PDFDocument
  private var searchDocument: PDFDocument?
  private var observers: [NSObjectProtocol] = []

  init(document: PDFDocument) { source = document }

  func search(_ query: String) {
    clear()
    let phrase = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !phrase.isEmpty, phrase.unicodeScalars.prefix(201).count <= 200 else { return }
    guard let url = source.documentURL, let document = PDFDocument(url: url) else {
      error = "Text search is unavailable for this PDF."
      return
    }
    searchDocument = document
    hasSearched = true
    isSearching = true
    observers.append(
      NotificationCenter.default.addObserver(
        forName: .PDFDocumentDidFindMatch, object: document, queue: .main
      ) { [weak self] notification in
        guard let document = notification.object as? PDFDocument,
          let selection = notification.userInfo?[PDFDocumentFoundSelectionKey] as? PDFSelection,
          let page = selection.pages.first
        else { return }
        let documentID = ObjectIdentifier(document)
        let match = PDFSearchMatch(
          id: 0, pageIndex: document.index(for: page),
          text: String((selection.string ?? "").prefix(200)),
          ranges: (0..<selection.numberOfTextRanges(on: page)).map {
            selection.range(at: $0, on: page)
          })
        MainActor.assumeIsolated { self?.receive(match, documentID: documentID) }
      })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: .PDFDocumentDidEndFind, object: document, queue: .main
      ) { [weak self] notification in
        guard let document = notification.object as? PDFDocument else { return }
        let documentID = ObjectIdentifier(document)
        MainActor.assumeIsolated {
          guard let self, let active = self.searchDocument,
            documentID == ObjectIdentifier(active)
          else {
            return
          }
          self.isSearching = false
        }
      })
    document.beginFindString(phrase, withOptions: [.caseInsensitive, .literal])
  }

  private func receive(_ match: PDFSearchMatch, documentID: ObjectIdentifier) {
    guard isSearching, let document = searchDocument,
      documentID == ObjectIdentifier(document), (0..<source.pageCount).contains(match.pageIndex)
    else { return }
    matches.append(
      PDFSearchMatch(
        id: matches.count, pageIndex: match.pageIndex, text: match.text, ranges: match.ranges))
    if matches.count == 100 {
      reachedLimit = true
      stop()
    }
  }

  func stop() {
    isSearching = false
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    searchDocument?.cancelFindString()
    searchDocument = nil
  }

  func clear() {
    stop()
    matches.removeAll()
    hasSearched = false
    reachedLimit = false
    error = nil
  }
}
