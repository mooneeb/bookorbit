import Foundation

extension BookOrbitAPI {
  func previewHardcoverImport(afterID: Int) async throws -> HardcoverImportPreview {
    try await boundedJSON(
      "hardcover/import/preview", method: "POST",
      body: JSONEncoder().encode(PreviewHardcoverImportPayload(afterId: afterID)))
  }

  func applyHardcoverImport(afterID: Int, selectedIDs: [Int], progress: Bool) async throws
    -> HardcoverImportApplyResult
  {
    try await boundedJSON(
      "hardcover/import/apply", method: "POST",
      body: JSONEncoder().encode(
        ApplyHardcoverImportPayload(
          hardcoverUserBookIds: selectedIDs, importProgress: progress, afterId: afterID)))
  }
}
