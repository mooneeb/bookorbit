import Foundation

extension BookOrbitAPI {
  func bulkMetadataPreview(_ request: SelectedBulkMetadataRequest, session: UUID) async throws
    -> BulkMetadataPreview
  {
    try await boundedJSON(
      "books/bulk-edit-metadata/preview", method: "POST", body: JSONEncoder().encode(request),
      session: session)
  }

  func applyBulkMetadata(_ request: SelectedBulkMetadataRequest, session: UUID) async throws
    -> BulkEditMetadataResult
  {
    try await boundedJSON(
      "books/bulk-edit-metadata", method: "POST", body: JSONEncoder().encode(request),
      session: session)
  }

  func bulkBookExportPreview(_ request: SelectedBookExportRequest, session: UUID) async throws
    -> BookExportPreview
  {
    try await boundedJSON(
      "books/export/preflight", method: "POST", body: JSONEncoder().encode(request),
      session: session)
  }

  func bulkMetadataExportPreview(_ request: SelectedMetadataExportRequest, session: UUID)
    async throws -> MetadataExportPreflight
  {
    try await boundedJSON(
      "books/metadata-export/preflight", method: "POST", body: JSONEncoder().encode(request),
      session: session)
  }
}
