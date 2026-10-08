import Foundation
import Observation

@MainActor @Observable
final class NativeAnnotationRepository {
  private static var accounts: [String: NativeAnnotationRepository] = [:]
  let api: BookOrbitAPI
  private let namespace: String
  private let session: UUID
  private let store: NativeAnnotationStore
  private var active = true
  @ObservationIgnored private var syncTasks: [Int: Task<Void, Error>] = [:]
  @ObservationIgnored private var autosave: [Int: Task<Void, Never>] = [:]
  private(set) var pendingCount = 0
  private(set) var isSynchronizing = false
  private(set) var generation = 0
  private(set) var lastOperationID: UUID?
  var error: String?

  private init(api: BookOrbitAPI, namespace: String, session: UUID) throws {
    self.api = api
    self.namespace = namespace
    self.session = session
    store = try NativeAnnotationStore(namespace: namespace)
  }

  static func shared(api: BookOrbitAPI) async throws -> NativeAnnotationRepository {
    let namespace = try await api.storageNamespace()
    let session = try await api.authenticatedSessionGeneration()
    if let existing = accounts[namespace], existing.api === api, existing.session == session,
      existing.active
    {
      return existing
    }
    accounts[namespace]?.stop()
    let repository = try NativeAnnotationRepository(
      api: api, namespace: namespace, session: session)
    accounts[namespace] = repository
    repository.pendingCount = try await repository.store.pendingCount()
    return repository
  }

  static func disconnect(api: BookOrbitAPI) async {
    for (key, value) in accounts where value.api === api {
      value.stop()
      accounts.removeValue(forKey: key)
    }
  }

  func load(bookID: Int) async throws -> [NativeAnnotationItem] {
    try await checkAccount()
    let result = try await store.load(bookID: bookID)
    try await checkAccount()
    return result
  }

  func loadSourceInk(bookID: Int, fileID: Int, page: Int? = nil) async throws
    -> [NativeAnnotationItem]
  {
    try await checkAccount()
    return try await store.loadSourceInk(bookID: bookID, fileID: fileID, page: page)
  }

  func synchronizeSourceInk(bookID: Int, fileID: Int, page: Int? = nil) async throws {
    try await checkAccount()
    try await pull(bookID: bookID, fileID: fileID)
    try await synchronize(bookID: bookID)
    try await pull(bookID: bookID, fileID: fileID)
  }

  func create(bookID: Int, payload: NativeAnnotationPayload) async throws -> NativeAnnotationItem {
    try await checkAccount()
    guard bookID > 0, payload.cfi != nil || payload.pdf != nil else {
      throw ConnectionError.invalidResponse
    }
    let operationID = UUID()
    let clientID = UUID().uuidString.lowercased()
    let now = Date().ISO8601Format()
    let item = NativeAnnotationItem(
      clientId: clientID, kind: payload.kind ?? "highlight", drawing: payload.drawing,
      version: 1, deletedAt: nil, sourceRevision: payload.sourceRevision,
      pageFingerprint: payload.pageFingerprint, id: -Int.random(in: 1...Int.max), bookId: bookID,
      cfi: payload.cfi, jumpFileId: payload.bookFileId, pageno: payload.pdf?.page,
      text: payload.text ?? "", color: payload.color ?? "yellow",
      style: payload.style ?? "highlight",
      note: payload.note, chapterTitle: payload.chapterTitle, origin: "native",
      positionStatus: "exact",
      chapterIndex: nil, highlightedAt: now, createdAt: now, updatedAt: now,
      pdf: payload.pdf, starredAt: nil)
    let operation = NativeAnnotationOperation(
      operationId: operationID.uuidString.lowercased(),
      clientId: clientID, annotationId: nil, bookId: bookID, baseVersion: 0,
      action: "create", payload: payload)
    try await store.enqueue(
      NativeAnnotationQueuedChange(
        operation: operation, before: nil,
        after: item, attempted: false, status: "pending", acknowledged: nil))
    try await changed(operationID: operationID, bookID: bookID)
    return item
  }

  @discardableResult
  func mutate(
    _ item: NativeAnnotationItem, action: String,
    payload: NativeAnnotationPayload? = nil
  ) async throws -> UUID {
    try await checkAccount()
    guard ["update", "delete", "restore", "repair"].contains(action) else {
      throw ConnectionError.invalidResponse
    }
    guard let current = try await store.current(item) else {
      throw NativeAnnotationStorageError.recoveryRequired
    }
    guard current.version == item.version, current.deletedAt == item.deletedAt else {
      throw NativeAnnotationStorageError.newerChanges
    }
    guard current.deletedAt == nil || action == "restore" else {
      throw NativeAnnotationStorageError.recoveryRequired
    }
    guard current.positionStatus != "failed" || action == "repair" || action == "delete" else {
      throw NativeAnnotationStorageError.recoveryRequired
    }
    let operationID = UUID()
    var next = current
    if action == "delete" { next.deletedAt = Date().ISO8601Format() }
    if action == "restore" { next.deletedAt = nil }
    if let payload { apply(payload, to: &next) }
    next.version += 1
    next.updatedAt = Date().ISO8601Format()
    let operation = NativeAnnotationOperation(
      operationId: operationID.uuidString.lowercased(),
      clientId: current.clientId ?? UUID().uuidString.lowercased(),
      annotationId: current.id > 0 ? current.id : nil,
      bookId: current.bookId, baseVersion: current.version, action: action, payload: payload)
    if next.clientId == nil { next.clientId = operation.clientId }
    try await store.enqueue(
      NativeAnnotationQueuedChange(
        operation: operation, before: current,
        after: next, attempted: false, status: "pending", acknowledged: nil))
    try await changed(operationID: operationID, bookID: item.bookId)
    return operationID
  }

  @discardableResult
  func undo(operationID: UUID) async throws -> NativeAnnotationUndoOutcome {
    try await checkAccount()
    guard var change = try await store.change(operationID: operationID) else {
      throw NativeAnnotationStorageError.recoveryRequired
    }
    autosave[change.operation.bookId]?.cancel()
    autosave.removeValue(forKey: change.operation.bookId)
    if change.status == "pending", !change.attempted {
      do {
        try await store.cancel(change)
        pendingCount = try await store.pendingCount()
        generation += 1
        return .cancelled
      } catch NativeAnnotationStorageError.recoveryRequired {
        guard let current = try await store.change(operationID: operationID) else {
          throw NativeAnnotationStorageError.recoveryRequired
        }
        change = current
      }
    }
    try await store.requestUndo(change)
    syncTasks[change.operation.bookId]?.cancel()
    try await changed(operationID: operationID, bookID: change.operation.bookId)
    return .queued
  }

  private func resolveUndo(_ change: NativeAnnotationQueuedChange) async throws {
    guard let inverseID = change.undoOperationId, let acknowledged = change.acknowledged else {
      throw NativeAnnotationStorageError.recoveryRequired
    }
    try await pull(
      bookID: change.operation.bookId,
      fileID: acknowledged.kind == "pdf_ink" ? acknowledged.jumpFileId : nil)
    guard let current = try await store.canonical(acknowledged) else {
      throw NativeAnnotationStorageError.recoveryRequired
    }
    let action: String
    if change.before == nil || change.operation.action == "restore" {
      action = "delete"
    } else if change.operation.action == "delete" {
      action = "restore"
    } else {
      action = "update"
    }
    let payload = action == "delete" ? nil : change.before.map { payload(from: $0) }
    var after = current
    if action == "delete" { after.deletedAt = Date().ISO8601Format() }
    if action == "restore" { after.deletedAt = nil }
    if let payload { apply(payload, to: &after) }
    after.version += 1
    after.updatedAt = Date().ISO8601Format()
    let operation = NativeAnnotationOperation(
      operationId: inverseID, clientId: change.operation.clientId,
      annotationId: current.id, bookId: current.bookId,
      baseVersion: acknowledged.version, action: action, payload: payload)
    try await store.completeUndo(
      change,
      inverse: NativeAnnotationQueuedChange(
        operation: operation, before: current, after: after,
        attempted: false, status: "pending", acknowledged: nil))
    generation += 1
  }

  func synchronize(bookID: Int) async throws {
    try await checkAccount()
    if let task = syncTasks[bookID] { return try await task.value }
    let task = Task { try await self.performSync(bookID: bookID) }
    syncTasks[bookID] = task
    isSynchronizing = true
    defer {
      syncTasks.removeValue(forKey: bookID)
      isSynchronizing = !syncTasks.isEmpty
    }
    do {
      try await task.value
      error = nil
    } catch {
      if !task.isCancelled {
        self.error = error.localizedDescription
        generation += 1
      }
      throw error
    }
  }

  func synchronizePending() async {
    do {
      let books = try await store.pendingBooks()
      for bookID in books {
        try Task.checkCancellation()
        try await synchronize(bookID: bookID)
      }
    } catch { self.error = error.localizedDescription }
  }

  func recoveryDrafts(bookID: Int? = nil) async throws -> [NativeAnnotationRecoveryDraft] {
    try await checkAccount()
    return try await store.recoveryDrafts(bookID: bookID)
  }

  func recoveryDraftsPage(bookID: Int? = nil, cursor: Int? = nil, limit: Int = 40) async throws
    -> NativeAnnotationRecoveryPage
  {
    try await checkAccount()
    return try await store.recoveryDraftsPage(bookID: bookID, cursor: cursor, limit: limit)
  }

  func queryHub(query: [URLQueryItem]) async throws -> NativeAnnotationHubResponse {
    try await checkAccount()
    let cursor = query.first(where: { $0.name == "cursor" })?.value.flatMap(Int.init) ?? 0
    if cursor < 0 { return try await store.hub(query: query) }
    do {
      let response: NativeAnnotationHubResponse = try await api.boundedJSON(
        "annotations/native/hub", query: query, byteLimit: 32 * 1024 * 1024, session: session)
      try await checkAccount()
      guard response.items.count <= 100 else { throw ConnectionError.invalidResponse }
      try await store.importHub(response.items)
      return try await store.hub(query: query, remote: response)
    } catch {
      try await checkAccount()
      switch error {
      case ConnectionError.expiredSession, ConnectionError.denied, ConnectionError.invalidResponse:
        throw error
      default:
        self.error = error.localizedDescription
        if cursor > 0 { throw NativeAnnotationStorageError.paginationChanged }
        return try await store.hub(query: query)
      }
    }
  }

  func retainSourceRecovery(bookID: Int, fileID: Int, reason: String) async throws {
    try await checkAccount()
    guard ["source_replaced", "source_deleted"].contains(reason) else {
      throw ConnectionError.invalidResponse
    }
    try await store.retainSourceRecovery(bookID: bookID, fileID: fileID, reason: reason)
    pendingCount = try await store.pendingCount()
    generation += 1
  }

  func protectedSourceRevision(bookID: Int, fileID: Int, revision: String) async throws -> Bool {
    try await checkAccount()
    return try await store.protectedSourceRevision(
      bookID: bookID, fileID: fileID, revision: revision)
  }

  func canRemoveSourceVersion(bookID: Int, fileID: Int, revision: String) async throws -> Bool {
    try await !protectedSourceRevision(bookID: bookID, fileID: fileID, revision: revision)
  }

  private func performSync(bookID: Int) async throws {
    try await pull(bookID: bookID)
    for fileID in try await store.pendingSourceFiles(bookID: bookID) {
      try await pull(bookID: bookID, fileID: fileID)
    }
    let deviceID = try await store.deviceID()
    for _ in 0..<1000 {
      try Task.checkCancellation()
      try await checkAccount()
      guard let change = try await store.nextPending(bookID: bookID) else { break }
      guard try await store.markAttempted(change) else { continue }
      let request = NativeAnnotationOperationsRequest(
        deviceId: deviceID, operations: [change.operation])
      let route: String
      if change.after.kind == "pdf_ink", let fileID = change.after.jumpFileId {
        route = "annotations/native/source-ink/\(bookID)/\(fileID)/operations"
      } else {
        route = "annotations/native/operations"
      }
      let response: NativeAnnotationOperationsResponse = try await api.boundedJSON(
        route, method: "POST", body: JSONEncoder().encode(request),
        byteLimit: 8 * 1024 * 1024, session: session)
      try await checkAccount()
      guard response.results.count == 1, let result = response.results.first else {
        throw ConnectionError.invalidResponse
      }
      try await store.applyResult(result, change: change)
      pendingCount = try await store.pendingCount()
      generation += 1
      if let publication = result.publication, publication.status != "published" {
        throw NativeAnnotationStorageError.publicationPending
      }
      if let operationID = UUID(uuidString: change.operation.operationId),
        let latest = try await store.change(operationID: operationID), latest.undoOperationId != nil
      {
        if latest.status == "recovery" { throw NativeAnnotationStorageError.recoveryRequired }
        if latest.status == "pending", latest.acknowledged != nil {
          try await resolveUndo(latest)
        }
      }
    }
    try await pull(bookID: bookID)
    let cursor = try await store.cursor(bookID: bookID)
    let ack = NativeAnnotationAck(deviceId: deviceID, bookId: bookID, cursor: cursor)
    try await api.sendEmpty(
      "annotations/native/ack", body: JSONEncoder().encode(ack), session: session)
    try await checkAccount()
    pendingCount = try await store.pendingCount()
  }

  private func pull(bookID: Int, fileID: Int? = nil) async throws {
    var cursor = try await store.cursor(bookID: bookID, fileID: fileID)
    while true {
      try Task.checkCancellation()
      try await checkAccount()
      var query = [
        URLQueryItem(name: "bookId", value: String(bookID)),
        URLQueryItem(name: "cursor", value: cursor), URLQueryItem(name: "limit", value: "10"),
      ]
      if let fileID { query.append(URLQueryItem(name: "bookFileId", value: String(fileID))) }
      let delta: NativeAnnotationDelta = try await api.boundedJSON(
        fileID == nil ? "annotations/native/delta" : "annotations/native/source-ink", query: query,
        byteLimit: 24 * 1024 * 1024, session: session)
      try await checkAccount()
      guard delta.items.count <= 10, !delta.hasMore || delta.nextCursor != cursor else {
        throw ConnectionError.invalidResponse
      }
      guard
        fileID == nil || delta.items.allSatisfy({ $0.kind == "pdf_ink" && $0.jumpFileId == fileID })
      else {
        throw ConnectionError.invalidResponse
      }
      try await store.applyDelta(delta, bookID: bookID, fileID: fileID)
      if !delta.items.isEmpty { generation += 1 }
      cursor = delta.nextCursor
      if !delta.hasMore { return }
    }
  }

  private func changed(operationID: UUID, bookID: Int) async throws {
    try await checkAccount()
    let usesPrecommitFixture =
      ProcessInfo.processInfo.environment["BOOKORBIT_ANNOTATION_INPUT_FIXTURE"] == "1"
      && ProcessInfo.processInfo.arguments.contains("--annotation-input-driver")
      && ProcessInfo.processInfo.environment["BOOKORBIT_ANNOTATION_PRECOMMIT_FIXTURE"] == "1"
    let coalescingDelay: Duration = usesPrecommitFixture ? .seconds(10) : .milliseconds(650)
    lastOperationID = operationID
    pendingCount = try await store.pendingCount()
    generation += 1
    autosave[bookID]?.cancel()
    autosave[bookID] = Task {
      do {
        try await Task.sleep(for: coalescingDelay)
        try Task.checkCancellation()
        try await self.synchronize(bookID: bookID)
      } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
  }

  private func checkAccount() async throws {
    try Task.checkCancellation()
    guard active, try await api.storageNamespace() == namespace,
      try await api.authenticatedSessionGeneration() == session
    else { throw ConnectionError.expiredSession }
  }

  private func stop() {
    active = false
    for task in autosave.values { task.cancel() }
    for task in syncTasks.values { task.cancel() }
    autosave.removeAll()
    syncTasks.removeAll()
    pendingCount = 0
    isSynchronizing = false
    let store = store
    Task { await store.close() }
  }

  private func same(_ left: NativeAnnotationItem, _ right: NativeAnnotationItem) -> Bool {
    left.id == right.id || (left.clientId != nil && left.clientId == right.clientId)
  }

  private func apply(_ value: NativeAnnotationPayload, to item: inout NativeAnnotationItem) {
    if let value = value.kind { item.kind = value }
    if let value = value.drawing { item.drawing = value }
    if let value = value.cfi { item.cfi = value }
    if let value = value.pdf {
      item.pdf = value
      item.pageno = value.page
    }
    if let value = value.bookFileId { item.jumpFileId = value }
    if let value = value.text { item.text = value }
    if let value = value.color { item.color = value }
    if let value = value.style { item.style = value }
    if let value = value.note { item.note = value }
    if let value = value.chapterTitle { item.chapterTitle = value }
    if let value = value.sourceRevision { item.sourceRevision = value }
    if let value = value.pageFingerprint { item.pageFingerprint = value }
  }

  private func payload(from item: NativeAnnotationItem) -> NativeAnnotationPayload {
    NativeAnnotationPayload(
      kind: item.kind, drawing: item.drawing,
      sourceRevision: item.sourceRevision, pageFingerprint: item.pageFingerprint,
      cfi: item.cfi, pdf: item.pdf, bookFileId: item.jumpFileId, text: item.text,
      color: item.color, style: item.style, note: item.note, chapterTitle: item.chapterTitle)
  }
}
