import Foundation
import Observation

struct AnnotationHubReaderDestination: Identifiable {
  let id = UUID()
  let book: BookDetail
  let file: BookDetailFile
  let annotation: NativeAnnotationItem
  let repairing: Bool
  var recoveryDraft: NativeAnnotationRecoveryDraft? = nil
}

struct AnnotationHubGroup: Identifiable {
  let id: String
  let title: String
  var items: [NativeAnnotationHubItem]
}

enum AnnotationHubRepairFormat {
  case pdf
  case reflowable

  func supports(_ file: BookDetailFile) -> Bool {
    let format = file.format?.lowercased() ?? ""
    switch self {
    case .pdf: return format == "pdf"
    case .reflowable: return NativeEbookVocabulary.mimeTypes[format] != nil
    }
  }
}

@MainActor @Observable
final class AnnotationHubModel {
  let api: BookOrbitAPI
  let userID: Int
  private(set) var repository: NativeAnnotationRepository?
  private(set) var items: [NativeAnnotationHubItem] = []
  private(set) var nextCursor: Int?
  private(set) var isBusy = false
  private(set) var page = 1
  private var cursor: Int?
  private var previousCursors: [Int?] = []
  private var attempt = UUID()
  private var undoOperations: [UUID] = []
  var search = ""
  var kind = ""
  var status = "active"
  var groupBy = "book"
  var bookID: Int?
  var bookTitle: String?
  var selected: Set<Int> = []
  var detail: NativeAnnotationHubItem?
  var reader: AnnotationHubReaderDestination?
  var repairBook: BookDetail?
  private var repairDraft: NativeAnnotationRecoveryDraft?
  var error: String?
  var notice: String?

  init(api: BookOrbitAPI, userID: Int) {
    self.api = api
    self.userID = userID
  }

  var canGoBack: Bool { !previousCursors.isEmpty }
  var canUndo: Bool { !undoOperations.isEmpty }
  var repairKind: String {
    repairDraft?.operation.payload?.kind ?? repairDraft?.item?.kind ?? detail?.kind ?? "text_note"
  }
  var repairFormat: AnnotationHubRepairFormat {
    if let draft = repairDraft {
      let payload = draft.operation.payload
      let fileID = payload?.bookFileId ?? draft.item?.jumpFileId
      let fileFormat = repairBook?.files.first { $0.id == fileID }?.format
      return repairKind == "pdf_ink" || payload?.pdf != nil || draft.item?.pdf != nil
        || fileFormat?.lowercased() == "pdf" ? .pdf : .reflowable
    }
    return repairKind == "pdf_ink" || detail?.pdf != nil
      || detail?.fileFormat?.lowercased() == "pdf" ? .pdf : .reflowable
  }
  var selectedItems: [NativeAnnotationHubItem] { items.filter { selected.contains($0.id) } }
  var groups: [AnnotationHubGroup] {
    var groups: [AnnotationHubGroup] = []
    for item in items {
      if groups.last?.id == item.groupKey {
        groups[groups.count - 1].items.append(item)
      } else {
        let title: String
        switch groupBy {
        case "book": title = item.bookTitle ?? String(localized: "Untitled book")
        case "kind": title = AnnotationHubLabels.kind(item.kind)
        case "source": title = AnnotationHubLabels.source(item.origin)
        default: title = item.groupKey
        }
        groups.append(.init(id: item.groupKey, title: title, items: [item]))
      }
    }
    return groups
  }

  func load(reset: Bool = false) async {
    if reset {
      cursor = nil
      previousCursors = []
      page = 1
      selected = []
    }
    let attempt = UUID()
    self.attempt = attempt
    isBusy = true
    error = nil
    defer { if self.attempt == attempt { isBusy = false } }
    do {
      guard search.utf16.count <= 200 else {
        throw AnnotationHubError(
          message: String(localized: "Search must be 200 characters or fewer."))
      }
      let repository = try await NativeAnnotationRepository.shared(api: api)
      guard self.attempt == attempt else { return }
      self.repository = repository
      var query = [
        URLQueryItem(name: "limit", value: "40"),
        URLQueryItem(name: "status", value: status),
        URLQueryItem(name: "groupBy", value: groupBy),
      ]
      if !search.isEmpty { query.append(.init(name: "search", value: search)) }
      if !kind.isEmpty { query.append(.init(name: "kind", value: kind)) }
      if let cursor { query.append(.init(name: "cursor", value: String(cursor))) }
      if let bookID { query.append(.init(name: "bookId", value: String(bookID))) }
      let response = try await repository.queryHub(query: query)
      guard self.attempt == attempt else { return }
      guard response.items.count <= 40,
        Set(response.items.map(\.id)).count == response.items.count,
        response.nextCursor == nil || response.nextCursor != cursor
      else { throw ConnectionError.invalidResponse }
      items = response.items
      nextCursor = response.nextCursor
      if repository.error != nil {
        notice = String(
          localized:
            "Showing annotations saved on this iPad. Synchronize when the server is available.")
      }
      selected.formIntersection(Set(items.map(\.id)))
      if let detail { self.detail = items.first { $0.id == detail.id } }
    } catch {
      if self.attempt == attempt { self.error = error.localizedDescription }
    }
  }

  func next() async {
    guard !isBusy, let nextCursor else { return }
    previousCursors.append(cursor)
    cursor = nextCursor
    page += 1
    selected = []
    await load()
  }

  func previous() async {
    guard !isBusy, !previousCursors.isEmpty else { return }
    cursor = previousCursors.removeLast()
    page -= 1
    selected = []
    await load()
  }

  func toggleSelection(_ item: NativeAnnotationHubItem) {
    if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
  }

  func showBook(_ item: NativeAnnotationHubItem) async {
    bookID = item.bookId
    bookTitle = item.bookTitle
    detail = nil
    await load(reset: true)
  }

  func clearBook() async {
    bookID = nil
    bookTitle = nil
    await load(reset: true)
  }

  func mutateSelection(action: String) async {
    guard !isBusy, let repository, !selectedItems.isEmpty else { return }
    let chosen = selectedItems
    isBusy = true
    error = nil
    notice = nil
    var operations: [UUID] = []
    do {
      for item in chosen {
        let operation = try await repository.mutate(try item.canonical(), action: action)
        operations.append(operation)
        selected.remove(item.id)
      }
      undoOperations = operations
      notice = String(localized: "Changes saved on this iPad. Synchronize to send pending work.")
    } catch {
      undoOperations = operations
      self.error = error.localizedDescription
      notice =
        operations.isEmpty
        ? nil
        : String(localized: "Some changes were saved. The remaining items are still selected.")
    }
    isBusy = false
    await reloadAfterMutation()
  }

  func mutateDetail(action: String) async {
    guard let detail else { return }
    selected = [detail.id]
    await mutateSelection(action: action)
  }

  func undo() async {
    guard !isBusy, let repository, !undoOperations.isEmpty else { return }
    isBusy = true
    error = nil
    notice = nil
    do {
      var queued = false
      while let operation = undoOperations.last {
        let outcome = try await repository.undo(operationID: operation)
        if case .queued = outcome { queued = true }
        undoOperations.removeLast()
      }
      notice =
        queued
        ? NativeAnnotationUndoOutcome.queued.message
        : String(localized: "Undo saved.")
    } catch { self.error = error.localizedDescription }
    isBusy = false
    await reloadAfterMutation()
  }

  func synchronize() async {
    guard !isBusy, let repository else { return }
    isBusy = true
    error = nil
    notice = nil
    do {
      if repository.pendingCount > 0 {
        await repository.synchronizePending()
        if let error = repository.error { throw AnnotationHubError(message: error) }
      }
      for bookID in Set(items.map(\.bookId)).sorted() {
        try await repository.synchronize(bookID: bookID)
      }
      notice = String(localized: "Synchronization finished for the books on this page.")
    } catch { self.error = error.localizedDescription }
    isBusy = false
    await reloadAfterMutation()
  }

  func openPassage(_ item: NativeAnnotationHubItem) async {
    guard !isBusy, item.deletedAt == nil else { return }
    isBusy = true
    error = nil
    notice = nil
    defer { isBusy = false }
    do {
      guard let fileID = item.jumpFileId else {
        throw AnnotationHubError(
          message: String(localized: "This annotation needs a repaired passage before it can open.")
        )
      }
      let book: BookDetail = try await api.boundedJSON(
        "books/\(item.bookId)", byteLimit: 2 * 1024 * 1024)
      guard book.id == item.bookId, let file = book.files.first(where: { $0.id == fileID }) else {
        throw ConnectionError.fileChanged
      }
      guard
        item.cfi != nil || item.pdf != nil
          || (file.format?.lowercased() == "pdf" && item.pageno != nil)
      else {
        throw AnnotationHubError(
          message: String(localized: "This annotation needs a repaired passage before it can open.")
        )
      }
      reader = .init(book: book, file: file, annotation: try item.canonical(), repairing: false)
    } catch { self.error = error.localizedDescription }
  }

  func beginRepair(_ item: NativeAnnotationHubItem) async {
    guard !isBusy, item.deletedAt == nil else { return }
    isBusy = true
    error = nil
    defer { isBusy = false }
    do {
      let book: BookDetail = try await api.boundedJSON(
        "books/\(item.bookId)", byteLimit: 2 * 1024 * 1024)
      guard book.id == item.bookId else { throw ConnectionError.invalidResponse }
      repairDraft = nil
      detail = item
      repairBook = book
    } catch { self.error = error.localizedDescription }
  }

  func chooseRepairFile(_ file: BookDetailFile) {
    guard let book = repairBook,
      let file = book.files.first(where: { $0.id == file.id }), repairFormat.supports(file)
    else { return }
    do {
      if let draft = repairDraft {
        reader = .init(
          book: book, file: file, annotation: try recoveryItem(draft), repairing: true,
          recoveryDraft: draft)
      } else if let detail {
        reader = .init(book: book, file: file, annotation: try detail.canonical(), repairing: true)
      } else {
        return
      }
      repairBook = nil
    } catch { self.error = error.localizedDescription }
  }

  func repairHere(_ payload: NativeAnnotationPayload) async {
    guard let reader, reader.repairing, let repository, !isBusy else { return }
    isBusy = true
    error = nil
    notice = nil
    do {
      if let draft = reader.recoveryDraft {
        let retained = try recoveryItem(draft)
        var repaired = payload
        repaired.kind = retained.kind
        repaired.drawing = retained.drawing
        repaired.note = retained.note
        repaired.color = retained.color
        repaired.style = retained.style
        _ = try await repository.create(bookID: draft.bookId, payload: repaired)
        undoOperations = repository.lastOperationID.map { [$0] } ?? []
        notice = String(
          localized: "A new annotation was explicitly attached. The recovery draft is preserved.")
      } else {
        let operation = try await repository.mutate(
          reader.annotation, action: "repair", payload: payload)
        undoOperations = [operation]
        notice = String(
          localized:
            "The selected passage was saved as an explicit repair. Synchronize to publish it.")
      }
      self.reader = nil
      detail = nil
    } catch { self.error = error.localizedDescription }
    isBusy = false
    await reloadAfterMutation()
  }

  func beginDraftRepair(_ draft: NativeAnnotationRecoveryDraft) async {
    guard !isBusy else { return }
    isBusy = true
    error = nil
    defer { isBusy = false }
    do {
      guard draft.item != nil
      else {
        throw AnnotationHubError(
          message: String(
            localized:
              "This draft needs its original annotation details before it can be attached. Export it to preserve the saved operation."
          ))
      }
      let book: BookDetail = try await api.boundedJSON(
        "books/\(draft.bookId)", byteLimit: 2 * 1024 * 1024)
      guard book.id == draft.bookId else { throw ConnectionError.invalidResponse }
      repairDraft = draft
      repairBook = book
    } catch { self.error = error.localizedDescription }
  }

  private func recoveryItem(_ draft: NativeAnnotationRecoveryDraft) throws -> NativeAnnotationItem {
    let payload = draft.operation.payload
    guard var item = draft.item else {
      throw AnnotationHubError(
        message: String(
          localized:
            "The original annotation details are unavailable. Export this draft for manual recovery."
        ))
    }
    item.drawing = payload?.drawing ?? item.drawing
    item.note = payload?.note ?? item.note
    item.text = payload?.text ?? item.text
    return item
  }

  private func reloadAfterMutation() async {
    let failure = error
    await load()
    if let failure { error = failure }
  }

  func exportSelection(items: [NativeAnnotationHubItem]? = nil) throws
    -> AnnotationHubExportDocument
  {
    let chosen = items ?? (selectedItems.isEmpty ? detail.map { [$0] } ?? [] : selectedItems)
    guard !chosen.isEmpty, chosen.count <= 100 else {
      throw AnnotationHubError(message: String(localized: "Select annotations to export."))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let date = ISO8601DateFormatter().string(from: Date())
    var data = Data(
      "{\"format\":\"bookorbit-annotations-v1\",\"exportedAt\":\"\(date)\",\"userId\":\(userID),\"nextCursor\":null,\"items\":["
        .utf8)
    for (index, item) in chosen.enumerated() {
      let entry = try encoder.encode(item)
      guard data.count + entry.count + 3 <= AnnotationHubExportDocument.byteLimit else {
        throw AnnotationHubError(
          message: String(
            localized: "This export is too large. Export fewer annotations at a time."))
      }
      if index > 0 { data.append(Data(",".utf8)) }
      data.append(entry)
    }
    data.append(Data("]}".utf8))
    return .init(data: data)
  }
}

struct AnnotationHubError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

extension NativeAnnotationHubItem {
  func canonical() throws -> NativeAnnotationItem {
    try JSONDecoder().decode(NativeAnnotationItem.self, from: JSONEncoder().encode(self))
  }
}

enum AnnotationHubLabels {
  static func date(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }

  static func kind(_ kind: String) -> String {
    switch kind {
    case "text_note": String(localized: "Text note")
    case "handwriting": String(localized: "Handwritten note")
    case "pdf_ink": String(localized: "PDF ink")
    default: String(localized: "Highlight")
    }
  }

  static func source(_ source: String) -> String {
    switch source {
    case "kobo": "Kobo"
    case "koreader": "KOReader"
    default: String(localized: "BookOrbit")
    }
  }
}
