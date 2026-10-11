import Foundation

extension BookOrbitAPI {
  func maintenanceLibraries() async throws -> [Library] {
    try await boundedJSON("libraries")
  }

  func duplicateScan() async throws -> BookDuplicateScan? {
    try await boundedJSON("book-duplicates/scans/active")
  }

  func startDuplicateScan(libraryID: Int?) async throws -> BookDuplicateScan {
    let request = CreateBookDuplicateScanRequest(libraryId: libraryID, similarityPercent: 90)
    return try await boundedJSON(
      "book-duplicates/scans", method: "POST", body: JSONEncoder().encode(request))
  }

  func duplicateScan(id: Int) async throws -> BookDuplicateScan {
    try await boundedJSON("book-duplicates/scans/\(id)")
  }

  func duplicateGroups(scanID: Int, page: Int) async throws -> BookDuplicateGroupsResponse {
    try await boundedJSON(
      "book-duplicates/scans/\(scanID)/groups",
      query: [
        .init(name: "page", value: String(page)), .init(name: "pageSize", value: "20"),
      ])
  }

  func mergePreview(source: Int, target: Int) async throws -> MergeBooksPreview {
    try await boundedJSON(
      "book-duplicates/merge/preview", method: "POST",
      body:
        JSONEncoder().encode(MergeBooksRequest(sourceBookId: source, targetBookId: target)))
  }

  func mergeBooks(_ preview: MergeBooksPreview) async throws -> MergeBooksResult {
    try await boundedJSON(
      "book-duplicates/merge/apply", method: "POST",
      body:
        JSONEncoder().encode(
          MergeBooksRequest(
            sourceBookId: preview.sourceBookId, targetBookId: preview.targetBookId,
            previewToken: preview.previewToken)))
  }

  func renamePreview(libraryID: Int, page: Int) async throws -> BulkRenamePreviewPage {
    try await boundedJSON(
      "libraries/\(libraryID)/bulk-rename/preview",
      query: [
        .init(name: "page", value: String(page)), .init(name: "pageSize", value: "40"),
      ])
  }

  func renameBooks(
    libraryID: Int, bookIDs: [Int], previewToken: String,
    onEvent: @Sendable @escaping (BulkRenameProgressEvent) async throws -> Void
  ) async throws {
    let request = BulkRenameExecuteRequest(previewToken: previewToken, includeBookIds: bookIDs)
    try await eventStream(
      "libraries/\(libraryID)/bulk-rename/execute",
      body: JSONEncoder().encode(request), onEvent: onEvent)
  }

  func missingSummary() async throws -> MissingResourcesSummary {
    try await boundedJSON("maintenance/missing-resources")
  }

  func missingBooks(page: Int) async throws -> MissingBooksPage {
    try await boundedJSON(
      "maintenance/missing-resources/books",
      query: [
        .init(name: "page", value: String(page)), .init(name: "pageSize", value: "40"),
      ])
  }

  func brokenCovers() async throws -> BrokenCoversPage {
    try await boundedJSON(
      "maintenance/missing-resources/broken-covers",
      query: [
        .init(name: "page", value: "1"), .init(name: "pageSize", value: "40"),
      ])
  }

  func orphanedCoverDirs() async throws -> OrphanedCoverDirsPage {
    try await boundedJSON(
      "maintenance/missing-resources/orphaned-covers",
      query: [
        .init(name: "page", value: "1"), .init(name: "pageSize", value: "40"),
      ])
  }

  func coverSweep() async throws -> CoverSweep? {
    try await boundedJSON("maintenance/missing-resources/sweep")
  }

  func startCoverSweep() async throws -> CoverSweep {
    try await boundedJSON("maintenance/missing-resources/sweep", method: "POST")
  }

  func repairPreview(_ request: MissingFileRepairRequest) async throws -> MissingFileRepairPreview {
    try await boundedJSON(
      "maintenance/missing-resources/files/preview", method: "POST",
      body: JSONEncoder().encode(request))
  }

  func repairFile(_ preview: MissingFileRepairPreview) async throws -> MissingFileRepairResult {
    let request = MissingFileRepairRequest(
      bookId: preview.bookId, fileId: preview.fileId,
      replacementPath: preview.replacementPath, previewToken: preview.previewToken)
    return try await boundedJSON(
      "maintenance/missing-resources/files/repair", method: "POST",
      body: JSONEncoder().encode(request))
  }

  func cleanupMissingResources(category: String, bookIDs: [Int]) async throws
    -> MissingResourceCleanupResult
  {
    guard ["broken-covers", "orphaned-covers"].contains(category), !bookIDs.isEmpty,
      bookIDs.count <= 40
    else { throw ConnectionError.invalidResponse }
    return try await boundedJSON(
      "maintenance/missing-resources/\(category)/clean", method: "POST",
      body: JSONEncoder().encode(MissingResourceCleanupRequest(bookIds: bookIDs)))
  }
}
