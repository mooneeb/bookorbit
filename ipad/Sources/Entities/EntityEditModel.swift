import Foundation
import Observation

enum EntityEditOperation {
  case rename(String)
  case merge(BrowseEntityItem)
  case remove(String)
  case split([String])
}

@MainActor @Observable
final class EntityEditModel {
  let api: BookOrbitAPI
  let kind: EntityKind
  let item: BrowseEntityItem
  private(set) var info: EntityInfo?
  private(set) var busy = false
  private(set) var completed = false
  var name: String
  var splitNames = ""
  var writeFiles = false
  var error: String?
  var outcome: String?
  var preview: String?
  private(set) var operation: EntityEditOperation?

  init(api: BookOrbitAPI, kind: EntityKind, item: BrowseEntityItem) {
    self.api = api
    self.kind = kind
    self.item = item
    name = item.name
  }

  func load() async {
    busy = true
    error = nil
    defer { busy = false }
    do { info = try await api.entityInfo(kind: kind, id: item.id) } catch {
      self.error = error.localizedDescription
    }
  }

  func prepare(_ next: EntityEditOperation) async {
    await load()
    guard let info, error == nil else { return }
    operation = next
    let impact =
      "\(info.bookCount) books currently use \(info.name). Books, files, notes and reading progress are retained."
    switch next {
    case .rename(let name):
      guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        error = "Enter a name."
        operation = nil
        return
      }
      preview =
        "Rename to \(name). \(impact) If this name already exists, its relationships will be merged."
    case .merge(let target):
      preview =
        "Replace \(info.name) with \(target.name). \(impact) The source entity will be removed. Existing target relationships are kept."
    case .remove(let mode):
      preview =
        "\(mode == "soft" ? "Detach" : "Remove") \(info.name) from its books. \(impact) \(mode == "soft" ? "The unused entity is retained." : "The entity is removed when no longer used.")"
    case .split(let names):
      guard names.count >= 2, names.count <= 100 else {
        error = "Enter between 2 and 100 names, one per line."
        operation = nil
        return
      }
      preview =
        "Replace \(info.name) with \(names.joined(separator: ", ")). \(impact) Each book receives all the replacement entities."
    }
  }

  func cancelPreview() {
    operation = nil
    preview = nil
  }

  func apply() async {
    guard let operation, !busy else { return }
    busy = true
    error = nil
    preview = nil
    defer {
      busy = false
      self.operation = nil
    }
    do {
      let session = try await api.authenticatedSessionGeneration()
      let path = "entity-manager/\(kind.rawValue)"
      let count: Int
      var fileOutcome = writeFiles ? " File metadata writes were queued on the server." : ""
      switch operation {
      case .rename(let name):
        let request = EntityRenameRequest(
          entityId: item.id.entityNumber, currentValue: item.id.entityValue,
          newName: name, writeFiles: writeFiles)
        let result: RenameResult = try await api.boundedJSON(
          "\(path)/rename", method: "POST", body: JSONEncoder().encode(request), session: session)
        count = result.affectedBookCount
      case .merge(let target):
        let request = EntityMergeRequest(
          targetEntityId: target.id.entityNumber, targetValue: target.id.entityValue,
          sourceEntityIds: item.id.entityNumber.map { [$0] },
          sourceValues: item.id.entityValue.map { [$0] }, writeFiles: writeFiles)
        let result: MergeResult = try await api.boundedJSON(
          "\(path)/merge", method: "POST", body: JSONEncoder().encode(request), session: session)
        count = result.affectedBookCount
        if let recovery = result.fileWriteRecovery {
          fileOutcome =
            recovery.pendingBookCount > 0
            ? " \(recovery.pendingBookCount) file updates remain. Use Retry file updates in entity management to continue."
            : " File metadata updates completed."
        }
      case .remove(let mode):
        let request = EntityDeleteRequest(
          entityId: item.id.entityNumber, value: item.id.entityValue,
          mode: mode, writeFiles: writeFiles)
        let result: DeleteResult = try await api.boundedJSON(
          "\(path)/delete", method: "POST", body: JSONEncoder().encode(request), session: session)
        count = result.affectedBookCount
      case .split(let names):
        guard let id = item.id.entityNumber else { throw ConnectionError.invalidResponse }
        let request = EntitySplitRequest(entityId: id, newNames: names, writeFiles: writeFiles)
        let result: SplitResult = try await api.boundedJSON(
          "\(path)/split", method: "POST", body: JSONEncoder().encode(request), session: session)
        count = result.affectedBookCount
      }
      outcome =
        "Updated \(count) books.\(fileOutcome)"
      completed = true
    } catch {
      self.error =
        "\(error.localizedDescription) Refresh the directory before retrying to check whether the operation completed."
    }
  }
}
