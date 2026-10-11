import Foundation
import Observation

@MainActor @Observable
final class AcquisitionModel {
  let api: BookOrbitAPI
  let user: AuthUser
  var capabilities: UploadCapabilitiesResponse?
  var files: [BookDockFile] = []
  var selected: BookDockFile?
  var title = ""
  var authors = ""
  var libraryID: Int?
  var folderID: Int?
  var search = ""
  var page = 1
  var total = 0
  var received = 0
  var uploadSize = 0
  var isBusy = false
  var message: String?
  var preview: BookDockFinalizePreviewResult?
  var importJob: BookDockFinalizeJob?
  var pendingFinalize: AcquisitionFinalizeDraft?
  var bookID: Int?
  var pending: AcquisitionUploadDraft?
  private var journal: AcquisitionUploadJournal?
  private var session: UUID?
  private var transfer: Task<Void, Never>?
  private var importWatch: Task<Void, Never>?

  init(api: BookOrbitAPI, user: AuthUser) {
    self.api = api
    self.user = user
  }
  var isUploading: Bool { transfer != nil }
  var isFinalizing: Bool { importWatch != nil }
  var canFinalize: Bool {
    user.hasPermission(.libraryUpload) && user.hasPermission(.bookDockAccess)
  }
  var canConfirm: Bool {
    guard pendingFinalize == nil, preview?.ready == 1, let selected else { return false }
    return selected.selectedMetadata?.title == title
      && selected.selectedMetadata?.authors == authorNames
      && selected.targetLibraryId == libraryID && selected.targetFolderId == folderID
  }
  private var authorNames: [String] {
    authors.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter
    { !$0.isEmpty }
  }
  var progress: Double { uploadSize > 0 ? Double(received) / Double(uploadSize) : 0 }

  func prepare() async {
    await perform {
      self.session = try await self.api.authenticatedSessionGeneration()
      guard let session = self.session else { throw ConnectionError.expiredSession }
      self.journal = try AcquisitionUploadJournal(namespace: await self.api.storageNamespace())
      self.pending = try await self.journal?.load()
      self.pendingFinalize = try await self.journal?.loadFinalize()
      self.capabilities = try await self.api.acquisitionCapabilities(session: session)
      try await self.refresh()
      if let pending = self.pending {
        self.uploadSize = pending.sizeBytes
        self.message = String(
          localized: "An upload is saved on this iPad. Resume to reconcile its server status.")
      }
    }
    if pendingFinalize != nil { resumeImport() }
  }
  func reload(page: Int = 1) async {
    await perform {
      self.page = max(1, page)
      try await self.refresh()
    }
  }
  func select(_ file: BookDockFile) {
    guard !isBusy else { return }
    selected = file
    title =
      file.selectedMetadata?.title ?? file.fetchedMetadata?.title ?? file.embeddedMetadata?.title
      ?? file.fileName
    authors =
      (file.selectedMetadata?.authors ?? file.fetchedMetadata?.authors
      ?? file.embeddedMetadata?.authors)?.joined(separator: ", ") ?? ""
    libraryID = file.targetLibraryId
    folderID = file.targetFolderId
    preview = nil
    message = nil
  }
  func chooseLibrary(_ id: Int) {
    libraryID = id
    folderID = nil
    preview = nil
  }
  func chooseFolder(_ id: Int) {
    folderID = id
    preview = nil
  }
  func stage(_ url: URL) async {
    await perform {
      guard let journal = self.journal, let capabilities = self.capabilities else {
        throw ConnectionError.invalidResponse
      }
      self.pending = try await journal.stage(url, maximumBytes: capabilities.maxFileSizeBytes)
    }
    if pending != nil { resume() }
  }
  func resume() {
    guard transfer == nil, !isBusy, pending != nil else { return }
    transfer = Task { [weak self] in
      guard let self else { return }
      await self.perform { try await self.transferPending() }
      self.transfer = nil
    }
  }
  func pause() {
    transfer?.cancel()
    message = String(localized: "Upload paused. Resume checks the server's confirmed offset.")
  }
  func discard() async {
    await perform {
      guard let session = self.session, let journal = self.journal else {
        throw ConnectionError.expiredSession
      }
      if let id = self.pending?.sessionID {
        let _: UploadSessionResponse = try await self.api.boundedJSON(
          "uploads/\(id)", method: "DELETE", session: session, expectedStatus: 200)
      }
      try await journal.clear()
      self.pending = nil
      self.received = 0
      self.uploadSize = 0
    }
  }
  func review() async {
    await perform {
      guard let selected = self.selected, let session = self.session,
        let libraryID = self.libraryID,
        let folderID = self.folderID, self.canFinalize
      else { throw ConnectionError.denied }
      var metadata = selected.selectedMetadata ?? BookDockMetadata()
      metadata.title = self.title
      metadata.authors = self.authors.split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
      }.filter { !$0.isEmpty }
      let request = UpdateBookDockFileRequest(
        expectedUpdatedAt: selected.updatedAt, selectedMetadata: metadata,
        targetLibraryId: libraryID, targetFolderId: folderID)
      let updated: BookDockFile = try await self.api.boundedJSON(
        "book-dock/files/\(selected.id)", method: "PATCH",
        body: JSONEncoder().encode(request), session: session, expectedStatus: 200)
      self.selected = updated
      self.title = updated.selectedMetadata?.title ?? self.title
      self.authors = updated.selectedMetadata?.authors?.joined(separator: ", ") ?? self.authors
      let requestBody = try JSONSerialization.data(withJSONObject: ["fileIds": [selected.id]])
      self.preview = try await self.api.boundedJSON(
        "book-dock/finalize/preview", method: "POST", body: requestBody, session: session,
        expectedStatus: 200)
    }
  }
  func finalize() async {
    guard canFinalize, canConfirm, let selected, let journal else { return }
    await perform {
      guard let session = self.session, let libraryID = self.libraryID, let folderID = self.folderID
      else {
        throw ConnectionError.expiredSession
      }
      let current: BookDockFile = try await self.api.boundedJSON(
        "book-dock/files/\(selected.id)", session: session, expectedStatus: 200)
      guard current.updatedAt == selected.updatedAt else {
        self.selected = current
        self.title =
          current.selectedMetadata?.title ?? current.fetchedMetadata?.title ?? current
          .embeddedMetadata?.title ?? current.fileName
        self.authors =
          (current.selectedMetadata?.authors ?? current.fetchedMetadata?.authors
          ?? current.embeddedMetadata?.authors)?.joined(separator: ", ") ?? ""
        self.libraryID = current.targetLibraryId
        self.folderID = current.targetFolderId
        self.preview = nil
        self.message = String(
          localized:
            "This staged book changed. Review its latest metadata and destination before importing."
        )
        return
      }
      let request = BookDockFinalizeJobRequest(
        idempotencyKey: UUID().uuidString, fileIds: [selected.id],
        overrides: [
          BookDockFinalizeOverride(fileId: selected.id, libraryId: libraryID, folderId: folderID)
        ])
      let draft = AcquisitionFinalizeDraft(request: request)
      try await journal.saveFinalize(draft)
      self.pendingFinalize = draft
      self.importJob = nil
      self.preview = nil
    }
    if pendingFinalize != nil { resumeImport() }
  }
  func resumeImport(retryFailed: Bool = false) {
    guard importWatch == nil, !isBusy, pendingFinalize != nil else { return }
    importWatch = Task { [weak self] in
      guard let self else { return }
      await self.perform { try await self.followImport(retryFailed: retryFailed) }
      self.importWatch = nil
    }
  }
  func pauseImport() {
    guard importWatch != nil else { return }
    importWatch?.cancel()
    message = String(
      localized:
        "Status updates paused. The server import continues. Resume to reconcile its result.")
  }
  func dismissImportResult() async {
    guard !isBusy, let importJob, ["completed", "failed"].contains(importJob.state) else { return }
    await perform {
      try await self.journal?.clearFinalize()
      self.pendingFinalize = nil
      self.importJob = nil
    }
  }
  private func followImport(retryFailed: Bool) async throws {
    guard var draft = pendingFinalize, let journal, let session else {
      throw ConnectionError.expiredSession
    }
    var job: BookDockFinalizeJob
    if let id = draft.jobID {
      job = try await api.finalizeJob(id, session: session)
    } else {
      job = try await api.startFinalizeJob(draft.request, session: session)
      draft.jobID = job.id
      try await journal.saveFinalize(draft)
      pendingFinalize = draft
    }
    try validateImport(job, expectedID: draft.jobID)
    if retryFailed, job.state == "failed" {
      job = try await api.retryFinalizeJob(job.id, session: session)
      try validateImport(job, expectedID: draft.jobID)
    }
    importJob = job
    while ["queued", "running"].contains(job.state) {
      try await Task.sleep(for: .seconds(1))
      try Task.checkCancellation()
      job = try await api.finalizeJob(job.id, session: session)
      try validateImport(job, expectedID: draft.jobID)
      importJob = job
    }
    bookID =
      job.results.first(where: { $0.success })?.bookId
      ?? job.results.first?.existingBookId
    message =
      job.error ?? job.results.first?.message
      ?? (job.state == "completed"
        ? String(localized: "Import completed. Open the book to read.")
        : String(localized: "Import failed. Review the result and retry failed work."))
    if bookID != nil {
      selected = nil
      if let id = pending?.bookDockFileID,
        job.results.contains(where: { $0.fileId == id && $0.success })
      {
        try await journal.clear()
        pending = nil
      }
    }
    try await refresh()
  }
  private func validateImport(_ job: BookDockFinalizeJob, expectedID: Int?) throws {
    guard job.id > 0, expectedID == nil || expectedID == job.id,
      ["queued", "running", "completed", "failed"].contains(job.state),
      job.total >= 0, job.processed >= 0, job.processed <= job.total,
      job.succeeded >= 0, job.failed >= 0, job.succeeded + job.failed <= job.processed,
      job.results.count <= 100
    else { throw ConnectionError.invalidResponse }
  }
  private func transferPending() async throws {
    guard var draft = pending, let journal, let session else {
      throw ConnectionError.expiredSession
    }
    uploadSize = draft.sizeBytes
    var upload: UploadSessionResponse
    if let id = draft.sessionID {
      upload = try await api.uploadSession(id, session: session)
    } else {
      let body = CreateUploadSessionRequest(
        filename: draft.filename, sizeBytes: draft.sizeBytes,
        idempotencyKey: draft.id, target: .book_dock(.init(kind: "book_dock")), contentType: nil,
        sha256: nil)
      upload = try await api.boundedJSON(
        "uploads", method: "POST", body: JSONEncoder().encode(body), session: session,
        expectedStatus: 201)
      draft.sessionID = upload.id
      draft.sessionFilename = upload.filename
      try await journal.save(draft)
      pending = draft
    }
    guard case .book_dock = upload.target else { throw ConnectionError.invalidResponse }
    if draft.sessionFilename == nil {
      draft.sessionFilename = upload.filename
      try await journal.save(draft)
      pending = draft
    }
    guard upload.id == draft.sessionID, upload.sizeBytes == draft.sizeBytes,
      upload.filename == draft.sessionFilename,
      upload.chunkSizeBytes > 0, upload.chunkSizeBytes <= 16 * 1024 * 1024,
      upload.receivedBytes >= 0, upload.receivedBytes <= draft.sizeBytes
    else { throw ConnectionError.invalidResponse }
    received = upload.receivedBytes
    while upload.status == "receiving", received < draft.sizeBytes {
      try Task.checkCancellation()
      let bytes = try await journal.chunk(
        draft, offset: received, size: min(upload.chunkSizeBytes, 4 * 1024 * 1024))
      upload = try await api.uploadChunk(upload.id, offset: received, data: bytes, session: session)
      guard upload.receivedBytes > received, upload.receivedBytes <= draft.sizeBytes else {
        throw ConnectionError.invalidResponse
      }
      received = upload.receivedBytes
    }
    if upload.status == "receiving" {
      upload = try await api.boundedJSON(
        "uploads/\(upload.id)/complete", method: "POST", body: Data("{}".utf8), session: session,
        expectedStatus: 202)
    }
    if let bookID = upload.bookId {
      self.bookID = bookID
      try await journal.clear()
      pending = nil
      message = String(localized: "Recovered the imported book. Open it to read.")
    } else if let id = upload.bookDockFileId {
      draft.bookDockFileID = id
      try await journal.save(draft)
      pending = draft
      let file: BookDockFile = try await api.boundedJSON(
        "book-dock/files/\(id)", session: session, expectedStatus: 200)
      selected = file
      title =
        file.selectedMetadata?.title ?? file.fetchedMetadata?.title ?? file.embeddedMetadata?.title
        ?? file.fileName
      authors =
        (file.selectedMetadata?.authors ?? file.fetchedMetadata?.authors
        ?? file.embeddedMetadata?.authors)?.joined(separator: ", ") ?? ""
      libraryID = file.targetLibraryId
      folderID = file.targetFolderId
      message = String(localized: "Upload received. Review metadata and destination in Book Dock.")
      try await refresh()
    } else {
      message =
        upload.errorMessage
        ?? String(localized: "The server is processing this upload. Resume to check its status.")
    }
  }
  private func refresh() async throws {
    guard let session else { throw ConnectionError.expiredSession }
    let result = try await api.dockPage(page: page, search: search, session: session)
    guard result.items.count <= 20, result.page == page, result.total >= 0 else {
      throw ConnectionError.invalidResponse
    }
    files = result.items
    total = result.total
  }
  private func perform(_ operation: () async throws -> Void) async {
    guard !isBusy else { return }
    isBusy = true
    message = nil
    defer { isBusy = false }
    do { try await operation() } catch {
      if error is CancellationError || (error as? URLError)?.code == .cancelled {
        message =
          isFinalizing
          ? String(
            localized:
              "Status updates paused. The server import continues. Resume to reconcile its result.")
          : String(localized: "Upload paused. Resume checks the server's confirmed offset.")
      } else {
        message = error.localizedDescription
      }
    }
  }
}
