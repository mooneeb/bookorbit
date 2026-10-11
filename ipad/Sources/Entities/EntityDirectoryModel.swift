import Foundation
import Observation

@MainActor @Observable
final class EntityDirectoryModel {
  let api: BookOrbitAPI
  var kind: EntityKind
  var search = ""
  var sort = "name"
  var descending = false
  var emptyOnly = false
  private(set) var items: [BrowseEntityItem] = []
  private(set) var total = 0
  private(set) var page = 1
  private(set) var busy = false
  var error: String?
  var selection: [BrowseEntityItem] = []
  var bulkOutcome: String?
  private(set) var pendingFileOperations: [String] = []
  private(set) var retryingFileUpdates = false
  var fileUpdateMessage: String?

  func clearFileUpdateRecovery() {
    pendingFileOperations = []
    fileUpdateMessage = nil
  }

  func loadPendingFileUpdates() async {
    let requestedKind = kind
    do {
      let session = try await api.authenticatedSessionGeneration()
      let receipts: [[String: String]] = try await api.boundedJSON(
        "entity-manager/\(requestedKind.rawValue)/file-updates", session: session)
      guard kind == requestedKind, !Task.isCancelled else { return }
      pendingFileOperations = receipts.compactMap { $0["operationId"] }
    } catch {
      guard kind == requestedKind else { return }
      fileUpdateMessage = error.localizedDescription
    }
  }

  func retryFileUpdates() async {
    guard let operationID = pendingFileOperations.first, !retryingFileUpdates else { return }
    let requestedKind = kind
    retryingFileUpdates = true
    defer { retryingFileUpdates = false }
    do {
      let session = try await api.authenticatedSessionGeneration()
      let result: EntityFileWriteRecovery = try await api.boundedJSON(
        "entity-manager/\(requestedKind.rawValue)/file-updates/\(operationID)/retry",
        method: "POST", session: session)
      guard kind == requestedKind, !Task.isCancelled else { return }
      fileUpdateMessage =
        result.pendingBookCount > 0
        ? "\(result.pendingBookCount) file updates remain. Retry to continue. Check write settings or access for skipped files."
        : "File updates completed."
      await loadPendingFileUpdates()
    } catch {
      guard kind == requestedKind else { return }
      fileUpdateMessage = error.localizedDescription
    }
  }

  private var generation = UUID()

  init(api: BookOrbitAPI, kind: EntityKind = .author) {
    self.api = api
    self.kind = kind
  }

  func toggleSelection(_ item: BrowseEntityItem) {
    if let index = selection.firstIndex(where: { $0.id == item.id }) {
      selection.remove(at: index)
    } else if selection.count < 100 {
      selection.append(item)
    }
  }

  func bulkDelete() async {
    guard !selection.isEmpty, selection.count <= 100, !busy else { return }
    busy = true
    error = nil
    bulkOutcome = nil
    do {
      let session = try await api.authenticatedSessionGeneration()
      let request = EntityBulkDeleteRequest(
        entityIds: kind.isInline ? nil : selection.compactMap { $0.id.entityNumber },
        values: kind.isInline ? selection.compactMap { $0.id.entityValue } : nil,
        mode: kind.isInline ? "inline" : "hard", writeFiles: false)
      let result: BulkDeleteResult = try await api.boundedJSON(
        "entity-manager/\(kind.rawValue)/bulk-delete", method: "POST",
        body: JSONEncoder().encode(request), session: session)
      bulkOutcome = "Removed \(result.results.count) entities. \(result.errors.count) failed."
      if !result.errors.isEmpty {
        error = result.errors.map { "\($0.entityId.entityPath): \($0.error)" }.joined(
          separator: "\n")
      }
      let failed = Set(result.errors.map(\.entityId))
      selection.removeAll { !failed.contains($0.id) }
    } catch {
      self.error =
        "\(error.localizedDescription) Refresh before retrying to review the current entities."
    }
    busy = false
    let retainedError = error
    await load(page: page)
    error = retainedError ?? error
  }

  func bulkMerge(target: BrowseEntityItem) async {
    let sources = selection.filter { $0.id != target.id }
    guard !sources.isEmpty, sources.count <= 100, !busy else { return }
    busy = true
    error = nil
    bulkOutcome = nil
    do {
      let session = try await api.authenticatedSessionGeneration()
      let request = EntityMergeRequest(
        targetEntityId: target.id.entityNumber, targetValue: target.id.entityValue,
        sourceEntityIds: kind.isInline ? nil : sources.compactMap { $0.id.entityNumber },
        sourceValues: kind.isInline ? sources.compactMap { $0.id.entityValue } : nil,
        writeFiles: false)
      let result: MergeResult = try await api.boundedJSON(
        "entity-manager/\(kind.rawValue)/merge", method: "POST",
        body: JSONEncoder().encode(request), session: session)
      bulkOutcome =
        "Merged \(result.mergedIds.count) entities into \(target.name). Updated \(result.affectedBookCount) books."
      selection = []
    } catch {
      self.error =
        "\(error.localizedDescription) Refresh before retrying to review the current entities."
    }
    busy = false
    let retainedError = error
    await load(page: page)
    error = retainedError ?? error
  }

  func load(page: Int = 1) async {
    let request = UUID()
    generation = request
    busy = true
    error = nil
    defer { if generation == request { busy = false } }
    do {
      let result = try await api.entityPage(
        kind: kind, search: search, page: page, sort: sort,
        descending: descending, emptyOnly: emptyOnly)
      guard generation == request, !Task.isCancelled else { return }
      items = result.items
      total = result.total
      self.page = page
      await loadPendingFileUpdates()
    } catch {
      guard generation == request, !Task.isCancelled else { return }
      self.error = error.localizedDescription
    }
  }
}
