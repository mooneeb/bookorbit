import Foundation
import Observation

enum EPUBBookmarkOrder: String, CaseIterable, Identifiable {
  case location
  case newest
  case oldest

  var id: String { rawValue }
  var label: String {
    switch self {
    case .location: "Reading order"
    case .newest: "Newest"
    case .oldest: "Oldest"
    }
  }
}

@MainActor @Observable
final class EPUBBookmarksModel {
  let reader: EPUBReaderModel
  let cfi: String
  var title: String
  private(set) var query = ""
  private(set) var order = EPUBBookmarkOrder.location
  private(set) var items: [EpubBookmarkNavigationItem] = []
  private(set) var nextCursor: String?
  private(set) var currentBookmarkID: Int?
  private(set) var pageNumber = 1
  private(set) var hasLoaded = false
  private(set) var scanLimited = false
  private(set) var isLoading = false
  private(set) var isSaving = false
  private(set) var isOpening = false
  private(set) var needsPositionSave = false
  private(set) var queryError: String?
  private(set) var error: String?
  private(set) var openingError: String?
  private(set) var status: String?
  private(set) var canUseBookmarks: Bool?
  private let publicationID: UUID
  private let currentCFI: String?
  private var generation: UUID?
  private var fileRevision: String?
  private var requestID: UUID?
  private var requestTask: Task<Bool, Never>?
  private var cursor: String?
  private var retryCursor: String?
  private var previousCursors: [String?] = []
  private var pendingTitle: String?
  private var selectedForOpening: EpubBookmarkNavigationItem?
  private var isClosed = false
  private var sessionValid = true
  private var outbox: OfflineBookmarkOutbox?

  init(reader: EPUBReaderModel, cfi: String, title: String) {
    self.reader = reader
    self.cfi = cfi
    self.title = title
    publicationID = reader.publicationID
    currentCFI = reader.visibleLocation?.cfi
  }

  var isBusy: Bool { isLoading || isSaving || isOpening }
  var hasPendingSave: Bool { pendingTitle != nil }
  var hasPrevious: Bool { !previousCursors.isEmpty }
  var isCurrentPublication: Bool {
    !isClosed && sessionValid && reader.isReady && reader.publicationID == publicationID
  }
  var canBrowse: Bool {
    isCurrentPublication && canUseBookmarks != false && !isSaving && !isOpening && !hasPendingSave
      && !needsPositionSave
  }
  var canSelect: Bool { canBrowse && !isLoading }
  var canRemove: Bool { canSelect && outbox?.canWrite == true }
  var canSave: Bool {
    hasLoaded && isCurrentPublication && canUseBookmarks == true && outbox?.canWrite == true
      && !isBusy && !needsPositionSave
      && cfi.hasPrefix("epubcfi(") && cfi.utf16.count <= 2000
      && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && title.unicodeScalars.count <= 500
  }
  var canRetryOpening: Bool { selectedForOpening != nil && !isBusy && isCurrentPublication }
  var normalizedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

  func setQuery(_ value: String) {
    guard canBrowse, query != value else { return }
    query = value
    resetPages()
    if query.unicodeScalars.count > 200 {
      cancelRequest()
      queryError = "Use a search of 200 characters or fewer."
      return
    }
    _ = startLoad(nil, debounced: !normalizedQuery.isEmpty)
  }

  func clearQuery() { setQuery("") }

  func setOrder(_ value: EPUBBookmarkOrder) {
    guard canBrowse, order != value else { return }
    order = value
    resetPages()
    guard query.unicodeScalars.count <= 200 else { return }
    _ = startLoad(nil)
  }

  func load() async {
    guard canBrowse, query.unicodeScalars.count <= 200 else { return }
    _ = await startLoad(cursor).value
  }

  func retry() async {
    guard canBrowse, query.unicodeScalars.count <= 200 else { return }
    _ = await startLoad(retryCursor).value
  }

  func nextPage() async {
    guard canSelect, let nextCursor else { return }
    let old = cursor
    let task = startLoad(nextCursor)
    let id = requestID
    if await task.value, requestID == id {
      previousCursors.append(old)
      if previousCursors.count > 32 { previousCursors.removeFirst() }
      pageNumber += 1
    }
  }

  func previousPage() async {
    guard canSelect, let previous = previousCursors.last else { return }
    let task = startLoad(previous)
    let id = requestID
    if await task.value, requestID == id {
      previousCursors.removeLast()
      pageNumber = max(1, pageNumber - 1)
    }
  }

  func firstPage() async {
    guard canBrowse, query.unicodeScalars.count <= 200 else { return }
    let task = startLoad(nil)
    let id = requestID
    if await task.value, requestID == id {
      previousCursors = []
      pageNumber = 1
    }
  }

  func save() async {
    guard canSave, let generation, let outbox else { return }
    isSaving = true
    error = nil
    status = nil
    defer { isSaving = false }
    do {
      try await ensureSession(generation)
      try await outbox.checkSession(generation)
      let id = UUID()
      let localID = OfflineBookmarkOutbox.temporaryID(id)
      let payload = CreateEpubBookmarkPayload(
        cfi: cfi, title: title.trimmingCharacters(in: .whitespacesAndNewlines))
      let body = try JSONEncoder().encode(
        OfflineIdentifiedBookmark(payload: payload, clientId: id.uuidString))
      let local = BookmarkResponse(
        id: localID, bookId: reader.bookID, cfi: cfi, title: payload.title,
        positionSeconds: nil, fileId: nil, pageNumber: nil,
        createdAt: ISO8601DateFormatter().string(from: Date()))
      try outbox.update { state in
        state.operations.append(
          OfflineBookmarkOperation(
            id: id,
            path: "books/\(reader.bookID)/bookmarks", method: "POST", body: body,
            localID: localID, audioID: nil))
        state.items.insert(local, at: 0)
        state.items = Array(state.items.prefix(40))
      }
      items.insert(navigation(local), at: 0)
      items = Array(items.prefix(40))
      do {
        try await outbox.flush(session: generation)
        status = "Passage bookmarked."
      } catch is URLError {
        status = "Bookmark saved on this iPad. It will sync when connected."
      }
    } catch {
      invalidateAccess(error)
      if !isClosed { self.error = error.localizedDescription }
    }
  }

  func remove(_ bookmark: EpubBookmarkNavigationItem) async {
    guard canSelect, let generation, let outbox, outbox.canWrite,
      items.contains(where: { $0.id == bookmark.id })
    else { return }
    isSaving = true
    error = nil
    defer { isSaving = false }
    do {
      try await ensureSession(generation)
      try await outbox.checkSession(generation)
      try outbox.update { state in
        if bookmark.id < 0 {
          if let index = state.operations.firstIndex(where: { $0.localID == bookmark.id }),
            state.operations[index].transmitted
          {
            state.operations[index].cancelAfterCreate = true
          } else {
            state.operations.removeAll { $0.localID == bookmark.id }
          }
        } else {
          state.operations.append(
            OfflineBookmarkOperation(
              id: UUID(),
              path: "books/\(reader.bookID)/bookmarks/\(bookmark.id)", method: "DELETE", body: nil,
              localID: bookmark.id, audioID: nil))
        }
        state.recoveryOperations.removeAll { $0.localID == bookmark.id }
        state.items.removeAll { $0.id == bookmark.id }
        state.navigationItems.removeAll { $0.id == bookmark.id }
      }
      items.removeAll { $0.id == bookmark.id }
      do {
        try await outbox.flush(session: generation)
        status = "Bookmark removed."
      } catch is URLError {
        status = "Removal saved on this iPad. It will sync when connected."
      }
    } catch {
      invalidateAccess(error)
      if !isClosed { self.error = error.localizedDescription }
    }
  }

  private func navigation(_ value: BookmarkResponse) -> EpubBookmarkNavigationItem {
    EpubBookmarkNavigationItem(
      chapterTitle: nil, contextPercentage: nil, locationLabel: "Saved passage",
      id: value.id, bookId: value.bookId, cfi: value.cfi, title: value.title,
      positionSeconds: nil, fileId: nil, pageNumber: nil, createdAt: value.createdAt)
  }

  private func loadOffline(_ requested: String?) async throws -> Bool {
    guard let outbox, let generation else { throw ConnectionError.invalidResponse }
    try await outbox.checkSession(generation)
    let store = try await reader.api.offlineStore()
    var before: Int?
    if let requested, requested.hasPrefix("offline:"), let value = Int(requested.dropFirst(8)) {
      before = value
    }
    var found: [BookmarkResponse] = []
    var scanned = 0
    var next: Int?
    repeat {
      var query = [URLQueryItem(name: "limit", value: "40")]
      if let before { query.append(URLQueryItem(name: "beforeId", value: String(before))) }
      guard
        let bytes = try await store.read(
          path: "books/\(reader.bookID)/bookmarks/epub-page", query: query, limit: 1024 * 1024)
      else { break }
      let page = try JSONDecoder().decode(BookmarksPage.self, from: bytes)
      guard page.items.count <= 40, page.nextCursor != before || before == nil else {
        throw ConnectionError.invalidResponse
      }
      scanned += page.items.count
      found.append(
        contentsOf: page.items.filter {
          normalizedQuery.isEmpty || $0.title.lowercased().contains(normalizedQuery)
        })
      next = page.nextCursor
      before = next
    } while found.count < 40 && next != nil && scanned < 400
    let deleted = Set(
      outbox.state.deletedIDs
        + outbox.state.operations.filter { $0.method == "DELETE" }.compactMap(\.localID))
    let pending = outbox.state.items.filter {
      $0.id < 0 && (normalizedQuery.isEmpty || $0.title.lowercased().contains(normalizedQuery))
    }
    let values = pending + found.filter { !deleted.contains($0.id) }
    if values.isEmpty && scanned == 0 {
      items = outbox.state.navigationItems
    } else {
      items = values.map(navigation)
    }
    nextCursor = next.map { "offline:\($0)" }
    cursor = requested
    currentBookmarkID = items.first { $0.cfi == currentCFI }?.id
    scanLimited = scanned >= 400 && found.count < 40 && next != nil
    hasLoaded = true
    status = "Offline bookmarks are shown newest first. Pending changes remain on this iPad."
    try outbox.update { $0.navigationItems = Array(items.prefix(40)) }
    return true
  }

  func open(
    _ bookmark: EpubBookmarkNavigationItem,
    jump: @MainActor (String) async -> EPUBPositionJumpResult
  ) async -> Bool {
    guard canSelect, items.contains(where: { $0.id == bookmark.id }), let target = bookmark.cfi,
      let generation
    else { return false }
    selectedForOpening = bookmark
    isOpening = true
    openingError = nil
    defer { isOpening = false }
    do {
      try await ensureSession(generation)
      switch await jump(target) {
      case .saved:
        try await ensureSession(generation)
        return true
      case .pendingSave:
        needsPositionSave = true
        openingError =
          reader.error ?? "The passage is open. Retry Save to confirm the reading position."
      case .failed:
        openingError =
          reader.error ?? "The bookmark could not be opened. Retry when the reader is ready."
      }
    } catch {
      invalidateAccess(error)
      if !isClosed { openingError = error.localizedDescription }
    }
    return false
  }

  func retryOpening(jump: @MainActor (String) async -> EPUBPositionJumpResult) async -> Bool {
    guard canRetryOpening, let generation else { return false }
    if !needsPositionSave, let selectedForOpening {
      return await open(selectedForOpening, jump: jump)
    }
    isOpening = true
    openingError = nil
    defer { isOpening = false }
    do {
      try await ensureSession(generation)
      guard await reader.saveProgress() else {
        openingError = reader.error ?? "The reading position is not confirmed. Retry Save."
        return false
      }
      try await ensureSession(generation)
      needsPositionSave = false
      return true
    } catch {
      invalidateAccess(error)
      if !isClosed { openingError = error.localizedDescription }
    }
    return false
  }

  func close() {
    isClosed = true
    cancelRequest()
    items = []
  }

  private func resetPages() {
    items = []
    nextCursor = nil
    currentBookmarkID = nil
    hasLoaded = false
    scanLimited = false
    cursor = nil
    retryCursor = nil
    previousCursors = []
    pageNumber = 1
    queryError = nil
    openingError = nil
    selectedForOpening = nil
  }

  private func cancelRequest() {
    requestTask?.cancel()
    requestTask = nil
    requestID = nil
    isLoading = false
  }

  private func ensureSession(_ expected: UUID) async throws {
    guard isCurrentPublication, try await reader.bookmarkSessionGeneration() == expected else {
      throw ConnectionError.expiredSession
    }
  }

  private func invalidateAccess(_ error: any Error) {
    if case ConnectionError.denied = error {
      canUseBookmarks = false
      resetPages()
    }
    if case ConnectionError.expiredSession = error {
      sessionValid = false
      resetPages()
    }
    if case ConnectionError.fileChanged = error {
      sessionValid = false
      resetPages()
    }
  }

  private func startLoad(_ requested: String?, debounced: Bool = false) -> Task<Bool, Never> {
    cancelRequest()
    let id = UUID()
    requestID = id
    let query = normalizedQuery
    let queryInput = self.query.trimmingCharacters(in: .whitespacesAndNewlines)
    let sort = order.rawValue
    retryCursor = requested
    queryError = nil
    isLoading = true
    let task = Task { @MainActor [weak self] in
      guard let self else { return false }
      defer {
        if self.requestID == id {
          self.isLoading = false
          self.requestTask = nil
        }
      }
      do {
        if debounced { try await Task.sleep(for: .milliseconds(300)) }
        try Task.checkCancellation()
        let session = try await self.reader.bookmarkSessionGeneration()
        guard self.isCurrentPublication, self.generation == nil || self.generation == session else {
          throw ConnectionError.expiredSession
        }
        self.generation = session
        if self.outbox == nil {
          self.outbox = try await OfflineBookmarkOutbox.open(
            api: self.reader.api,
            bookID: self.reader.bookID, fileID: self.reader.file.id, channel: "epub",
            sourceIdentity: self.reader.file.absolutePath + ":"
              + String(self.reader.file.sizeBytes ?? -1))
        }
        if let outbox = self.outbox {
          do { try await outbox.flush(session: session) } catch is URLError {}
        }
        if self.canUseBookmarks == nil {
          let user: AuthUser = try await self.reader.api.boundedJSON("auth/me", session: session)
          try Task.checkCancellation()
          try await self.ensureSession(session)
          guard self.requestID == id else { return false }
          self.canUseBookmarks =
            user.isSuperuser || user.permissions.contains(Permission.libraryDownload.rawValue)
          guard self.canUseBookmarks == true else { throw ConnectionError.denied }
        }
        var parameters = [
          URLQueryItem(name: "limit", value: "40"),
          URLQueryItem(name: "fileId", value: String(self.reader.file.id)),
          URLQueryItem(name: "query", value: queryInput), URLQueryItem(name: "sort", value: sort),
        ]
        if let requested { parameters.append(.init(name: "cursor", value: requested)) }
        if let currentCFI = self.currentCFI {
          parameters.append(.init(name: "currentCfi", value: currentCFI))
        }
        let page: EpubBookmarkNavigationPage = try await self.reader.api.boundedJSON(
          "books/\(self.reader.bookID)/bookmarks/epub-navigation", query: parameters,
          byteLimit: 1024 * 1024, session: session)
        try Task.checkCancellation()
        try await self.ensureSession(session)
        guard self.requestID == id else { return false }
        guard self.fileRevision == nil || self.fileRevision == page.fileRevision else {
          throw ConnectionError.fileChanged
        }
        guard page.bookId == self.reader.bookID, page.fileId == self.reader.file.id,
          page.fileRevision.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
          page.query == query, page.sort == sort, page.items.count <= 40,
          (0...400).contains(page.scannedCount), page.scannedCount >= page.items.count,
          !page.scanLimited
            || (page.scannedCount == 400 && page.items.count < 40 && page.nextCursor != nil),
          Set(page.items.map(\.id)).count == page.items.count,
          page.items.allSatisfy({
            $0.bookId == self.reader.bookID && $0.id > 0 && $0.title.unicodeScalars.count <= 500
              && $0.cfi?.hasPrefix("epubcfi(") == true && ($0.cfi?.utf16.count ?? 2001) <= 2000
              && $0.fileId == nil && $0.pageNumber == nil && $0.positionSeconds == nil
              && ($0.chapterTitle?.utf16.count ?? 0) <= 2000 && $0.locationLabel.utf16.count <= 2000
              && ($0.contextPercentage.map { (0...100).contains($0) } ?? true)
          }), page.currentBookmarkId.map({ $0 > 0 }) ?? true,
          page.nextCursor.map({ !$0.isEmpty && $0.utf8.count <= 2048 && $0 != requested }) ?? true
        else { throw ConnectionError.invalidResponse }
        let pending = self.outbox?.state.items.filter { $0.id < 0 }.map(self.navigation) ?? []
        let deleted = Set(
          (self.outbox?.state.deletedIDs ?? [])
            + (self.outbox?.state.operations.filter { $0.method == "DELETE" }.compactMap(\.localID)
              ?? []))
        self.items = pending + page.items.filter { !deleted.contains($0.id) }
        try self.outbox?.update { $0.navigationItems = Array(self.items.prefix(40)) }
        self.fileRevision = page.fileRevision
        self.nextCursor = page.nextCursor
        self.currentBookmarkID = page.currentBookmarkId
        self.cursor = requested
        self.hasLoaded = true
        self.scanLimited = page.scanLimited
        return true
      } catch {
        guard self.requestID == id, !self.isClosed, !Task.isCancelled else { return false }
        if error is URLError {
          do {
            if self.canUseBookmarks == nil, let user = try await self.reader.api.resumeOfflineUser()
            {
              self.canUseBookmarks =
                user.isSuperuser || user.permissions.contains(Permission.libraryDownload.rawValue)
            }
            guard self.canUseBookmarks == true else { throw ConnectionError.denied }
            return try await self.loadOffline(requested)
          } catch {
            self.queryError = error.localizedDescription
            return false
          }
        }
        if let outbox = self.outbox, !outbox.state.recoveryOperations.isEmpty {
          self.items = outbox.state.items.map(self.navigation)
          self.hasLoaded = true
          self.queryError =
            "Pending bookmarks remain on this iPad for review. \(error.localizedDescription)"
          return true
        }
        self.invalidateAccess(error)
        if case ConnectionError.http(400) = error {
          self.resetPages()
        }
        if case ConnectionError.http(409) = error {
          self.invalidateAccess(ConnectionError.fileChanged)
          self.queryError = ConnectionError.fileChanged.localizedDescription
        } else {
          self.queryError = error.localizedDescription
        }
        return false
      }
    }
    requestTask = task
    return task
  }
}
