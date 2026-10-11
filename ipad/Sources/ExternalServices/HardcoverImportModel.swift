import Foundation
import Observation

@MainActor @Observable
final class HardcoverImportModel {
  let api: BookOrbitAPI
  private(set) var preview: HardcoverImportPreview?
  private(set) var result: HardcoverImportApplyResult?
  private(set) var busy = false
  private(set) var error: String?
  private(set) var afterID = 0
  private(set) var visited = 0
  var selectedIDs = Set<Int>()
  var importProgress = false

  init(api: BookOrbitAPI) { self.api = api }

  func load(afterID cursor: Int = 0) async {
    guard !busy else { return }
    busy = true
    error = nil
    defer { busy = false }
    do {
      let page = try await api.previewHardcoverImport(afterID: cursor)
      try Task.checkCancellation()
      if cursor == 0 {
        visited = 0
      } else if cursor != afterID {
        visited += preview?.rows.count ?? 0
      }
      afterID = cursor
      preview = page
      result = nil
      selectedIDs = Set(page.rows.filter { $0.outcome == "will_update" }.map(\.hardcoverUserBookId))
    } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
  }

  func apply() async {
    guard !busy, !selectedIDs.isEmpty, result == nil else { return }
    busy = true
    error = nil
    defer { busy = false }
    do {
      let confirmed = try await api.applyHardcoverImport(
        afterID: afterID, selectedIDs: selectedIDs.sorted(), progress: importProgress)
      try Task.checkCancellation()
      result = confirmed
      selectedIDs = []
    } catch {
      self.error =
        "The result could not be confirmed. Refresh this page before retrying. \(error.localizedDescription)"
      selectedIDs = []
    }
  }

  func nextPage() async {
    guard let cursor = preview?.nextCursor else { return }
    await load(afterID: cursor)
  }

  func refresh() async { await load(afterID: afterID) }

  func toggle(_ row: HardcoverImportPreviewRow) {
    guard !busy, result == nil, row.outcome == "will_update" || row.outcome == "needs_review" else {
      return
    }
    if selectedIDs.contains(row.hardcoverUserBookId) {
      selectedIDs.remove(row.hardcoverUserBookId)
    } else {
      selectedIDs.insert(row.hardcoverUserBookId)
    }
  }
}
