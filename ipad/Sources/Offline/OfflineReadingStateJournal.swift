import Foundation

@MainActor
final class OfflineReadingStateJournal {
  nonisolated private static let entryLimit = 4096
  nonisolated private static let protectionLock = NSRecursiveLock()
  private static let byteLimit = 32 * 1024 * 1024
  private let root: URL
  private let file: URL
  private struct ProtectedProgress: Decodable {
    let fileID: Int
    let sourceRevision: String?
    let pending: OfflineProgressDraft?
    let local: OfflineProgressDraft?
  }

  init(namespace: String, key: String) throws {
    root = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ).appendingPathComponent("BookOrbitReadingState", isDirectory: true)
      .appendingPathComponent(OfflineResourceStore.hash(Data(namespace.utf8)), isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    file = root.appendingPathComponent(OfflineResourceStore.hash(Data(key.utf8)) + ".json")
  }

  func read<T: Decodable>(_ type: T.Type) throws -> T? {
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size <= 256 * 1024
    else { throw ConnectionError.responseTooLarge }
    return try JSONDecoder().decode(type, from: Data(contentsOf: file))
  }

  func readMigratingPending<T: Decodable>(
    _ type: T.Type, fileID: Int, bookmarks: Bool = false
  ) throws -> T? {
    Self.protectionLock.lock()
    defer { Self.protectionLock.unlock() }
    if let current = try read(type) { return current }
    let files = try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.fileSizeKey])
    guard files.count <= Self.entryLimit else { throw OfflineStorageError.storageLimit }
    var candidate: URL?
    var scannedBytes = 0
    for previous in files where previous != file {
      guard let size = try previous.resourceValues(forKeys: [.fileSizeKey]).fileSize,
        size <= 256 * 1024
      else { throw ConnectionError.responseTooLarge }
      scannedBytes += size
      guard scannedBytes <= Self.byteLimit else { throw OfflineStorageError.storageLimit }
      let data = try Data(contentsOf: previous)
      guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ConnectionError.invalidResponse
      }
      let matches =
        bookmarks
        ? ((value["sourceRevisions"] as? [String: String])?[String(fileID)] != nil
          && !(value["operations"] as? [Any] ?? []).isEmpty)
        : (value["fileID"] as? Int == fileID
          && (value["pending"] != nil || value["local"] != nil))
      guard matches, (try? JSONDecoder().decode(type, from: data)) != nil else { continue }
      guard candidate == nil else { throw ConnectionError.fileChanged }
      candidate = previous
    }
    guard let candidate else { return nil }
    try FileManager.default.moveItem(at: candidate, to: file)
    return try read(type)
  }

  func save<T: Encodable>(_ value: T) throws {
    Self.protectionLock.lock()
    defer { Self.protectionLock.unlock() }
    let data = try JSONEncoder().encode(value)
    guard data.count <= 256 * 1024 else { throw ConnectionError.responseTooLarge }
    let files = try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.fileSizeKey])
    guard files.count < Self.entryLimit || FileManager.default.fileExists(atPath: file.path) else {
      throw OfflineStorageError.storageLimit
    }
    let used = try files.reduce(0) { total, entry in
      total + (entry == file ? 0 : try entry.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }
    guard used <= Self.byteLimit - data.count else { throw OfflineStorageError.storageLimit }
    try data.write(
      to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }

  nonisolated static func hasProtectedWork(namespace: String, fileID: Int, revision: String) throws
    -> Bool
  {
    protectionLock.lock()
    defer { protectionLock.unlock() }
    let root = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ).appendingPathComponent("BookOrbitReadingState", isDirectory: true)
      .appendingPathComponent(OfflineResourceStore.hash(Data(namespace.utf8)), isDirectory: true)
    guard FileManager.default.fileExists(atPath: root.path) else { return false }
    let files = try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.fileSizeKey])
    guard files.count <= entryLimit else { throw OfflineStorageError.storageLimit }
    for file in files {
      guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
        size <= 256 * 1024
      else { throw ConnectionError.responseTooLarge }
      let data = try Data(contentsOf: file)
      guard
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { throw ConnectionError.invalidResponse }
      if value["fileID"] != nil {
        let progress = try JSONDecoder().decode(ProtectedProgress.self, from: data)
        if progress.pending != nil || progress.local != nil {
          guard let sourceRevision = progress.sourceRevision else {
            throw ConnectionError.invalidResponse
          }
          if progress.fileID == fileID,
            sourceRevision.replacingOccurrences(of: "sha256:", with: "")
              == revision.replacingOccurrences(of: "sha256:", with: "")
          {
            return true
          }
        }
      } else {
        let bookmarks = try JSONDecoder().decode(OfflineBookmarkState.self, from: data)
        if !bookmarks.operations.isEmpty || !bookmarks.recoveryOperations.isEmpty {
          guard !bookmarks.sourceRevisions.isEmpty else { throw ConnectionError.invalidResponse }
          if let sourceRevision = bookmarks.sourceRevisions[String(fileID)],
            sourceRevision.replacingOccurrences(of: "sha256:", with: "")
              == revision.replacingOccurrences(of: "sha256:", with: "")
          {
            return true
          }
        }
      }
    }
    return false
  }

  nonisolated static func withSourceRemovalProtection<T>(
    namespace: String, fileID: Int, revision: String, remove: () throws -> T
  ) throws -> T {
    protectionLock.lock()
    defer { protectionLock.unlock() }
    let protected: Bool
    do {
      protected = try hasProtectedWork(namespace: namespace, fileID: fileID, revision: revision)
    } catch {
      throw OfflineStorageError.unverifiedProtection
    }
    guard !protected else { throw OfflineStorageError.protectedVersion }
    return try remove()
  }

  func remove() throws {
    Self.protectionLock.lock()
    defer { Self.protectionLock.unlock() }
    if FileManager.default.fileExists(atPath: file.path) {
      try FileManager.default.removeItem(at: file)
    }
  }
}

struct OfflineProgressDraft: Codable {
  let cfi: String?
  let pageNumber: Double?
  let positionSeconds: Double?
  let mediaOverlayFragment: String?
  let mediaOverlaySectionIndex: Int?
  let percentage: Double
  let source: String?
  let baseVersion: String?

  init(_ value: SaveFileProgressPayload) {
    cfi = value.cfi
    pageNumber = value.pageNumber
    positionSeconds = value.positionSeconds
    mediaOverlayFragment = value.mediaOverlayFragment
    mediaOverlaySectionIndex = value.mediaOverlaySectionIndex
    percentage = value.percentage
    source = value.source
    baseVersion = value.baseVersion
  }

  var payload: SaveFileProgressPayload {
    var value = SaveFileProgressPayload(percentage: percentage)
    value.cfi = cfi
    value.pageNumber = pageNumber
    value.positionSeconds = positionSeconds
    value.mediaOverlayFragment = mediaOverlayFragment
    value.mediaOverlaySectionIndex = mediaOverlaySectionIndex
    value.source = source
    value.baseVersion = baseVersion
    return value
  }
}

struct OfflineBookmarkOperation: Codable, Identifiable {
  let id: UUID
  let path: String
  let method: String
  let body: Data?
  let localID: Int?
  let audioID: String?
  var transmitted = false
  var cancelAfterCreate = false

  private enum CodingKeys: String, CodingKey {
    case id, path, method, body, localID, audioID, transmitted, cancelAfterCreate
  }

  init(
    id: UUID, path: String, method: String, body: Data?, localID: Int?, audioID: String?,
    transmitted: Bool = false, cancelAfterCreate: Bool = false
  ) {
    self.id = id
    self.path = path
    self.method = method
    self.body = body
    self.localID = localID
    self.audioID = audioID
    self.transmitted = transmitted
    self.cancelAfterCreate = cancelAfterCreate
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    path = try values.decode(String.self, forKey: .path)
    method = try values.decode(String.self, forKey: .method)
    body = try values.decodeIfPresent(Data.self, forKey: .body)
    localID = try values.decodeIfPresent(Int.self, forKey: .localID)
    audioID = try values.decodeIfPresent(String.self, forKey: .audioID)
    transmitted = try values.decodeIfPresent(Bool.self, forKey: .transmitted) ?? false
    cancelAfterCreate = try values.decodeIfPresent(Bool.self, forKey: .cancelAfterCreate) ?? false
  }
}

struct OfflineBookmarkState: Codable {
  var operations: [OfflineBookmarkOperation] = []
  var recoveryOperations: [OfflineBookmarkOperation] = []
  var sourceRevisions: [String: String] = [:]
  var deletedIDs: [Int] = []
  var deletedAudioIDs: [String] = []
  var items: [BookmarkResponse] = []
  var audioItems: [AudiobookBookmark] = []
  var navigationItems: [EpubBookmarkNavigationItem] = []

  private enum CodingKeys: String, CodingKey {
    case operations, recoveryOperations, sourceRevisions, deletedIDs, deletedAudioIDs
    case items, audioItems, navigationItems
  }

  init() {}

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    operations =
      try values.decodeIfPresent([OfflineBookmarkOperation].self, forKey: .operations) ?? []
    recoveryOperations =
      try values.decodeIfPresent(
        [OfflineBookmarkOperation].self, forKey: .recoveryOperations) ?? []
    sourceRevisions =
      try values.decodeIfPresent([String: String].self, forKey: .sourceRevisions) ?? [:]
    deletedIDs = try values.decodeIfPresent([Int].self, forKey: .deletedIDs) ?? []
    deletedAudioIDs = try values.decodeIfPresent([String].self, forKey: .deletedAudioIDs) ?? []
    items = try values.decodeIfPresent([BookmarkResponse].self, forKey: .items) ?? []
    audioItems = try values.decodeIfPresent([AudiobookBookmark].self, forKey: .audioItems) ?? []
    navigationItems =
      try values.decodeIfPresent(
        [EpubBookmarkNavigationItem].self, forKey: .navigationItems) ?? []
  }
}

struct OfflineIdentifiedBookmark<Payload: Encodable>: Encodable {
  let payload: Payload
  let clientId: String

  func encode(to encoder: any Encoder) throws {
    try payload.encode(to: encoder)
    var container = encoder.container(keyedBy: IdentityKey.self)
    try container.encode(clientId, forKey: .clientId)
  }
  private enum IdentityKey: String, CodingKey { case clientId }
}

@MainActor
final class OfflineBookmarkOutbox {
  private let journal: OfflineReadingStateJournal
  private let namespace: String
  private let api: BookOrbitAPI
  private let bookID: Int
  private let fileID: Int?
  private let sourceIdentity: String
  private let sourceFileIDs: [Int]
  private(set) var state: OfflineBookmarkState
  private(set) var canWrite = false

  init(
    api: BookOrbitAPI, namespace: String, key: String, bookID: Int, fileID: Int?,
    sourceIdentity: String, sourceFileIDs: [Int]
  ) throws {
    self.api = api
    self.namespace = namespace
    self.bookID = bookID
    self.fileID = fileID
    self.sourceIdentity = sourceIdentity
    self.sourceFileIDs = sourceFileIDs
    let openedJournal = try OfflineReadingStateJournal(namespace: namespace, key: key)
    journal = openedJournal
    state =
      try fileID.flatMap {
        try openedJournal.readMigratingPending(
          OfflineBookmarkState.self, fileID: $0, bookmarks: true)
      } ?? openedJournal.read(OfflineBookmarkState.self) ?? OfflineBookmarkState()
    guard state.operations.count <= 128, state.recoveryOperations.count <= 128,
      state.items.count <= 40,
      state.audioItems.count <= 40, state.navigationItems.count <= 40
    else { throw ConnectionError.responseTooLarge }
  }

  static func open(
    api: BookOrbitAPI, bookID: Int, fileID: Int?, channel: String,
    sourceIdentity: String? = nil
  ) async throws -> OfflineBookmarkOutbox {
    let namespace = try await api.storageNamespace()
    let book: BookDetail = try await api.boundedJSON("books/\(bookID)", byteLimit: 2 * 1024 * 1024)
    let identity = try Self.identity(book: book, fileID: fileID)
    if let sourceIdentity, let fileID,
      identity != "\(fileID):\(sourceIdentity)"
    {
      throw ConnectionError.fileChanged
    }
    let result = try OfflineBookmarkOutbox(
      api: api, namespace: namespace,
      key: "bookmarks.\(bookID).\(fileID ?? 0).\(channel).\(identity)",
      bookID: bookID, fileID: fileID, sourceIdentity: identity,
      sourceFileIDs: book.files.filter { file in
        if let fileID { return file.id == fileID }
        return ["m4b", "m4a", "mp3", "opus", "ogg", "flac"].contains(
          file.format?.lowercased() ?? "")
      }.map(\.id))
    let session = try await api.authenticatedSessionGeneration()
    for id in result.sourceFileIDs {
      if result.state.sourceRevisions[String(id)] == nil,
        !result.state.operations.isEmpty || !result.state.recoveryOperations.isEmpty
      {
        throw ConnectionError.fileChanged
      }
      if result.state.sourceRevisions[String(id)] == nil
        || (result.state.operations.isEmpty && result.state.recoveryOperations.isEmpty)
      {
        let revision = try await api.sourceRevision(fileID: id, session: session)
        try result.update { $0.sourceRevisions[String(id)] = revision }
      }
    }
    let user: AuthUser = try await api.boundedJSON("auth/me", byteLimit: 1024 * 1024)
    result.canWrite =
      user.isSuperuser
      || (user.permissions.contains(Permission.libraryDownload.rawValue)
        && user.permissions.contains(Permission.annotationManageOwn.rawValue))
    return result
  }

  func update(_ change: (inout OfflineBookmarkState) -> Void) throws {
    var next = state
    change(&next)
    guard next.operations.count + next.recoveryOperations.count <= 128,
      next.deletedIDs.count <= 4096, next.deletedAudioIDs.count <= 4096
    else {
      throw OfflineStorageError.storageLimit
    }
    try journal.save(next)
    state = next
  }

  func checkSession(_ generation: UUID) async throws {
    guard try await api.storageNamespace() == namespace,
      try await api.authenticatedSessionGeneration() == generation
    else { throw ConnectionError.expiredSession }
  }

  private static func identity(book: BookDetail, fileID: Int?) throws -> String {
    let files = book.files.filter { fileID == nil || $0.id == fileID }
    guard !files.isEmpty else { throw ConnectionError.fileChanged }
    return files.sorted { $0.id < $1.id }.map {
      $0.format?.lowercased() == "pdf"
        ? "\($0.id):\($0.absolutePath)"
        : "\($0.id):\($0.absolutePath):\($0.sizeBytes ?? -1)"
    }.joined(separator: "|")
  }

  func flush(session: UUID) async throws {
    guard !state.operations.isEmpty else { return }
    let book: BookDetail = try await api.boundedJSON(
      "books/\(bookID)", byteLimit: 2 * 1024 * 1024, session: session)
    try await checkSession(session)
    guard try Self.identity(book: book, fileID: fileID) == sourceIdentity else {
      throw ConnectionError.fileChanged
    }
    for id in sourceFileIDs {
      guard let previous = state.sourceRevisions[String(id)] else {
        throw ConnectionError.fileChanged
      }
      let revision = try await api.reconciledSourceRevision(
        fileID: id, previous: previous, session: session)
      try update { $0.sourceRevisions[String(id)] = revision }
    }
    let user: AuthUser = try await api.boundedJSON(
      "auth/me", byteLimit: 1024 * 1024, session: session)
    try await checkSession(session)
    canWrite =
      user.isSuperuser
      || (user.permissions.contains(Permission.libraryDownload.rawValue)
        && user.permissions.contains(Permission.annotationManageOwn.rawValue))
    guard canWrite else { throw ConnectionError.denied }
    for operation in state.operations {
      try await checkSession(session)
      try update { state in
        if let index = state.operations.firstIndex(where: { $0.id == operation.id }) {
          state.operations[index].transmitted = true
        }
      }
      if operation.method == "DELETE" {
        do {
          try await api.sendEmpty(operation.path, method: "DELETE", session: session)
        } catch ConnectionError.http(404) {}
        try await checkSession(session)
        try update { state in
          state.operations.removeAll { $0.id == operation.id }
          if let id = operation.localID, !state.deletedIDs.contains(id) {
            state.deletedIDs.append(id)
          }
          if let id = operation.audioID, !state.deletedAudioIDs.contains(id) {
            state.deletedAudioIDs.append(id)
          }
        }
      } else if let audioID = operation.audioID {
        let saved: AudiobookBookmark
        do {
          saved = try await api.boundedJSON(
            operation.path, method: operation.method, body: operation.body, session: session)
        } catch ConnectionError.http(409) {
          try retainRecovery(operation)
          throw ConnectionError.http(409)
        } catch ConnectionError.http(404) {
          try retainRecovery(operation)
          throw ConnectionError.http(404)
        }
        try await checkSession(session)
        guard
          let original = state.audioItems.first(where: { $0.id == audioID })
            ?? (operation.body.flatMap {
              try? JSONDecoder().decode(CreateAudiobookBookmark.self, from: $0)
            }.map { draft in
              AudiobookBookmark(
                id: draft.clientId, bookId: bookID, positionMs: draft.positionMs,
                chapterId: draft.chapterId, title: draft.title, note: draft.note, createdAt: "",
                updatedAt: "")
            }),
          saved.id.lowercased() == audioID.lowercased(), saved.bookId == original.bookId,
          saved.positionMs == original.positionMs, saved.chapterId == original.chapterId,
          saved.title.unicodeScalars.count <= 500,
          saved.note.map({ $0.unicodeScalars.count <= 4000 }) ?? true
        else {
          throw ConnectionError.invalidResponse
        }
        if operation.cancelAfterCreate {
          do {
            try await api.sendEmpty(
              operation.path + "/" + saved.id, method: "DELETE", session: session)
          } catch ConnectionError.http(404) {}
          try await checkSession(session)
        }
        try update { state in
          state.operations.removeAll { $0.id == operation.id }
          state.audioItems.removeAll { $0.id == audioID }
          if !operation.cancelAfterCreate {
            state.audioItems.insert(saved, at: 0)
          } else if !state.deletedAudioIDs.contains(saved.id) {
            state.deletedAudioIDs.append(saved.id)
          }
          state.audioItems = Array(state.audioItems.prefix(40))
        }
      } else {
        let saved: BookmarkResponse
        do {
          saved = try await api.boundedJSON(
            operation.path, method: operation.method, body: operation.body, session: session)
        } catch ConnectionError.http(409) {
          try retainRecovery(operation)
          throw ConnectionError.http(409)
        } catch ConnectionError.http(404) {
          try retainRecovery(operation)
          throw ConnectionError.http(404)
        }
        try await checkSession(session)
        let components = operation.path.split(separator: "/")
        guard components.count >= 3, saved.id > 0, saved.bookId == Int(components[1]),
          saved.title.unicodeScalars.count <= 500,
          saved.positionSeconds == nil,
          (saved.cfi != nil && saved.fileId == nil && saved.pageNumber == nil)
            || (saved.cfi == nil && saved.fileId != nil && saved.pageNumber.map({ $0 > 0 }) == true)
        else { throw ConnectionError.invalidResponse }
        guard let body = operation.body else { throw ConnectionError.invalidResponse }
        if operation.path.hasSuffix("/fixed-page") {
          let draft = try JSONDecoder().decode(CreateFixedPageBookmarkPayload.self, from: body)
          guard saved.fileId == draft.fileId, saved.pageNumber == draft.pageNumber else {
            throw ConnectionError.invalidResponse
          }
        } else {
          let draft = try JSONDecoder().decode(CreateEpubBookmarkPayload.self, from: body)
          guard saved.cfi == draft.cfi else { throw ConnectionError.invalidResponse }
        }
        if operation.cancelAfterCreate {
          let components = operation.path.split(separator: "/")
          let path = "books/\(components[1])/bookmarks/\(saved.id)"
          do {
            try await api.sendEmpty(path, method: "DELETE", session: session)
          } catch ConnectionError.http(404) {}
          try await checkSession(session)
        }
        try update { state in
          state.operations.removeAll { $0.id == operation.id }
          state.items.removeAll { $0.id == operation.localID || $0.id == saved.id }
          if !operation.cancelAfterCreate {
            state.items.insert(saved, at: 0)
          } else if !state.deletedIDs.contains(saved.id) {
            state.deletedIDs.append(saved.id)
          }
          state.items = Array(state.items.prefix(40))
        }
      }
    }
  }

  private func retainRecovery(_ operation: OfflineBookmarkOperation) throws {
    try update { state in
      state.operations.removeAll { $0.id == operation.id }
      state.recoveryOperations.append(operation)
    }
  }

  static func temporaryID(_ id: UUID) -> Int {
    -Int(UInt64(id.uuidString.replacingOccurrences(of: "-", with: "").prefix(12), radix: 16)!) - 1
  }
}
