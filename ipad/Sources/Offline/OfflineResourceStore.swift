import CryptoKit
import Foundation

struct OfflineResource: Codable, Sendable, Identifiable {
  var path: String
  var query: [OfflineQuery] = []
  var expectedBytes: Int64?
  var receivedBytes: Int64 = 0
  var digest: String?
  var validator: String?
  var sourceDigest: String?
  var bookID: Int?
  var fileID: Int?
  var id: String { OfflineResourceStore.key(path: path, query: query.map(\.item)) }
}

struct OfflineQuery: Codable, Sendable {
  let name: String
  let value: String?
  var item: URLQueryItem { URLQueryItem(name: name, value: value) }
}

struct OfflineBookSnapshot: Codable, Sendable, Identifiable {
  var book: BookDetail
  var selectedFileIDs: [Int]
  var resources: [OfflineResource] = []
  var state = "preparing"
  var message: String?
  var updatedAt = Date()
  var id: Int { book.id }
  var receivedBytes: Int64 { resources.reduce(0) { $0 + $1.receivedBytes } }
  var knownBytes: Int64 { resources.reduce(0) { $0 + ($1.expectedBytes ?? $1.receivedBytes) } }
}

actor OfflineResourceStore {
  static let byteLimit: Int64 = 4 * 1024 * 1024 * 1024
  static let bookLimit = 500
  private static let resourceFileLimit = 350_000
  let root: URL
  private let namespace: String
  private var verified: [String: Date] = [:]
  private var sizes: [String: Int64]?
  private var usedBytes: Int64 = 0
  private var activeBookTransfers: Set<Int> = []

  init(namespace: String) throws {
    self.namespace = namespace
    root = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ).appendingPathComponent("BookOrbitOffline", isDirectory: true)
      .appendingPathComponent(Self.hash(Data(namespace.utf8)), isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var protected = root
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try protected.setResourceValues(values)
    try FileManager.default.setAttributes(
      [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
      ofItemAtPath: root.path)
  }

  nonisolated static func key(path: String, query: [URLQueryItem] = []) -> String {
    let sorted = query.sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
    var components = URLComponents()
    components.path = path
    components.queryItems = sorted.isEmpty ? nil : sorted
    return hash(Data((components.string ?? path).utf8))
  }

  nonisolated static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  func snapshot(bookID: Int) throws -> OfflineBookSnapshot? {
    let file = root.appendingPathComponent("book-\(bookID).json")
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    guard (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max <= 32 * 1024 * 1024
    else { throw ConnectionError.responseTooLarge }
    return try JSONDecoder().decode(OfflineBookSnapshot.self, from: Data(contentsOf: file))
  }

  func save(_ snapshot: OfflineBookSnapshot) throws {
    guard snapshot.selectedFileIDs.count <= 4096, snapshot.resources.count <= 100_000 else {
      throw ConnectionError.responseTooLarge
    }
    if try self.snapshot(bookID: snapshot.id) == nil, try bookIDs().count >= Self.bookLimit {
      throw OfflineStorageError.bookLimit
    }
    let data = try JSONEncoder().encode(snapshot)
    guard data.count <= 32 * 1024 * 1024 else { throw ConnectionError.responseTooLarge }
    let file = root.appendingPathComponent("book-\(snapshot.id).json")
    let existing = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    try reserve(max(0, Int64(data.count) - existing))
    try data.write(to: file, options: .atomic)
    recordUsage(file, size: Int64(data.count))
    let summary = OfflineBookSummary(
      id: snapshot.id, title: snapshot.book.title ?? "Untitled book", state: snapshot.state,
      selectedFileCount: snapshot.selectedFileIDs.count)
    let summaryFile = root.appendingPathComponent("summary-\(snapshot.id).json")
    let summaryData = try JSONEncoder().encode(summary)
    try reserve(max(0, Int64(summaryData.count) - (sizes?[summaryFile.lastPathComponent] ?? 0)))
    try summaryData.write(to: summaryFile, options: .atomic)
    recordUsage(summaryFile, size: Int64(summaryData.count))
  }

  func summaries() throws -> [OfflineBookSummary] {
    try bookIDs().compactMap { id in
      let file = root.appendingPathComponent("summary-\(id).json")
      if FileManager.default.fileExists(atPath: file.path) {
        guard (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max <= 16 * 1024
        else { throw ConnectionError.responseTooLarge }
        return try JSONDecoder().decode(OfflineBookSummary.self, from: Data(contentsOf: file))
      }
      guard let book = try snapshot(bookID: id) else { return nil }
      return OfflineBookSummary(
        id: id, title: book.book.title ?? "Untitled book", state: book.state,
        selectedFileCount: book.selectedFileIDs.count)
    }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
  }

  func bookID(fileID: Int) throws -> Int? {
    if let resource = try sourceIndex(fileID: fileID), let bookID = resource.bookID {
      return bookID
    }
    for id in try bookIDs() {
      if try snapshot(bookID: id)?.book.files.contains(where: { $0.id == fileID }) == true {
        return id
      }
    }
    return nil
  }

  func sourceResource(fileID: Int) throws -> OfflineResource? {
    if let resource = try sourceIndex(fileID: fileID) { return resource }
    guard let bookID = try bookID(fileID: fileID), let snapshot = try snapshot(bookID: bookID)
    else { return nil }
    let served = OfflineResourceStore.key(path: "books/files/\(fileID)/serve")
    if let source = snapshot.resources.first(where: { $0.id == served }) { return source }
    guard let data = try read(path: "audiobooks/\(bookID)/manifest", limit: 1024 * 1024),
      let manifest = try? JSONDecoder().decode(AudiobookManifest.self, from: data),
      let asset = manifest.assets.first(where: { $0.fileId == fileID })
    else { return nil }
    let id = OfflineResourceStore.key(path: "audiobooks/\(bookID)/assets/\(asset.assetId)/content")
    return snapshot.resources.first { $0.id == id }
      ?? OfflineResource(
        path: "audiobooks/\(bookID)/assets/\(asset.assetId)/content", bookID: bookID, fileID: fileID
      )
  }

  private func sourceIndex(fileID: Int) throws -> OfflineResource? {
    let file = root.appendingPathComponent("source-file-\(fileID).json")
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    guard (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max < 64 * 1024 else {
      throw ConnectionError.responseTooLarge
    }
    let resource = try JSONDecoder().decode(OfflineResource.self, from: Data(contentsOf: file))
    guard resource.fileID == fileID else { throw ConnectionError.invalidResponse }
    return resource
  }

  private func writeSourceIndex(_ resource: OfflineResource) throws {
    guard let fileID = resource.fileID, resource.bookID != nil else { return }
    let file = root.appendingPathComponent("source-file-\(fileID).json")
    let data = try JSONEncoder().encode(resource)
    try reserve(max(0, Int64(data.count) - (sizes?[file.lastPathComponent] ?? 0)))
    try data.write(to: file, options: .atomic)
    recordUsage(file, size: Int64(data.count))
  }

  func receipt(path: String, query: [URLQueryItem] = []) throws -> OfflineResource? {
    guard let file = try verifiedURL(path: path, query: query) else { return nil }
    return try JSONDecoder().decode(
      OfflineResource.self, from: Data(contentsOf: file.appendingPathExtension("receipt")))
  }

  func books() throws -> [OfflineBookSnapshot] {
    let files = try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil
    )
    .filter { $0.lastPathComponent.hasPrefix("book-") && $0.pathExtension == "json" }
    guard files.count <= Self.bookLimit else { throw OfflineStorageError.bookLimit }
    return try files.compactMap { file in
      guard let id = Int(file.deletingPathExtension().lastPathComponent.dropFirst(5)) else {
        return nil
      }
      return try snapshot(bookID: id)
    }.sorted { $0.updatedAt > $1.updatedAt }
  }

  func destination(path: String, query: [URLQueryItem] = []) -> URL {
    root.appendingPathComponent(Self.key(path: path, query: query) + ".resource")
  }

  func read(path: String, query: [URLQueryItem] = [], limit: Int) throws -> Data? {
    guard let file = try verifiedURL(path: path, query: query),
      let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= limit
    else { return nil }
    return try Data(contentsOf: file)
  }

  func verifiedURL(path: String, query: [URLQueryItem] = []) throws -> URL? {
    let file = destination(path: path, query: query)
    let receipt = file.appendingPathExtension("receipt")
    guard FileManager.default.fileExists(atPath: file.path),
      FileManager.default.fileExists(atPath: receipt.path)
    else { return nil }
    let resource = try JSONDecoder().decode(OfflineResource.self, from: Data(contentsOf: receipt))
    let attributes = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    guard attributes.fileSize.map(Int64.init) == resource.receivedBytes,
      let date = attributes.contentModificationDate
    else { throw OfflineStorageError.corruptResource }
    if verified[file.lastPathComponent] != date {
      guard let digest = resource.digest, try checksum(file) == digest else {
        throw OfflineStorageError.corruptResource
      }
      verified[file.lastPathComponent] = date
    }
    return file
  }

  @discardableResult
  func write<T: Encodable>(_ value: T, path: String, query: [URLQueryItem] = []) throws
    -> OfflineResource
  {
    try writeData(JSONEncoder().encode(value), path: path, query: query)
  }

  func contains(path: String, query: [URLQueryItem] = []) -> Bool {
    FileManager.default.fileExists(
      atPath: destination(path: path, query: query).appendingPathExtension("receipt").path)
  }

  @discardableResult
  func writeData(_ data: Data, path: String, query: [URLQueryItem] = []) throws -> OfflineResource {
    guard data.count <= 8 * 1024 * 1024 else { throw ConnectionError.responseTooLarge }
    let file = destination(path: path, query: query)
    let existing = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    try reserve(max(0, Int64(data.count) - existing))
    try data.write(to: file, options: .atomic)
    return try finish(
      OfflineResource(
        path: path, query: query.map { OfflineQuery(name: $0.name, value: $0.value) }), at: file)
  }

  func finish(_ resource: OfflineResource, at file: URL) throws -> OfflineResource {
    var resource = resource
    guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      resource.expectedBytes.map({ $0 == Int64(size) }) ?? true
    else { throw ConnectionError.fileChanged }
    resource.receivedBytes = Int64(size)
    resource.expectedBytes = Int64(size)
    resource.digest = try checksum(file)
    guard resource.sourceDigest.map({ $0 == resource.digest }) ?? true else {
      throw OfflineStorageError.corruptResource
    }
    recordUsage(file, size: Int64(size))
    try writeReceipt(resource, file: file)
    verified[file.lastPathComponent] = try file.resourceValues(forKeys: [
      .contentModificationDateKey
    ]).contentModificationDate
    return resource
  }

  func publish(
    _ resource: OfflineResource, partial: URL, destination: URL,
    knownPublication: Bool = false
  ) throws
    -> OfflineResource
  {
    var completed = resource
    guard let size = try partial.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      resource.expectedBytes == Int64(size)
    else { throw ConnectionError.fileChanged }
    completed.receivedBytes = Int64(size)
    completed.digest = try checksum(partial)
    guard resource.sourceDigest.map({ $0 == completed.digest }) ?? true else {
      throw OfflineStorageError.corruptResource
    }
    let receipt = destination.appendingPathExtension("receipt")
    if FileManager.default.fileExists(atPath: destination.path) {
      if let oldData = try? Data(contentsOf: receipt),
        let previous = try? JSONDecoder().decode(OfflineResource.self, from: oldData),
        previous.digest != completed.digest, !knownPublication
      {
        try retainVersion(
          previous, source: destination, receiptData: oldData, reason: "source_replaced")
      }
      if FileManager.default.fileExists(atPath: destination.path) {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
      } else {
        try FileManager.default.moveItem(at: partial, to: destination)
      }
    } else {
      try FileManager.default.moveItem(at: partial, to: destination)
    }
    recordUsage(partial, size: 0)
    recordUsage(destination, size: Int64(size))
    try writeReceipt(completed, file: destination)
    try writeSourceIndex(completed)
    verified[destination.lastPathComponent] = try destination.resourceValues(forKeys: [
      .contentModificationDateKey
    ]).contentModificationDate
    return completed
  }

  func advancePublishedSource(bookID: Int, fileID: Int, resource: OfflineResource) throws {
    guard var snapshot = try snapshot(bookID: bookID), let digest = resource.digest else {
      throw ConnectionError.invalidResponse
    }
    if let index = snapshot.book.files.firstIndex(where: { $0.id == fileID }) {
      snapshot.book.files[index].sizeBytes = Double(resource.receivedBytes)
    }
    for index in snapshot.resources.indices {
      let cached = snapshot.resources[index]
      if cached.id == resource.id {
        snapshot.resources[index] = resource
      } else if cached.path == "annotations/native/files/\(fileID)/source",
        let data = try read(path: cached.path, query: cached.query.map(\.item), limit: 1024 * 1024)
      {
        if var descriptor = try? JSONDecoder().decode(NativePdfPageSource.self, from: data) {
          descriptor.sourceRevision = "sha256:\(digest)"
          descriptor.matchedSourceRevision = nil
          snapshot.resources[index] = try write(
            descriptor, path: cached.path, query: cached.query.map(\.item))
        } else if var batch = try? JSONDecoder().decode(NativePdfPageSourceBatch.self, from: data) {
          batch.sourceRevision = "sha256:\(digest)"
          for page in batch.pages.indices {
            batch.pages[page].sourceRevision = batch.sourceRevision
            batch.pages[page].matchedSourceRevision = nil
          }
          snapshot.resources[index] = try write(
            batch, path: cached.path, query: cached.query.map(\.item))
        }
      }
    }
    try save(snapshot)
  }

  func retainOpenedPdfSource(
    book: BookDetail, fileID: Int, source: URL, revision: String, reason: String
  ) throws {
    let digest = revision.replacingOccurrences(of: "sha256:", with: "")
    guard digest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
      book.files.contains(where: { $0.id == fileID && $0.format?.lowercased() == "pdf" }),
      try checksum(source) == digest,
      let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      (1...(100 * 1024 * 1024)).contains(size)
    else { throw ConnectionError.invalidResponse }
    var retained =
      try snapshot(bookID: book.id)
      ?? OfflineBookSnapshot(book: book, selectedFileIDs: [])
    if !retained.book.files.contains(where: { $0.id == fileID }),
      let file = book.files.first(where: { $0.id == fileID })
    {
      retained.book.files.append(file)
    }
    retained.state = "recovery"
    retained.message =
      "The source changed. The complete PDF you were reading is retained for review."
    try save(retained)
    let resource = OfflineResource(
      path: "books/files/\(fileID)/serve", expectedBytes: Int64(size), receivedBytes: Int64(size),
      digest: digest, validator: "\"\(digest)\"", sourceDigest: digest, bookID: book.id,
      fileID: fileID)
    let id = "recovery-\(resource.id)-\(digest)"
    if FileManager.default.fileExists(atPath: root.appendingPathComponent(id + ".version").path) {
      return
    }
    try reserve(Int64(size))
    let copy = root.appendingPathComponent("open-pdf-\(UUID().uuidString).resource")
    try FileManager.default.copyItem(at: source, to: copy)
    recordUsage(copy, size: Int64(size))
    do {
      try retainVersion(
        resource, source: copy, receiptData: JSONEncoder().encode(resource), reason: reason)
    } catch {
      try? FileManager.default.removeItem(at: copy)
      recordUsage(copy, size: 0)
      throw error
    }
  }

  func sourceVersions(bookID: Int? = nil, fileID: Int? = nil, after: String? = nil, limit: Int = 40)
    throws -> OfflineSourceVersionsPage
  {
    guard (1...40).contains(limit), bookID.map({ $0 > 0 }) ?? true, fileID.map({ $0 > 0 }) ?? true
    else { throw ConnectionError.invalidResponse }
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.fileSizeKey],
        options: [.skipsSubdirectoryDescendants])
    else { throw ConnectionError.invalidResponse }
    var results: [OfflineSourceVersion] = []
    for case let file as URL in enumerator where file.pathExtension == "version" {
      guard (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max < 16 * 1024
      else { throw ConnectionError.responseTooLarge }
      let version = try JSONDecoder().decode(
        OfflineSourceVersion.self, from: Data(contentsOf: file))
      guard bookID == nil || version.bookID == bookID, fileID == nil || version.fileID == fileID,
        after.map({ version.id > $0 }) ?? true
      else { continue }
      results.append(version)
      results.sort { $0.id < $1.id }
      if results.count > limit + 1 { results.removeLast() }
    }
    let hasMore = results.count > limit
    let items = Array(results.prefix(limit))
    return OfflineSourceVersionsPage(items: items, nextCursor: hasMore ? items.last?.id : nil)
  }

  func sourceVersion(id: String) throws -> OfflineSourceVersion {
    guard id.range(of: "^recovery-[a-f0-9]{64}-[a-f0-9]{64}$", options: .regularExpression) != nil
    else { throw ConnectionError.invalidResponse }
    let file = root.appendingPathComponent(id + ".version")
    guard (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max < 16 * 1024 else {
      throw ConnectionError.responseTooLarge
    }
    let version = try JSONDecoder().decode(OfflineSourceVersion.self, from: Data(contentsOf: file))
    guard version.id == id else { throw ConnectionError.invalidResponse }
    return version
  }

  func exportSourceVersion(id: String) throws -> StagedBookFile {
    let version = try sourceVersion(id: id)
    let source = root.appendingPathComponent(id + ".resource")
    guard try checksum(source) == version.revision,
      try source.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)
        == version.sizeBytes
    else { throw OfflineStorageError.corruptResource }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bookorbit-recovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let format =
      version.format.range(of: "^[a-z0-9]{1,10}$", options: .regularExpression) != nil
      ? version.format : "content"
    let filename =
      "book-\(version.bookID)-file-\(version.fileID)-\(version.revision.prefix(12)).\(format)"
    let url = directory.appendingPathComponent(filename)
    do { try FileManager.default.copyItem(at: source, to: url) } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
    return StagedBookFile(
      directory: directory, url: url, filename: filename, size: version.sizeBytes)
  }

  func exportDownloadedResource(fileID: Int) throws -> StagedBookFile {
    guard let resource = try sourceResource(fileID: fileID),
      let bookID = try resource.bookID ?? bookID(fileID: fileID),
      let snapshot = try snapshot(bookID: bookID),
      let edition = snapshot.book.files.first(where: { $0.id == fileID }),
      let source = try verifiedURL(path: resource.path, query: resource.query.map(\.item)),
      let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize
    else { throw ConnectionError.invalidResponse }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bookorbit-offline-export-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let offered = edition.format?.lowercased() ?? "content"
    let format =
      offered.range(of: "^[a-z0-9]{1,10}$", options: .regularExpression) != nil
      ? offered : "content"
    let filename = "book-file-\(fileID).\(format)"
    let url = directory.appendingPathComponent(filename)
    do { try FileManager.default.copyItem(at: source, to: url) } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
    return StagedBookFile(directory: directory, url: url, filename: filename, size: Int64(size))
  }

  func removeSourceVersion(id: String) throws {
    let version = try sourceVersion(id: id)
    try OfflineReadingStateJournal.withSourceRemovalProtection(
      namespace: namespace, fileID: version.fileID, revision: version.revision
    ) {
      for suffix in ["resource", "resource.receipt", "version"] {
        let file = root.appendingPathComponent(id + "." + suffix)
        if FileManager.default.fileExists(atPath: file.path) {
          try FileManager.default.removeItem(at: file)
        }
        recordUsage(file, size: 0)
      }
    }
  }

  func invalidateDerivedResources(bookID: Int, fileID: Int) throws {
    guard var snapshot = try snapshot(bookID: bookID) else { return }
    for index in snapshot.resources.indices {
      let resource = snapshot.resources[index]
      let editionQuery = resource.query.contains {
        $0.name == "fileId" && $0.value == String(fileID)
      }
      let derived =
        (resource.path.hasPrefix("epub/\(bookID)/") && editionQuery)
        || resource.path.hasPrefix("cbz/files/\(fileID)/pages")
        || resource.path == "annotations/native/files/\(fileID)/source"
      guard derived else { continue }
      let file = destination(path: resource.path, query: resource.query.map(\.item))
      for item in [file, file.appendingPathExtension("receipt")] {
        if FileManager.default.fileExists(atPath: item.path) {
          try FileManager.default.removeItem(at: item)
        }
        recordUsage(item, size: 0)
      }
      verified[file.lastPathComponent] = nil
      snapshot.resources[index].digest = nil
      snapshot.resources[index].receivedBytes = 0
    }
    snapshot.state = "recovery"
    try save(snapshot)
  }

  func retainCurrentSource(fileID: Int, reason: String) throws {
    let retained = try sourceResource(fileID: fileID)
    let source = destination(
      path: retained?.path ?? "books/files/\(fileID)/serve",
      query: retained?.query.map(\.item) ?? [])
    let receipt = source.appendingPathExtension("receipt")
    guard FileManager.default.fileExists(atPath: source.path),
      FileManager.default.fileExists(atPath: receipt.path)
    else { return }
    let data = try Data(contentsOf: receipt)
    let resource = try JSONDecoder().decode(OfflineResource.self, from: data)
    try retainVersion(resource, source: source, receiptData: data, reason: reason)
  }

  private func retainVersion(
    _ resource: OfflineResource, source: URL, receiptData: Data, reason: String
  ) throws {
    let parts = resource.path.split(separator: "/")
    let deliveredID =
      parts.count == 4 && parts[0] == "books" && parts[1] == "files" && parts[3] == "serve"
      ? Int(parts[2]) : nil
    guard let fileID = resource.fileID ?? deliveredID, let revision = resource.digest else {
      return
    }
    let id = "recovery-\(resource.id)-\(revision)"
    if FileManager.default.fileExists(atPath: root.appendingPathComponent(id + ".version").path) {
      return
    }
    let owners = try resource.bookID.map { [$0] } ?? bookIDs()
    for bookID in owners {
      guard let snapshot = try snapshot(bookID: bookID),
        let file = snapshot.book.files.first(where: { $0.id == fileID })
      else { continue }
      let version = OfflineSourceVersion(
        id: id, bookID: bookID, fileID: fileID,
        title: snapshot.book.title ?? "Untitled book", filename: file.filename ?? "Book file",
        format: file.format?.lowercased() ?? "content", revision: revision,
        sizeBytes: resource.receivedBytes, capturedAt: Date(), reason: reason)
      let metadata = try JSONEncoder().encode(version)
      try reserve(Int64(receiptData.count + metadata.count))
      let recovery = root.appendingPathComponent(id + ".resource")
      if !FileManager.default.fileExists(atPath: recovery.path) {
        try FileManager.default.moveItem(at: source, to: recovery)
        recordUsage(source, size: 0)
      }
      try receiptData.write(to: recovery.appendingPathExtension("receipt"), options: .atomic)
      try metadata.write(to: root.appendingPathComponent(id + ".version"), options: .atomic)
      recordUsage(recovery, size: resource.receivedBytes)
      recordUsage(recovery.appendingPathExtension("receipt"), size: Int64(receiptData.count))
      recordUsage(root.appendingPathComponent(id + ".version"), size: Int64(metadata.count))
      return
    }
  }

  func beginBookTransfer(bookID: Int) throws {
    guard !activeBookTransfers.contains(bookID) else { throw OfflineStorageError.activeDownload }
    activeBookTransfers.insert(bookID)
  }

  func endBookTransfer(bookID: Int) { activeBookTransfers.remove(bookID) }

  func removeBook(bookID: Int) throws {
    do {
      try removeBookResources(bookID: bookID)
    } catch let error as OfflineStorageError {
      throw error
    } catch {
      throw OfflineStorageError.unverifiedDownload
    }
  }

  private func removeBookResources(bookID: Int) throws {
    guard bookID > 0, let snapshot = try snapshot(bookID: bookID), snapshot.id == bookID,
      snapshot.book.files.count <= 4096, snapshot.resources.count <= 100_000
    else { throw OfflineStorageError.unverifiedDownload }
    guard !activeBookTransfers.contains(bookID) else { throw OfflineStorageError.activeDownload }
    var candidates = Set(snapshot.resources.map(\.id))
    var fileIDs = Set(snapshot.book.files.map(\.id))
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.fileSizeKey],
        options: [.skipsSubdirectoryDescendants])
    else { throw OfflineStorageError.unverifiedDownload }
    var scanned = 0
    for case let file as URL in enumerator {
      scanned += 1
      guard scanned <= Self.resourceFileLimit else { throw OfflineStorageError.unverifiedDownload }
      guard !file.lastPathComponent.hasPrefix("recovery-") else { continue }
      guard
        file.lastPathComponent.hasSuffix(".resource.receipt")
          || file.lastPathComponent.hasSuffix(".resource.transfer")
      else { continue }
      guard (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max <= 64 * 1024
      else { throw OfflineStorageError.unverifiedDownload }
      let resource = try JSONDecoder().decode(OfflineResource.self, from: Data(contentsOf: file))
      guard file.lastPathComponent == resource.id + ".resource." + file.pathExtension else {
        throw OfflineStorageError.unverifiedDownload
      }
      if resource.bookID == bookID || belongsToBook(resource, bookID: bookID, fileIDs: fileIDs) {
        candidates.insert(resource.id)
        if let fileID = resource.fileID { fileIDs.insert(fileID) }
      }
      guard candidates.count <= Self.resourceFileLimit else {
        throw OfflineStorageError.unverifiedDownload
      }
    }
    // A shared font or metadata receipt may serve several explicit downloads.
    for otherID in try bookIDs() where otherID != bookID {
      guard let other = try self.snapshot(bookID: otherID), other.id == otherID,
        other.resources.count <= 100_000
      else { throw OfflineStorageError.unverifiedDownload }
      for resource in other.resources { candidates.remove(resource.id) }
    }
    var sourceIndexes: [URL] = []
    for fileID in fileIDs {
      if let indexed = try sourceIndex(fileID: fileID), indexed.bookID == bookID,
        candidates.contains(indexed.id)
      {
        sourceIndexes.append(root.appendingPathComponent("source-file-\(fileID).json"))
      }
    }
    try NativeAnnotationStore.withOfflineBookRemovalProtection(namespace: namespace, bookID: bookID)
    {
      try OfflineReadingStateJournal.withBookRemovalProtection(
        namespace: namespace, fileIDs: fileIDs
      ) {
        for id in candidates {
          let file = root.appendingPathComponent(id + ".resource")
          for item in [
            file, file.appendingPathExtension("receipt"),
            file.appendingPathExtension("partial"), file.appendingPathExtension("transfer"),
          ] {
            try removeLocalFile(item)
          }
          verified[file.lastPathComponent] = nil
        }
        for index in sourceIndexes { try removeLocalFile(index) }
        try removeLocalFile(root.appendingPathComponent("book-\(bookID).json"))
        try removeLocalFile(root.appendingPathComponent("summary-\(bookID).json"))
      }
    }
  }

  private func belongsToBook(_ resource: OfflineResource, bookID: Int, fileIDs: Set<Int>) -> Bool {
    let parts = resource.path.split(separator: "/")
    guard parts.count >= 2 else { return false }
    if ["epub", "audiobooks"].contains(parts[0]), Int(parts[1]) == bookID { return true }
    if parts[0] == "books", Int(parts[1]) == bookID { return true }
    if parts.count >= 3, parts[1] == "files", ["books", "cbz"].contains(parts[0]),
      let fileID = Int(parts[2]), fileIDs.contains(fileID)
    {
      return true
    }
    if parts.count >= 4, parts[0] == "annotations", parts[1] == "native", parts[2] == "files",
      let fileID = Int(parts[3]), fileIDs.contains(fileID)
    {
      return true
    }
    if parts.count == 3, parts[0] == "reader", parts[1] == "preferences",
      let fileID = Int(parts[2]), fileIDs.contains(fileID)
    {
      return true
    }
    return false
  }

  private func removeLocalFile(_ file: URL) throws {
    if FileManager.default.fileExists(atPath: file.path) {
      try FileManager.default.removeItem(at: file)
    }
    recordUsage(file, size: 0)
  }

  private func bookIDs() throws -> [Int] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants])
    else { throw ConnectionError.invalidResponse }
    var ids: [Int] = []
    for case let file as URL in enumerator
    where file.lastPathComponent.hasPrefix("book-") && file.pathExtension == "json" {
      if let id = Int(file.deletingPathExtension().lastPathComponent.dropFirst(5)) {
        ids.append(id)
      }
      guard ids.count <= Self.bookLimit else { throw OfflineStorageError.bookLimit }
    }
    return ids
  }

  func reserve(_ additional: Int64) throws {
    guard additional >= 0, additional <= Self.byteLimit else {
      throw OfflineStorageError.storageLimit
    }
    if sizes == nil {
      guard
        let enumerator = FileManager.default.enumerator(
          at: root, includingPropertiesForKeys: [.fileSizeKey],
          options: [.skipsSubdirectoryDescendants])
      else { throw ConnectionError.invalidResponse }
      var measured: [String: Int64] = [:]
      for case let file as URL in enumerator {
        guard measured.count < Self.resourceFileLimit else {
          throw OfflineStorageError.storageLimit
        }
        measured[file.lastPathComponent] = Int64(
          try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
      }
      sizes = measured
    }
    if usedBytes == 0 { usedBytes = sizes!.values.reduce(0, +) }
    guard sizes!.count < Self.resourceFileLimit - 8 else { throw OfflineStorageError.storageLimit }
    guard usedBytes <= Self.byteLimit - additional else { throw OfflineStorageError.storageLimit }
    let capacity = try FileManager.default.attributesOfFileSystem(forPath: root.path)
    guard let free = capacity[.systemFreeSize] as? NSNumber,
      additional <= free.int64Value - 128 * 1024 * 1024
    else { throw ConnectionError.insufficientStorage }
  }

  func saveTransfer(_ resource: OfflineResource, destination: URL) throws {
    let data = try JSONEncoder().encode(resource)
    guard data.count <= 64 * 1024 else { throw ConnectionError.responseTooLarge }
    let file = destination.appendingPathExtension("transfer")
    try reserve(max(0, Int64(data.count) - (sizes?[file.lastPathComponent] ?? 0)))
    try data.write(to: file, options: .atomic)
    recordUsage(file, size: Int64(data.count))
  }

  func finishTransfer(destination: URL) throws {
    let file = destination.appendingPathExtension("transfer")
    if FileManager.default.fileExists(atPath: file.path) {
      try FileManager.default.removeItem(at: file)
    }
    recordUsage(file, size: 0)
  }

  private func writeReceipt(_ resource: OfflineResource, file: URL) throws {
    let receipt = file.appendingPathExtension("receipt")
    let data = try JSONEncoder().encode(resource)
    try reserve(max(0, Int64(data.count) - (sizes?[receipt.lastPathComponent] ?? 0)))
    try data.write(to: receipt, options: .atomic)
    recordUsage(receipt, size: Int64(data.count))
  }

  func reserveTransfer(destination: URL, total: Int64) throws {
    let partial = destination.appendingPathExtension("partial")
    let existing = Int64((try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    try reserve(max(0, total - (sizes?[partial.lastPathComponent] ?? existing)))
    recordUsage(partial, size: total)
  }

  private func recordUsage(_ file: URL, size: Int64) {
    guard sizes != nil else { return }
    let previous = sizes?[file.lastPathComponent] ?? 0
    usedBytes += size - previous
    sizes?[file.lastPathComponent] = size == 0 ? nil : size
  }

  private func checksum(_ file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hash = SHA256()
    while let bytes = try handle.read(upToCount: 256 * 1024), !bytes.isEmpty {
      hash.update(data: bytes)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

enum OfflineStorageError: LocalizedError {
  case storageLimit, bookLimit, corruptResource, protectedVersion, unverifiedProtection
  case protectedDownload, unverifiedDownload, activeDownload
  var errorDescription: String? {
    switch self {
    case .protectedDownload:
      "This download is needed by pending notes, bookmarks, reading progress, or recovery work. Keep or export the content, then synchronize or resolve that work before removing the download."
    case .unverifiedDownload:
      "Saved work or download references could not be checked safely. The download is retained. Restore the saved work or reconnect and retry removal."
    case .activeDownload:
      "This book is downloading in another view. Pause the download before removing its content."
    case .protectedVersion:
      "This version is required by pending annotations, bookmarks, reading progress, or a recovery draft. Export it and resolve the saved work before removing it."
    case .unverifiedProtection:
      "Saved reading work could not be checked. This version remains protected. Export it and restore the saved work before retrying removal."
    case .storageLimit:
      "Offline storage has reached its 4 GB limit. Remove another download or an unprotected retained version, then retry. Your pending work remains protected."
    case .bookLimit:
      "This iPad supports up to 500 explicitly selected offline books. Remove another download before adding this book."
    case .corruptResource:
      "A downloaded resource failed verification. Connect and retry its download."
    }
  }
}

struct OfflineSourceVersion: Codable, Sendable, Identifiable {
  let id: String
  let bookID: Int
  let fileID: Int
  let title: String
  let filename: String
  let format: String
  let revision: String
  let sizeBytes: Int64
  let capturedAt: Date
  let reason: String
}

struct OfflineSourceVersionsPage: Sendable {
  let items: [OfflineSourceVersion]
  let nextCursor: String?
}

struct OfflineBookSummary: Codable, Sendable, Identifiable {
  let id: Int
  let title: String
  let state: String
  let selectedFileCount: Int
}
