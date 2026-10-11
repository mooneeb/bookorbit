import Foundation

struct NativeReadingAttemptDraft: Codable, Equatable {
  var id: UUID
  var bookID: Int
  var title: String
  var baseline: ReadingAttempt?
  var started: String
  var finished: String
  var outcome: String
  var timeZone: String
}

@MainActor
final class NativeReadingAttemptOutbox {
  private struct Operation: Codable, Identifiable {
    let id: UUID
    let draft: NativeReadingAttemptDraft
    let body: Data
    var conflict: String?
  }
  private struct State: Codable {
    var drafts: [String: NativeReadingAttemptDraft] = [:]
    var operations: [Operation] = []
  }
  private static var stores: [String: NativeReadingAttemptOutbox] = [:]
  private let namespace: String
  private let journal: NativeReadingRecordJournal
  private var state: State
  private var isFlushing = false

  private init(namespace: String) throws {
    self.namespace = namespace
    journal = try NativeReadingRecordJournal(namespace: namespace, key: "attempts")
    state = try journal.read(State.self) ?? State()
    guard state.drafts.count <= 128, state.operations.count <= 256 else {
      throw OfflineStorageError.storageLimit
    }
  }

  static func open(api: BookOrbitAPI) async throws -> NativeReadingAttemptOutbox {
    let namespace = try await api.storageNamespace()
    if let store = stores[namespace] { return store }
    let store = try NativeReadingAttemptOutbox(namespace: namespace)
    stores[namespace] = store
    return store
  }

  static func flush(api: BookOrbitAPI) async throws {
    try await open(api: api).flushPending(api: api)
  }

  func draft(bookID: Int) -> NativeReadingAttemptDraft? { state.drafts[String(bookID)] }
  func hasPending(bookID: Int) -> Bool {
    state.operations.contains { $0.draft.bookID == bookID }
  }
  func recoveryReason(bookID: Int) -> String? {
    state.operations.first { $0.draft.bookID == bookID && $0.conflict != nil }?.conflict
  }

  func preserve(_ draft: NativeReadingAttemptDraft) throws {
    guard !state.operations.contains(where: { $0.id == draft.id }) else { return }
    var next = state
    guard next.drafts[String(draft.bookID)] != nil || next.drafts.count < 128 else {
      throw OfflineStorageError.storageLimit
    }
    next.drafts[String(draft.bookID)] = draft
    try commit(next)
  }

  func enqueue(_ draft: NativeReadingAttemptDraft) throws {
    if state.operations.contains(where: { $0.id == draft.id }) { return }
    guard !hasPending(bookID: draft.bookID) else { throw ReadingRecordError.recoveryRequired }
    let body: Data
    if let baseline = draft.baseline {
      var payload = ReadingAttemptPatch(
        startedOn: draft.started.isEmpty ? .clear : .set(draft.started),
        endedOn: draft.finished.isEmpty ? .clear : .set(draft.finished),
        outcome: draft.outcome.isEmpty ? .clear : .set(draft.outcome))
      payload.baseUpdatedAt = baseline.updatedAt
      body = try JSONEncoder().encode(payload)
    } else {
      var payload = CreateReadingAttemptPayload(
        startedOn: draft.started.isEmpty ? nil : draft.started,
        endedOn: draft.finished.isEmpty ? nil : draft.finished, outcome: draft.outcome)
      payload.clientId = draft.id.uuidString
      body = try JSONEncoder().encode(payload)
    }
    var next = state
    guard next.operations.count < 256 else { throw OfflineStorageError.storageLimit }
    guard next.drafts[String(draft.bookID)] != nil || next.drafts.count < 128 else {
      throw OfflineStorageError.storageLimit
    }
    next.drafts[String(draft.bookID)] = draft
    next.operations.append(Operation(id: draft.id, draft: draft, body: body))
    try commit(next)
  }

  var recoveryItems: [NativeReadingRecoveryItem] {
    state.operations.compactMap { operation in
      guard let reason = operation.conflict else { return nil }
      return NativeReadingRecoveryItem(
        id: operation.id.uuidString, title: "Reading history for \(operation.draft.title)",
        reason: reason)
    }
  }

  func recoveryData() throws -> Data {
    let records: [[String: Any]] = try state.operations.compactMap { operation in
      guard let reason = operation.conflict else { return nil }
      return [
        "bookId": operation.draft.bookID,
        "attemptId": operation.draft.baseline?.id as Any? ?? NSNull(),
        "reason": reason,
        "localVersion": try JSONSerialization.jsonObject(
          with: JSONEncoder().encode(operation.draft)),
      ]
    }
    return try JSONSerialization.data(withJSONObject: records)
  }

  private func commit(_ next: State) throws {
    try journal.save(next)
    state = next
  }

  private func acknowledge(_ operation: Operation) throws {
    var next = state
    next.operations.removeAll { $0.id == operation.id }
    if next.drafts[String(operation.draft.bookID)]?.id == operation.id {
      next.drafts.removeValue(forKey: String(operation.draft.bookID))
    }
    try commit(next)
  }

  private func retain(_ operation: Operation, reason: String) throws {
    var next = state
    if let index = next.operations.firstIndex(where: { $0.id == operation.id }) {
      next.operations[index].conflict = reason
    }
    try commit(next)
  }

  private func matchesDesired(_ operation: Operation, current: ReadingAttempt) -> Bool {
    current.bookId == operation.draft.bookID
      && current.startedOn == (operation.draft.started.isEmpty ? nil : operation.draft.started)
      && current.endedOn == (operation.draft.finished.isEmpty ? nil : operation.draft.finished)
      && current.outcome == (operation.draft.outcome.isEmpty ? nil : operation.draft.outcome)
  }

  private func flushPending(api: BookOrbitAPI) async throws {
    guard !isFlushing else { return }
    isFlushing = true
    defer { isFlushing = false }
    let session = try await api.authenticatedSessionGeneration()
    for operation in state.operations.lazy.filter({ $0.conflict == nil }).prefix(64) {
      guard try await api.storageNamespace() == namespace else {
        throw ConnectionError.expiredSession
      }
      let path = "books/\(operation.draft.bookID)/reading-attempts"
      do {
        let _: ReadingAttempt = try await api.boundedJSONOnline(
          operation.draft.baseline.map { "\(path)/\($0.id)" } ?? path,
          method: operation.draft.baseline == nil ? "POST" : "PATCH",
          body: operation.body, byteLimit: 64 * 1024, session: session,
          expectedStatus: operation.draft.baseline == nil ? 201 : 200, timeoutInterval: 20)
        guard try await api.storageNamespace() == namespace else {
          throw ConnectionError.expiredSession
        }
        try acknowledge(operation)
      } catch {
        switch error {
        case ConnectionError.http(409):
          if let baseline = operation.draft.baseline {
            do {
              let current: ReadingAttempt = try await api.boundedJSONOnline(
                "\(path)/\(baseline.id)", byteLimit: 64 * 1024, session: session,
                expectedStatus: 200, timeoutInterval: 10)
              guard try await api.storageNamespace() == namespace else {
                throw ConnectionError.expiredSession
              }
              if matchesDesired(operation, current: current) {
                try acknowledge(operation)
                continue
              }
            } catch ConnectionError.http(404) {
            } catch ConnectionError.denied {
            }
          }
          try retain(
            operation,
            reason:
              "This reading attempt changed or was deleted. Your local history is kept for recovery and will not overwrite or recreate it."
          )
        case ConnectionError.http(400), ConnectionError.http(404), ConnectionError.denied:
          try retain(
            operation,
            reason:
              "This book or reading attempt is unavailable. Your local history is kept for recovery and will not recreate deleted history."
          )
        default: throw error
        }
      }
    }
  }
}
