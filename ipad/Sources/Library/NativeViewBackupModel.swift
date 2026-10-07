import Foundation
import Observation

struct NativeViewBackupCounts: Sendable {
  let presets: Int
  let savedViews: Int

  var isEmpty: Bool { presets == 0 && savedViews == 0 }
  var description: String {
    "\(presets) \(presets == 1 ? "preset" : "presets") and "
      + "\(savedViews) \(savedViews == 1 ? "saved view" : "saved views")"
  }
}

@MainActor @Observable
final class NativeViewBackupModel {
  let location: BookLocation
  private(set) var isImporting = false
  private(set) var status: String?
  private(set) var error: String?
  private let presets: TablePresetModel
  private let savedViews: SavedViewModel
  private var importTask: Task<Void, Never>?
  private var operationID = UUID()

  init(presets: TablePresetModel, savedViews: SavedViewModel, location: BookLocation) {
    self.presets = presets
    self.savedViews = savedViews
    self.location = location
  }

  var counts: NativeViewBackupCounts {
    NativeViewBackupCounts(
      presets: presets.customPresets(at: location.storageKey).count,
      savedViews: savedViews.views(at: location.storageKey).count)
  }

  var filename: String {
    switch location {
    case .all: "library-table-backup-shared.json"
    case .library(let id, _): "library-table-backup-\(id).json"
    case .collection(let id, _): "collection-table-backup-\(id).json"
    case .scope(let id, _, _): "smart-scope-table-backup-\(id).json"
    }
  }

  func prepareExport() throws -> (
    document: NativeViewBackupDocument, counts: NativeViewBackupCounts
  ) {
    resetFeedback()
    let backup = TableViewBackup(
      version: 1, presets: presets.customPresets(at: location.storageKey),
      savedViews: savedViews.exportedViews(at: location.storageKey))
    try validate(backup)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(backup)
    guard data.count <= NativeViewBackupFile.byteLimit else { throw NativeViewBackupError.fileSize }
    return (
      NativeViewBackupDocument(data: data),
      NativeViewBackupCounts(presets: backup.presets.count, savedViews: backup.savedViews.count)
    )
  }

  func exportFinished(_ result: Result<URL, any Error>, counts: NativeViewBackupCounts) {
    switch result {
    case .success: status = "Exported \(counts.description)."
    case .failure(let failure): report(failure, operation: "Export")
    }
  }

  func importerFinished(_ result: Result<[URL], any Error>) {
    switch result {
    case .success(let urls):
      guard urls.count == 1, let url = urls.first else {
        resetFeedback()
        report(NativeViewBackupError.invalidFile, operation: "Import")
        return
      }
      importFile(url)
    case .failure(let failure):
      resetFeedback()
      report(failure, operation: "Import")
    }
  }

  func reportExportFailure(_ failure: any Error) { report(failure, operation: "Export") }

  func pickerCanceled() {
    resetFeedback()
    status = "Import canceled. Nothing was imported."
  }

  func exportCanceled() {
    resetFeedback()
    status = "Export canceled."
  }

  func cancelImport() {
    guard isImporting else { return }
    operationID = UUID()
    importTask?.cancel()
    importTask = nil
    isImporting = false
    status = "Import canceled. Nothing was imported."
    error = nil
  }

  private func importFile(_ url: URL) {
    guard !isImporting else { return }
    resetFeedback()
    isImporting = true
    let id = UUID()
    operationID = id
    importTask = Task {
      do {
        let backup = try await NativeViewBackupFile.read(from: url)
        try Task.checkCancellation()
        guard operationID == id else { return }
        let imported = try commit(backup)
        status =
          imported.isEmpty
          ? "The backup is empty. No presets or saved views were imported."
          : "Imported \(imported.description)."
      } catch {
        guard operationID == id else { return }
        report(error, operation: "Import")
      }
      guard operationID == id else { return }
      isImporting = false
      importTask = nil
    }
  }

  private func validate(_ backup: TableViewBackup) throws {
    guard backup.version == 1 else { throw NativeViewBackupError.version }
    guard backup.presets.count <= 100, backup.savedViews.count <= 100 else {
      throw NativeViewBackupError.entries
    }
    for preset in backup.presets {
      guard preset.isBuiltIn != true else { throw NativeViewBackupError.builtIn }
      try NativeViewBackupValidation.validate(layout: preset.layout)
      try TablePresetModel.validate(preset)
    }
    for view in backup.savedViews { try SavedViewModel.validate(view) }
  }

  private func commit(_ backup: TableViewBackup) throws -> NativeViewBackupCounts {
    try validate(backup)
    let previousPresets = presets.items
    let nextPresets = try presets.prepareImport(backup.presets, at: location.storageKey)
    let nextViews = try savedViews.prepareImport(backup.savedViews, at: location.storageKey)
    let imported = NativeViewBackupCounts(
      presets: nextPresets.count - previousPresets.count,
      savedViews: nextViews.count - savedViews.items.count)
    guard imported.presets == backup.presets.count, imported.savedViews == backup.savedViews.count
    else { throw NativeViewBackupError.invalidFile }
    guard !imported.isEmpty else { return imported }
    try presets.persistPrepared(nextPresets)
    do { try savedViews.persistPrepared(nextViews) } catch {
      do { try presets.persistPrepared(previousPresets) } catch {
        throw NativeViewBackupError.restore
      }
      throw error
    }
    return imported
  }

  private func resetFeedback() {
    status = nil
    error = nil
  }

  private func report(_ failure: any Error, operation: String) {
    let cocoa = failure as NSError
    if failure is CancellationError
      || (cocoa.domain == NSCocoaErrorDomain
        && cocoa.code == CocoaError.Code.userCancelled.rawValue)
    {
      status = "\(operation) canceled."
      error = nil
    } else {
      status = nil
      let suffix =
        operation == "Import" && (failure as? NativeViewBackupError) != .restore
        ? " Nothing was imported." : ""
      error = failure.localizedDescription + suffix
    }
  }
}
