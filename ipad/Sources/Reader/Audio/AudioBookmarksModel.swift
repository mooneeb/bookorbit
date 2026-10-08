import Foundation
import Observation

struct AudioBookmarkPosition {
  let milliseconds: Int
  let chapterID: String?
}

@MainActor @Observable
final class AudioBookmarksModel {
  let api: BookOrbitAPI
  let bookID: Int
  var title = ""
  var note = ""
  private(set) var items: [AudiobookBookmark] = []
  private(set) var nextCursor: String?
  private(set) var isLoading = false
  private(set) var isSaving = false
  private(set) var hasLoaded = false
  private(set) var pageNumber = 1
  private(set) var status: String?
  private(set) var error: String?
  private(set) var editingID: String?
  @ObservationIgnored private let capture: () -> AudioBookmarkPosition?
  private var cursor: String?
  private var previous: [(String?, Int)] = []
  private var generation: UUID?
  private var pendingCreate: CreateAudiobookBookmark?
  private var pendingUpdate: (String, UpdateAudiobookBookmark)?
  private var pendingDelete: String?
  private var isClosed = false

  init(api: BookOrbitAPI, bookID: Int, capture: @escaping () -> AudioBookmarkPosition?) {
    self.api = api
    self.bookID = bookID
    self.capture = capture
  }

  var isBusy: Bool { isLoading || isSaving }
  var hasPrevious: Bool { !previous.isEmpty }
  var hasPendingWrite: Bool { pendingCreate != nil || pendingUpdate != nil || pendingDelete != nil }
  var canClose: Bool { !isBusy && !hasPendingWrite }
  var canSave: Bool {
    !isBusy && hasLoaded && !isClosed && pendingDelete == nil
      && (editingID != nil || pendingCreate != nil || capture() != nil)
      && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && title.unicodeScalars.count <= 500 && note.unicodeScalars.count <= 4000
  }
  var currentPosition: AudioBookmarkPosition? {
    if let pendingCreate {
      return .init(milliseconds: pendingCreate.positionMs, chapterID: pendingCreate.chapterId)
    }
    return capture()
  }

  func load() async { await loadPage(cursor) }

  func firstPage() async {
    guard !isBusy, !hasPendingWrite else { return }
    if await loadPage(nil) {
      pageNumber = 1
      previous.removeAll()
    }
  }

  func nextPage() async {
    guard !isBusy, !hasPendingWrite, let nextCursor else { return }
    let old = (cursor, pageNumber)
    if await loadPage(nextCursor) {
      previous.append(old)
      if previous.count > 32 { previous.removeFirst() }
      pageNumber += 1
    }
  }

  func previousPage() async {
    guard !isBusy, !hasPendingWrite, let old = previous.last else { return }
    if await loadPage(old.0) {
      pageNumber = old.1
      previous.removeLast()
    }
  }

  func beginEditing(_ item: AudiobookBookmark) {
    guard !isBusy, !hasPendingWrite, items.contains(item), !isClosed else { return }
    editingID = item.id
    title = item.title
    note = item.note ?? ""
    status = nil
    error = nil
  }

  func newBookmark() {
    guard !isBusy, !hasPendingWrite, !isClosed else { return }
    editingID = nil
    title = ""
    note = ""
    status = nil
    error = nil
  }

  func save() async {
    guard canSave, let generation else { return }
    isSaving = true
    error = nil
    status = nil
    defer { isSaving = false }
    do {
      if let editingID {
        guard let original = items.first(where: { $0.id == editingID }) else {
          throw ConnectionError.invalidResponse
        }
        let payload =
          pendingUpdate?.1
          ?? UpdateAudiobookBookmark(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            note: note.isEmpty ? .clear : .set(note))
        pendingUpdate = (editingID, payload)
        let saved: AudiobookBookmark = try await api.boundedJSON(
          "audiobooks/\(bookID)/bookmarks/\(editingID)", method: "PATCH",
          body: JSONEncoder().encode(payload), session: generation)
        guard !isClosed else { return }
        try validate(saved)
        let expectedNote: String?
        switch payload.note {
        case .set(let value): expectedNote = value
        case .clear: expectedNote = nil
        case nil: expectedNote = original.note
        }
        guard saved.id == editingID, saved.positionMs == original.positionMs,
          saved.chapterId == original.chapterId, saved.title == payload.title,
          saved.note == expectedNote
        else { throw ConnectionError.invalidResponse }
        if let index = items.firstIndex(where: { $0.id == editingID }) { items[index] = saved }
        pendingUpdate = nil
        title = saved.title
        note = saved.note ?? ""
        status = "Bookmark changes saved."
      } else {
        if pendingCreate == nil {
          guard let point = capture() else { throw ConnectionError.invalidResponse }
          pendingCreate = CreateAudiobookBookmark(
            clientId: UUID().uuidString, positionMs: point.milliseconds, chapterId: point.chapterID,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            note: note.isEmpty ? nil : note)
        }
        guard let payload = pendingCreate else { throw ConnectionError.invalidResponse }
        let saved: AudiobookBookmark = try await api.boundedJSON(
          "audiobooks/\(bookID)/bookmarks", method: "POST", body: JSONEncoder().encode(payload),
          session: generation)
        guard !isClosed else { return }
        try validate(saved)
        guard saved.id.lowercased() == payload.clientId.lowercased(),
          saved.positionMs == payload.positionMs, saved.chapterId == payload.chapterId,
          saved.title == payload.title, saved.note == payload.note
        else {
          throw ConnectionError.invalidResponse
        }
        pendingCreate = nil
        status = "Bookmarked \(AudioPlaybackModel.clock(Double(saved.positionMs) / 1000))."
        title = ""
        note = ""
        isSaving = false
        await firstPage()
      }
    } catch {
      if !isClosed {
        self.error =
          "The bookmark save could not be confirmed. Retry Save with the same draft. \(error.localizedDescription)"
      }
    }
  }

  func remove(_ item: AudiobookBookmark) async {
    guard !isBusy, !isClosed, pendingCreate == nil, pendingUpdate == nil,
      pendingDelete == nil || pendingDelete == item.id, items.contains(item),
      let generation
    else { return }
    isSaving = true
    error = nil
    status = nil
    pendingDelete = item.id
    defer { isSaving = false }
    do {
      do {
        try await api.sendEmpty(
          "audiobooks/\(bookID)/bookmarks/\(item.id)", method: "DELETE", session: generation)
      } catch ConnectionError.http(404) {
      }
      guard !isClosed else { return }
      pendingDelete = nil
      items.removeAll { $0.id == item.id }
      if editingID == item.id {
        editingID = nil
        title = ""
        note = ""
      }
      status = "Bookmark removed."
      isSaving = false
      await firstPage()
    } catch {
      if !isClosed {
        self.error = "Removal could not be confirmed. Retry Remove. \(error.localizedDescription)"
      }
    }
  }

  func canRemove(_ item: AudiobookBookmark) -> Bool {
    !isBusy && !isClosed && pendingCreate == nil && pendingUpdate == nil
      && (pendingDelete == nil || pendingDelete == item.id)
  }

  func discardPending() async {
    guard !isBusy, !isClosed else { return }
    pendingCreate = nil
    pendingUpdate = nil
    pendingDelete = nil
    editingID = nil
    title = ""
    note = ""
    status = nil
    hasLoaded = false
    items = []
    nextCursor = nil
    await firstPage()
  }

  func close() { isClosed = true }

  @discardableResult
  private func loadPage(_ requested: String?) async -> Bool {
    guard !isBusy, !hasPendingWrite, !isClosed else { return false }
    isLoading = true
    error = nil
    defer { isLoading = false }
    do {
      let session: UUID
      if let generation {
        session = generation
      } else {
        session = try await api.authenticatedSessionGeneration()
        generation = session
      }
      var query = [URLQueryItem(name: "limit", value: "40")]
      if let requested { query.append(URLQueryItem(name: "afterId", value: requested)) }
      let response: AudiobookBookmarksPage = try await api.boundedJSON(
        "audiobooks/\(bookID)/bookmarks/page", query: query,
        byteLimit: 2 * 1024 * 1024, session: session)
      guard !isClosed else { return false }
      guard response.items.count <= 40, Set(response.items.map(\.id)).count == response.items.count,
        response.nextCursor == nil || response.nextCursor == response.items.last?.id,
        response.nextCursor != requested || response.nextCursor == nil
      else {
        throw ConnectionError.invalidResponse
      }
      for item in response.items { try validate(item) }
      guard
        zip(response.items, response.items.dropFirst()).allSatisfy({
          $0.positionMs <= $1.positionMs
        })
      else {
        throw ConnectionError.invalidResponse
      }
      items = response.items
      cursor = requested
      nextCursor = response.nextCursor
      hasLoaded = true
      if let editingID, !items.contains(where: { $0.id == editingID }) {
        self.editingID = nil
        title = ""
        note = ""
      }
      return true
    } catch {
      if !isClosed { self.error = error.localizedDescription }
      return false
    }
  }

  private func validate(_ item: AudiobookBookmark) throws {
    guard UUID(uuidString: item.id) != nil, item.bookId == bookID, item.positionMs >= 0,
      item.positionMs <= 9_007_199_254_740_991, item.title.unicodeScalars.count <= 500,
      !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      item.note.map({ $0.unicodeScalars.count <= 4000 }) ?? true,
      item.chapterId.map({ !$0.isEmpty && $0.unicodeScalars.count <= 80 }) ?? true
    else {
      throw ConnectionError.invalidResponse
    }
  }
}
