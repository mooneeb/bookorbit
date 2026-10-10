import Foundation
import Observation
import PDFKit

@MainActor @Observable
final class OfflineBookModel {
  let api: BookOrbitAPI
  let book: BookDetail
  var selectedFileIDs: Set<Int> = []
  private(set) var snapshot: OfflineBookSnapshot?
  private(set) var isBusy = false
  private(set) var status =
    "Choose the complete files, media, and companion documents to keep on this iPad."
  private(set) var error: String?
  var confirmsRemoval = false
  private var namespace: String?
  private var task: Task<Void, Never>?
  private var pauseRequested = false
  private var resourceIndices: [String: Int] = [:]

  init(api: BookOrbitAPI, book: BookDetail) {
    self.api = api
    self.book = book
  }

  var bytesLabel: String {
    guard let snapshot else { return "No content selected" }
    return
      "\(ByteCountFormatter.string(fromByteCount: snapshot.receivedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: snapshot.knownBytes, countStyle: .file)) known bytes"
  }

  private var availableCoverMedia: [CoverMedium] {
    book.coverMedia.filter { medium in
      (medium == .ebook ? book.covers.ebook : book.covers.audio) != nil
    }
  }

  func load() async {
    do {
      namespace = try await api.storageNamespace()
      snapshot = try await api.offlineStore().snapshot(bookID: book.id)
      if let snapshot {
        selectedFileIDs = Set(snapshot.selectedFileIDs).intersection(Set(book.files.map(\.id)))
        for index in snapshot.resources.indices {
          let resource = snapshot.resources[index]
          let destination = try await api.offlineStore().destination(
            path: resource.path, query: resource.query.map(\.item))
          if let receipt = try await api.offlineStore().receipt(
            path: resource.path, query: resource.query.map(\.item))
          {
            self.snapshot?.resources[index] = receipt
            continue
          }
          let partial = destination.appendingPathExtension("partial")
          if let count = try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            self.snapshot?.resources[index].receivedBytes = Int64(count)
          }
        }
        status =
          snapshot.state == "ready"
          ? "Verified ready for offline reading"
          : "Download \(snapshot.state). Resume to verify all selected content."
      }
    } catch { self.error = error.localizedDescription }
  }

  func toggle(_ file: BookDetailFile) {
    guard !isBusy else { return }
    if selectedFileIDs.contains(file.id) {
      selectedFileIDs.remove(file.id)
    } else {
      selectedFileIDs.insert(file.id)
    }
  }

  func start() {
    guard !isBusy, !selectedFileIDs.isEmpty else { return }
    isBusy = true
    pauseRequested = false
    error = nil
    task = Task { await run() }
  }

  func pause() {
    guard isBusy else { return }
    pauseRequested = true
    task?.cancel()
  }

  func requestRemoval() {
    guard !isBusy, snapshot != nil else { return }
    confirmsRemoval = true
  }

  func removeDownload() {
    guard !isBusy, snapshot != nil, let namespace else { return }
    isBusy = true
    error = nil
    task = Task {
      defer {
        isBusy = false
        task = nil
      }
      do {
        try await api.removeOfflineBook(bookID: book.id, namespace: namespace)
        snapshot = nil
        selectedFileIDs = []
        status =
          "Downloaded content removed from this iPad. Your server book and saved reading work are retained."
      } catch {
        self.error = error.localizedDescription
      }
    }
  }

  private func run() async {
    var transferStore: OfflineResourceStore?
    defer {
      isBusy = false
      task = nil
    }
    do {
      let store = try await api.offlineStore()
      try await store.beginBookTransfer(bookID: book.id)
      transferStore = store
      if snapshot == nil || Set(snapshot!.selectedFileIDs) != selectedFileIDs
        || snapshot?.book.files != book.files || snapshot?.state == "recovery"
      {
        snapshot = OfflineBookSnapshot(book: book, selectedFileIDs: selectedFileIDs.sorted())
      }
      snapshot?.book = book
      snapshot?.resources.removeAll { resource in
        guard resource.path == "books/\(book.id)/cover",
          let value = resource.query.first(where: { $0.name == "medium" })?.value,
          let medium = CoverMedium(rawValue: value)
        else { return false }
        return (medium == .ebook ? book.covers.ebook : book.covers.audio) == nil
      }
      resourceIndices = Dictionary(
        uniqueKeysWithValues: snapshot!.resources.enumerated().map { ($0.element.id, $0.offset) })
      snapshot?.state = "preparing"
      status = "Preparing metadata, owned notes, bookmarks, and complete selected content"
      try await persist()
      try await prepare()
      snapshot?.state = "downloading"
      try await persist()
      guard let count = snapshot?.resources.count else { throw ConnectionError.invalidResponse }
      for index in 0..<count {
        try Task.checkCancellation()
        guard let resource = snapshot?.resources[index] else {
          throw ConnectionError.invalidResponse
        }
        if let retained = try await store.receipt(
          path: resource.path, query: resource.query.map(\.item))
        {
          snapshot?.resources[index] = retained
          continue
        }
        status = "Downloading resource \(index + 1) of \(count)"
        let destination = await store.destination(
          path: resource.path, query: resource.query.map(\.item))
        let result = try await api.downloadOfflineResource(resource, destination: destination) {
          [weak self] progress in
          self?.snapshot?.resources[index].receivedBytes = progress.received
          self?.snapshot?.resources[index].expectedBytes = progress.total
        }
        snapshot?.resources[index] = result
      }
      try await persist()
      for file in book.files
      where selectedFileIDs.contains(file.id) && file.format?.lowercased() == "pdf" {
        guard let url = try await store.verifiedURL(path: "books/files/\(file.id)/serve"),
          let document = PDFDocument(url: url)
        else { throw ConnectionError.invalidResponse }
        if document.isLocked { continue }
        guard (1...100_000).contains(document.pageCount) else {
          throw ConnectionError.invalidResponse
        }
        var page = 0
        while page < document.pageCount {
          try Task.checkCancellation()
          status = "Saving PDF page anchors \(page + 1) of \(document.pageCount)"
          let query = [
            URLQueryItem(name: "bookId", value: String(book.id)),
            .init(name: "pageStart", value: String(page)), .init(name: "limit", value: "100"),
          ]
          let batch: NativePdfPageSourceBatch = try await cache(
            "annotations/native/files/\(file.id)/source", query: query)
          if let next = batch.nextPage {
            guard next >= 0, next <= 100_000, Double(next).rounded() == Double(next) else {
              throw ConnectionError.invalidResponse
            }
          }
          let nextPage = batch.nextPage.map { Int($0) }
          let sourceID = OfflineResourceStore.key(path: "books/files/\(file.id)/serve")
          let sourceDigest = snapshot?.resources.first(where: { $0.id == sourceID })?.digest
          guard !batch.pages.isEmpty, batch.pages.count <= 100,
            batch.pages.enumerated().allSatisfy({
              $0.element.page == page + $0.offset
                && $0.element.sourceRevision == batch.sourceRevision
            }),
            batch.sourceRevision == sourceDigest.map({ "sha256:\($0)" }),
            nextPage
              == (page + batch.pages.count < document.pageCount ? page + batch.pages.count : nil)
          else { throw ConnectionError.fileChanged }
          for descriptor in batch.pages {
            let resource = try await store.write(
              descriptor, path: "annotations/native/files/\(file.id)/source",
              query: [
                .init(name: "bookId", value: String(book.id)),
                .init(name: "page", value: String(descriptor.page)),
              ])
            record(resource)
          }
          guard let next = nextPage else { break }
          page = next
        }
      }
      status = "Synchronizing every owned annotation, including unselected files"
      let annotations = try await NativeAnnotationRepository.shared(api: api)
      try await annotations.synchronize(bookID: book.id)
      for file in book.files
      where selectedFileIDs.contains(file.id) && file.format?.lowercased() == "pdf" {
        try await annotations.synchronizeSourceInk(bookID: book.id, fileID: file.id)
      }
      try Task.checkCancellation()
      guard let snapshot else { throw ConnectionError.invalidResponse }
      for resource in snapshot.resources {
        guard
          try await store.verifiedURL(path: resource.path, query: resource.query.map(\.item)) != nil
        else {
          throw OfflineStorageError.corruptResource
        }
      }
      self.snapshot?.state = "ready"
      self.snapshot?.message = nil
      status = "Verified ready for offline reading"
      try await persist()
    } catch {
      snapshot?.state = pauseRequested ? "paused" : "failed"
      snapshot?.message = pauseRequested ? nil : error.localizedDescription
      status =
        pauseRequested
        ? "Paused. Verified resources are retained; an unverified resource restarts when its server has no resume validator."
        : "Download incomplete. Retry to verify all selected content."
      self.error = pauseRequested ? nil : error.localizedDescription
      try? await persist()
    }
    if let transferStore { await transferStore.endBookTransfer(bookID: book.id) }
  }

  private func prepare() async throws {
    let store = try await api.offlineStore()
    record(try await store.write(book, path: "books/\(book.id)"))
    let user: AuthUser = try await cache("auth/me")
    try await addJSON("reader/defaults")
    if user.settings.syncReaderPreferences == true {
      for file in book.files where selectedFileIDs.contains(file.id) {
        try await addJSON("reader/preferences/\(file.id)")
      }
    }
    try await addJSON("fonts")
    try await addJSON("server-fonts")
    try await addJSON("user-preferences/server-fonts")
    for medium in availableCoverMedia {
      add(
        "books/\(book.id)/cover",
        query: [
          .init(name: "medium", value: medium.rawValue), .init(name: "strict", value: "true"),
          .init(name: "t", value: book.coverVersion),
        ])
    }
    for file in book.files {
      let _: FileReadingProgress = try await cache("books/files/\(file.id)/progress")
      if ["pdf", "cbz", "cbr", "cb7"].contains(file.format?.lowercased() ?? "") {
        try await cacheFixedPageBookmarks(file)
      }
    }
    var before: Int?
    repeat {
      var query = [URLQueryItem(name: "limit", value: "40")]
      if let before { query.append(.init(name: "beforeId", value: String(before))) }
      let page: BookmarksPage = try await cache(
        "books/\(book.id)/bookmarks/epub-page", query: query)
      guard page.items.count <= 40, page.nextCursor != before || page.nextCursor == nil else {
        throw ConnectionError.invalidResponse
      }
      before = page.nextCursor
    } while before != nil
    var audiobook: AudiobookManifest?
    if book.files.contains(where: {
      AudioStreamFormat.mimeTypes[$0.format?.lowercased() ?? ""] != nil
    }) {
      audiobook = try await cache("audiobooks/\(book.id)/manifest")
      let _: AudiobookPlaybackState? = try await cache("audiobooks/\(book.id)/playback-state")
      var after: String?
      repeat {
        var query = [URLQueryItem(name: "limit", value: "40")]
        if let after { query.append(.init(name: "afterId", value: after)) }
        let page: AudiobookBookmarksPage = try await cache(
          "audiobooks/\(book.id)/bookmarks/page", query: query)
        guard page.items.count <= 40, page.nextCursor != after || page.nextCursor == nil else {
          throw ConnectionError.invalidResponse
        }
        after = page.nextCursor
      } while after != nil
    }
    for file in book.files where selectedFileIDs.contains(file.id) {
      try Task.checkCancellation()
      let format = file.format?.lowercased() ?? ""
      let session = try await api.authenticatedSessionGeneration()
      let previous = try await store.sourceResource(fileID: file.id)
      let revision = try await api.sourceRevision(fileID: file.id, session: session)
      if let previousRevision = previous?.digest, previousRevision != revision {
        snapshot?.resources.removeAll { resource in
          let editionQuery = resource.query.contains {
            $0.name == "fileId" && $0.value == String(file.id)
          }
          return resource.fileID == file.id || resource.path == "books/files/\(file.id)/serve"
            || resource.path == previous?.path
            || (resource.path.hasPrefix("epub/\(book.id)/") && editionQuery)
            || resource.path.hasPrefix("cbz/files/\(file.id)/pages")
            || resource.path == "annotations/native/files/\(file.id)/source"
        }
        resourceIndices = Dictionary(
          uniqueKeysWithValues: snapshot!.resources.enumerated().map { ($0.element.id, $0.offset) })
      }
      if NativeEbookVocabulary.mimeTypes[format] != nil {
        let preferences = EPUBPreferencesModel(api: api, fileID: file.id)
        await preferences.load()
        guard preferences.hasLoaded else { throw ConnectionError.invalidResponse }
        if let family = try preferences.fonts.resolve(preferences.value.settings.fontFamily) {
          let fonts = try family.renderingFiles(
            weight: preferences.value.settings.fontWeight,
            style: preferences.value.settings.fontStyle)
          for font in fonts {
            add(
              "\(family.scope == "server" ? "server-fonts" : "fonts")/\(font.id)/file",
              size: Double(font.fileSize))
          }
        }
        preferences.close()
      }
      if let asset = audiobook?.assets.first(where: { $0.fileId == file.id }) {
        add(
          "audiobooks/\(book.id)/assets/\(asset.assetId)/content", size: asset.sizeBytes,
          fileID: file.id)
        continue
      }
      add("books/files/\(file.id)/serve", size: file.sizeBytes, fileID: file.id)
      if format == "epub" {
        let query = [URLQueryItem(name: "fileId", value: String(file.id))]
        let info: EpubBookInfo = try await cache(
          "epub/\(book.id)/info", query: query, limit: 8 * 1024 * 1024)
        guard info.manifest.count <= 65_536, info.spine.count <= 4096,
          info.manifest.allSatisfy({
            EPUBPublicationResources.validPath($0.href) && (0...(8 * 1024 * 1024)).contains($0.size)
          })
        else { throw ConnectionError.responseTooLarge }
        for item in info.manifest {
          add("epub/\(book.id)/file/\(item.href)", query: query, size: Double(item.size))
        }
        for path in Set(
          (info.optionalFiles ?? []) + ["META-INF/container.xml", info.containerPath])
        {
          guard EPUBPublicationResources.validPath(path) else {
            throw ConnectionError.invalidResponse
          }
          add("epub/\(book.id)/file/\(path)", query: query)
        }
        if file.mediaOverlay?.available == true {
          for section in info.spine.indices {
            var cursor = 0
            repeat {
              let query = [
                URLQueryItem(name: "fileId", value: String(file.id)),
                .init(name: "sectionIndex", value: String(section)),
                .init(name: "cursor", value: String(cursor)),
                .init(name: "limit", value: "64"),
              ]
              let page: EpubMediaOverlayClipsPage = try await cache(
                "epub/\(book.id)/media-overlay/clips", query: query)
              guard page.items.count <= 64, page.nextCursor.map({ $0 > cursor }) ?? true else {
                throw ConnectionError.invalidResponse
              }
              guard let next = page.nextCursor else { break }
              cursor = next
            } while true
          }
        }
      } else if ["cbz", "cbr", "cb7"].contains(format) {
        let count: ComicPageCountResponse = try await cache("cbz/files/\(file.id)/pages")
        guard (1...100_000).contains(count.pageCount) else { throw ConnectionError.invalidResponse }
        for page in 0..<count.pageCount { add("cbz/files/\(file.id)/pages/\(page)") }
      }
    }
    guard let snapshot, snapshot.resources.count <= 100_000,
      snapshot.knownBytes <= OfflineResourceStore.byteLimit
    else { throw OfflineStorageError.storageLimit }
    try await persist()
  }

  private func cacheFixedPageBookmarks(_ file: BookDetailFile) async throws {
    var cursor: Int?
    repeat {
      var query = [
        URLQueryItem(name: "fileId", value: String(file.id)), .init(name: "limit", value: "40"),
      ]
      if let cursor { query.append(.init(name: "beforeId", value: String(cursor))) }
      let page: BookmarksPage = try await cache("books/\(book.id)/bookmarks/page", query: query)
      guard page.items.count <= 40, page.nextCursor != cursor || page.nextCursor == nil else {
        throw ConnectionError.invalidResponse
      }
      cursor = page.nextCursor
    } while cursor != nil
  }

  private func cache<T: Codable & Sendable>(
    _ path: String, query: [URLQueryItem] = [], limit: Int = 1024 * 1024
  ) async throws -> T {
    try Task.checkCancellation()
    let value: T = try await api.boundedJSON(path, query: query, byteLimit: limit)
    let resource = try await api.offlineStore().write(value, path: path, query: query)
    record(resource)
    return value
  }

  private func addJSON(_ path: String, query: [URLQueryItem] = []) async throws {
    try Task.checkCancellation()
    let resource = OfflineResource(
      path: path, query: query.map { .init(name: $0.name, value: $0.value) })
    let store = try await api.offlineStore()
    let destination = await store.destination(path: path, query: query)
    let completed = try await api.downloadOfflineResource(resource, destination: destination) { _ in
    }
    record(completed)
  }

  private func record(_ resource: OfflineResource) {
    if let index = resourceIndices[resource.id] {
      snapshot?.resources[index] = resource
    } else {
      resourceIndices[resource.id] = snapshot?.resources.count ?? 0
      snapshot?.resources.append(resource)
    }
  }

  private func add(
    _ path: String, query: [URLQueryItem] = [], size: Double? = nil, fileID: Int? = nil
  ) {
    let resource = OfflineResource(
      path: path, query: query.map { .init(name: $0.name, value: $0.value) },
      expectedBytes: size.flatMap {
        $0.isFinite && $0 >= 0 && $0 < Double(Int64.max) ? Int64($0) : nil
      }, bookID: book.id, fileID: fileID)
    if resourceIndices[resource.id] == nil { record(resource) }
  }

  private func persist() async throws {
    guard var snapshot else { return }
    snapshot.updatedAt = Date()
    self.snapshot = snapshot
    try await api.offlineStore().save(snapshot)
  }
}
