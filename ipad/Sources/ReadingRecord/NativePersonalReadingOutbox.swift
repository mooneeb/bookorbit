import Foundation

struct NativePersonalReadingDraft: Codable {
  var book: BookDetail
  var status: String
  var started: String
  var finished: String
  var note: String
  var rating: Double?
  var timeZone: String
}

@MainActor
final class NativePersonalReadingOutbox {
  private struct Operation: Codable, Identifiable {
    var id: UUID
    var bookID: Int
    var kind: String
    var body: Data
    var baselineStatus: UserBookStatus?
    var baselineNote: String?
    var baselineRating: Double?
    var conflict: String?
  }
  private struct State: Codable {
    var drafts: [String: NativePersonalReadingDraft] = [:]
    var operations: [Operation] = []
  }
  private static var stores: [String: NativePersonalReadingOutbox] = [:]
  private let namespace: String
  private let journal: NativeReadingRecordJournal
  private var state: State
  private var isFlushing = false

  private init(namespace: String) throws {
    self.namespace = namespace
    journal = try NativeReadingRecordJournal(namespace: namespace, key: "personal")
    state = try journal.read(State.self) ?? State()
    guard state.operations.count <= 256, state.drafts.count <= 128 else {
      throw OfflineStorageError.storageLimit
    }
  }

  static func open(api: BookOrbitAPI) async throws -> NativePersonalReadingOutbox {
    let namespace = try await api.storageNamespace()
    if let current = stores[namespace] { return current }
    let current = try NativePersonalReadingOutbox(namespace: namespace)
    stores[namespace] = current
    return current
  }

  static func flush(api: BookOrbitAPI) async throws {
    let store = try await open(api: api)
    try await store.flushPending(api: api)
  }

  func draft(bookID: Int) -> NativePersonalReadingDraft? { state.drafts[String(bookID)] }
  var recoveryItems: [NativeReadingRecoveryItem] {
    state.operations.compactMap { operation in
      guard let conflict = operation.conflict else { return nil }
      return NativeReadingRecoveryItem(
        id: operation.id.uuidString,
        title: state.drafts[String(operation.bookID)]?.book.title
          ?? "Reading record for book \(operation.bookID)", reason: conflict)
    }
  }

  func recoveryData() throws -> Data {
    let records: [[String: Any]] = try state.operations.compactMap { operation in
      guard let conflict = operation.conflict else { return nil }
      var record: [String: Any] = [
        "bookId": operation.bookID, "field": operation.kind,
        "reason": conflict, "record": try JSONSerialization.jsonObject(with: operation.body),
      ]
      if let draft = state.drafts[String(operation.bookID)] {
        record["localVersion"] = [
          "title": draft.book.title, "status": draft.status,
          "started": draft.started, "finished": draft.finished, "note": draft.note,
          "rating": draft.rating.map { $0 as Any } ?? NSNull(), "timeZone": draft.timeZone,
        ]
      }
      return record
    }
    return try JSONSerialization.data(withJSONObject: records)
  }
  func hasPending(bookID: Int) -> Bool { state.operations.contains { $0.bookID == bookID } }
  func recoveryReason(bookID: Int) -> String? {
    state.operations.first { $0.bookID == bookID && $0.conflict != nil }?.conflict
  }

  func preserve(book: BookDetail, draft: BookReadingDraft) throws {
    var next = state
    if draft.hasChanges || hasPending(bookID: book.id) {
      guard next.drafts.count < 128 || next.drafts[String(book.id)] != nil else {
        throw OfflineStorageError.storageLimit
      }
      next.drafts[String(book.id)] = NativePersonalReadingDraft(
        book: book, status: draft.status, started: draft.started, finished: draft.finished,
        note: draft.note, rating: draft.rating, timeZone: draft.timeZone.identifier)
    } else {
      next.drafts.removeValue(forKey: String(book.id))
    }
    try commit(next)
  }

  func enqueue(book: BookDetail, draft: BookReadingDraft) throws {
    var next = state
    guard !next.operations.contains(where: { $0.bookID == book.id && $0.conflict != nil }) else {
      throw ReadingRecordError.recoveryRequired
    }
    var statusPayload = draft.statusPayload
    statusPayload?.baseStatusUpdatedAt = (book.readStatus?.updatedAt).map { .set($0) } ?? .clear
    var notePayload = draft.notePayload
    notePayload.baseNote = book.personalNote.map { .set($0) } ?? .clear
    var ratingPayload = draft.ratingPayload
    ratingPayload.baseRating = book.rating.map { .set($0) } ?? .clear
    let entries: [(String, Data?)] = [
      ("status", try statusPayload.map { try JSONEncoder().encode($0) }),
      ("note", draft.noteChanged ? try JSONEncoder().encode(notePayload) : nil),
      ("rating", draft.ratingChanged ? try JSONEncoder().encode(ratingPayload) : nil),
    ]
    for (kind, body) in entries {
      guard let body else { continue }
      next.operations.removeAll { $0.bookID == book.id && $0.kind == kind }
      next.operations.append(
        Operation(
          id: UUID(), bookID: book.id, kind: kind, body: body,
          baselineStatus: book.readStatus, baselineNote: book.personalNote,
          baselineRating: book.rating))
    }
    guard next.operations.count <= 256 else { throw OfflineStorageError.storageLimit }
    try commit(next)
    try preserve(book: book, draft: draft)
  }

  func enqueueManual(bookID: Int, payload: CreateManualReadingSessionPayload) throws {
    var next = state
    guard next.operations.count < 256 else { throw OfflineStorageError.storageLimit }
    next.operations.append(
      Operation(
        id: UUID(), bookID: bookID, kind: "manual", body: try JSONEncoder().encode(payload)))
    try commit(next)
  }

  func keepDraftOnly(bookID: Int) throws {
    var next = state
    next.operations.removeAll { $0.bookID == bookID && $0.kind != "manual" }
    try commit(next)
  }

  private func commit(_ next: State) throws {
    try journal.save(next)
    state = next
  }

  private func flushPending(api: BookOrbitAPI) async throws {
    guard !isFlushing else { return }
    isFlushing = true
    defer { isFlushing = false }
    let session = try await api.authenticatedSessionGeneration()
    for pending in state.operations.prefix(64) where pending.conflict == nil {
      guard try await api.storageNamespace() == namespace else {
        throw ConnectionError.expiredSession
      }
      do {
        if pending.kind == "manual" {
          let _: BookReadingSession = try await api.boundedJSON(
            "books/\(pending.bookID)/sessions", method: "POST", body: pending.body, session: session
          )
        } else {
          let remote: BookDetail = try await api.boundedJSON(
            "books/\(pending.bookID)", byteLimit: 2 * 1024 * 1024, session: session)
          if !matchesDesired(pending, book: remote) {
            guard matchesBaseline(pending, book: remote) else {
              var next = state
              if let index = next.operations.firstIndex(where: { $0.id == pending.id }) {
                next.operations[index].conflict =
                  "Your reading details changed on another device. Your local version is kept for recovery. Review the current server record before saving again."
              }
              try commit(next)
              continue
            }
            switch pending.kind {
            case "status":
              let _: UserBookStatus = try await api.boundedJSON(
                "books/\(pending.bookID)/status", method: "PATCH", body: pending.body,
                session: session)
            case "note":
              let _: BookDetail = try await api.boundedJSON(
                "books/\(pending.bookID)/personal-note", method: "PATCH", body: pending.body,
                session: session)
            case "rating":
              let _: BookDetail = try await api.boundedJSON(
                "books/\(pending.bookID)/rating", method: "PATCH", body: pending.body,
                session: session)
            default: throw ConnectionError.invalidResponse
            }
          }
        }
        guard try await api.storageNamespace() == namespace else {
          throw ConnectionError.expiredSession
        }
        var next = state
        next.operations.removeAll { $0.id == pending.id }
        if !next.operations.contains(where: { $0.bookID == pending.bookID }) {
          next.drafts.removeValue(forKey: String(pending.bookID))
        }
        try commit(next)
      } catch {
        if case ConnectionError.http(409) = error {
          var next = state
          if let index = next.operations.firstIndex(where: { $0.id == pending.id }) {
            next.operations[index].conflict =
              "Another device changed this reading field while it was saving. Your local version is retained for recovery."
          }
          try commit(next)
          continue
        }
        let unavailable: Bool
        switch error {
        case ConnectionError.http(404), ConnectionError.denied: unavailable = true
        case ConnectionError.http(400): unavailable = pending.kind == "manual"
        default: unavailable = false
        }
        if unavailable {
          var next = state
          if let index = next.operations.firstIndex(where: { $0.id == pending.id }) {
            next.operations[index].conflict =
              pending.kind == "manual"
              ? "This manual session is unavailable or was deleted. Its local version is retained and will not recreate it."
              : "This book is unavailable. Your local reading record is retained for recovery."
          }
          try commit(next)
          continue
        }
        throw error
      }
    }
  }

  private func matchesBaseline(_ operation: Operation, book: BookDetail) -> Bool {
    switch operation.kind {
    case "status":
      return book.readStatus?.status == operation.baselineStatus?.status
        && book.readStatus?.startedAt == operation.baselineStatus?.startedAt
        && book.readStatus?.finishedAt == operation.baselineStatus?.finishedAt
    case "note": return normalized(book.personalNote) == normalized(operation.baselineNote)
    case "rating": return book.rating == operation.baselineRating
    default: return false
    }
  }

  private func matchesDesired(_ operation: Operation, book: BookDetail) -> Bool {
    guard let body = try? JSONSerialization.jsonObject(with: operation.body) as? [String: Any]
    else { return false }
    switch operation.kind {
    case "status":
      if let status = body["status"] as? String, status != book.readStatus?.status { return false }
      for (key, current) in [
        ("startedAt", book.readStatus?.startedAt), ("finishedAt", book.readStatus?.finishedAt),
      ] {
        if let date = body[key] as? String, date != current.map({ String($0.prefix(10)) }) {
          return false
        }
        if body[key] is NSNull, current != nil { return false }
      }
      return true
    case "note": return normalized(body["note"] as? String) == normalized(book.personalNote)
    case "rating":
      if body["rating"] is NSNull { return book.rating == nil }
      return (body["rating"] as? NSNumber)?.doubleValue == book.rating
    default: return false
    }
  }

  private func normalized(_ value: String?) -> String {
    (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

enum ReadingRecordError: LocalizedError {
  case recoveryRequired
  var errorDescription: String? {
    "A local recovery version needs review. Keep it as a draft, load the current server record, then explicitly save the version you want."
  }
}
