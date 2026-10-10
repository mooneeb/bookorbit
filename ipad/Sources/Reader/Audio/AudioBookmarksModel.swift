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
  let fileID: Int?
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
  private var outbox: OfflineBookmarkOutbox?

  init(
    api: BookOrbitAPI, bookID: Int, fileID: Int? = nil,
    capture: @escaping () -> AudioBookmarkPosition?
  ) {
    self.api = api
    self.bookID = bookID
    self.fileID = fileID
    self.capture = capture
  }

  var isBusy: Bool { isLoading || isSaving }
  var hasPrevious: Bool { !previous.isEmpty }
  var hasPendingWrite: Bool { pendingCreate != nil || pendingUpdate != nil || pendingDelete != nil }
  var canClose: Bool { !isBusy }
  var canSave: Bool {
    !isBusy && hasLoaded && !isClosed && outbox?.canWrite == true && pendingDelete == nil
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
    guard canSave, let generation, let outbox else { return }
    isSaving = true
    error = nil
    status = nil
    defer { isSaving = false }
    do {
      try await outbox.checkSession(generation)
      let id = UUID()
      let audioID: String
      let body: Data
      let path: String
      let method: String
      var local: AudiobookBookmark
      if let editingID {
        guard let original = items.first(where: { $0.id == editingID }) else {
          throw ConnectionError.invalidResponse
        }
        audioID = editingID
        let payload = UpdateAudiobookBookmark(
          title: title.trimmingCharacters(in: .whitespacesAndNewlines),
          note: note.isEmpty ? .clear : .set(note))
        body = try JSONEncoder().encode(payload)
        path = "audiobooks/\(bookID)/bookmarks/\(editingID)"
        method = "PATCH"
        local = original
        local.title = payload.title ?? original.title
        local.note = note.isEmpty ? nil : note
      } else {
        guard let point = capture() else { throw ConnectionError.invalidResponse }
        audioID = id.uuidString
        let payload = CreateAudiobookBookmark(
          clientId: audioID, positionMs: point.milliseconds,
          chapterId: point.chapterID, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
          note: note.isEmpty ? nil : note)
        body = try JSONEncoder().encode(payload)
        path = "audiobooks/\(bookID)/bookmarks"
        method = "POST"
        let date = ISO8601DateFormatter().string(from: Date())
        local = AudiobookBookmark(
          id: audioID, bookId: bookID, positionMs: payload.positionMs,
          chapterId: payload.chapterId, title: payload.title, note: payload.note, createdAt: date,
          updatedAt: date)
      }
      try outbox.update { state in
        state.operations.append(
          OfflineBookmarkOperation(
            id: id, path: path, method: method,
            body: body, localID: nil, audioID: audioID))
        state.audioItems.removeAll { $0.id == audioID }
        state.audioItems.insert(local, at: 0)
        state.audioItems = Array(state.audioItems.prefix(40))
      }
      items = outbox.state.audioItems
      title = ""
      note = ""
      editingID = nil
      do {
        try await outbox.flush(session: generation)
        items = outbox.state.audioItems
        status = "Bookmark saved."
      } catch is URLError {
        status = "Bookmark saved on this iPad. It will sync when connected."
      }
    } catch { if !isClosed { self.error = error.localizedDescription } }
  }

  func remove(_ item: AudiobookBookmark) async {
    guard canRemove(item), items.contains(item), let generation, let outbox else { return }
    isSaving = true
    error = nil
    defer { isSaving = false }
    do {
      try await outbox.checkSession(generation)
      try outbox.update { state in
        let create = state.operations.first { $0.audioID == item.id && $0.method == "POST" }
        if let create {
          if create.transmitted,
            let index = state.operations.firstIndex(where: { $0.id == create.id })
          {
            state.operations[index].cancelAfterCreate = true
          } else {
            state.operations.removeAll { $0.id == create.id }
          }
        } else {
          state.operations.append(
            OfflineBookmarkOperation(
              id: UUID(),
              path: "audiobooks/\(bookID)/bookmarks/\(item.id)", method: "DELETE", body: nil,
              localID: nil, audioID: item.id))
        }
        state.recoveryOperations.removeAll { $0.audioID == item.id }
        state.audioItems.removeAll { $0.id == item.id }
      }
      items = outbox.state.audioItems
      if editingID == item.id {
        editingID = nil
        title = ""
        note = ""
      }
      do {
        try await outbox.flush(session: generation)
        status = "Bookmark removed."
      } catch is URLError {
        status = "Removal saved on this iPad. It will sync when connected."
      }
    } catch { if !isClosed { self.error = error.localizedDescription } }
  }

  func canRemove(_ item: AudiobookBookmark) -> Bool {
    !isBusy && !isClosed && outbox?.canWrite == true && pendingCreate == nil && pendingUpdate == nil
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
      if outbox == nil {
        outbox = try await OfflineBookmarkOutbox.open(
          api: api, bookID: bookID, fileID: fileID, channel: "audio")
      }
      if let outbox {
        try await outbox.checkSession(session)
        do { try await outbox.flush(session: session) } catch is URLError {}
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
      let pendingIDs = Set(
        (outbox?.state.operations.compactMap(\.audioID) ?? [])
          + (outbox?.state.deletedAudioIDs ?? []))
      let local = outbox?.state.audioItems.filter { pendingIDs.contains($0.id) } ?? []
      items = local + response.items.filter { !pendingIDs.contains($0.id) }
      try outbox?.update { $0.audioItems = Array(items.prefix(40)) }
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
      if !isClosed, let outbox {
        items = outbox.state.audioItems
        hasLoaded = true
        if error is URLError {
          status = "Bookmarks saved on this iPad. Connect to sync pending changes."
        } else {
          self.error =
            "Pending bookmarks remain on this iPad for review. \(error.localizedDescription)"
        }
        return true
      }
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
