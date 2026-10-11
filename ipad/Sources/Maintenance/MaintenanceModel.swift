import Foundation
import Observation

@MainActor @Observable
final class MaintenanceModel {
  enum Tool: String, CaseIterable, Identifiable {
    case duplicates = "Duplicates"
    case rename = "Rename"
    case missing = "Missing resources"
    var id: String { rawValue }
  }

  let api: BookOrbitAPI
  let user: AuthUser
  var tool: Tool = .duplicates
  private(set) var libraries: [Library] = []
  var libraryID: Int?
  private(set) var scan: BookDuplicateScan?
  private(set) var groups: [BookDuplicateGroup] = []
  private(set) var renames: [BulkRenamePreviewItem] = []
  private(set) var missing: [MissingBookEntry] = []
  private(set) var summary: MissingResourcesSummary?
  private(set) var page = 1
  private(set) var total = 0
  private(set) var isBusy = false
  private(set) var progress = ""
  var error: String?
  var result: String?
  var selectedBookIDs: Set<Int> = []
  var mergeTargets: [Int: Int] = [:]
  var merge: MergeBooksPreview?
  var repair: MissingFileRepairPreview?
  var repairBookID = ""
  var repairFileID = ""
  private(set) var repairFiles: [BookDetailFile] = []
  var replacementPath = ""
  private(set) var brokenCovers: [BrokenCoverEntry] = []
  private(set) var orphanedCovers: [OrphanedCoverDirEntry] = []
  var cleanupCategory: String?
  private var renamePreviewToken: String?
  private var renameCompleted = false
  private var operation: Task<Void, Never>?

  init(api: BookOrbitAPI, user: AuthUser) {
    self.api = api
    self.user = user
  }

  var canDelete: Bool { user.hasPermission(.libraryDeleteBooks) }
  var canRename: Bool {
    user.hasPermission(.manageLibraries)
      && !user.permissions.contains(Permission.demoRestricted.rawValue)
  }
  var canMerge: Bool {
    canDelete && user.hasPermission(.libraryEditMetadata)
      && !user.permissions.contains(Permission.demoRestricted.rawValue)
  }
  var canRepair: Bool { canDelete && canRename }
  var tools: [Tool] { Tool.allCases.filter { $0 == .rename ? canRename : canDelete } }
  var canNext: Bool { page * (tool == .duplicates ? 20 : 40) < total && !isBusy }

  func load() async {
    do {
      libraries = try await api.maintenanceLibraries().filter { $0.type == "books" }
      if libraryID == nil { libraryID = libraries.first?.id }
      if !tools.contains(tool), let first = tools.first { tool = first }
      await refresh()
    } catch { self.error = error.localizedDescription }
  }

  func refresh() async { await loadPage(1) }
  func next() async { if canNext { await loadPage(page + 1) } }
  func previous() async { if page > 1 { await loadPage(page - 1) } }

  private func loadPage(_ target: Int) async {
    guard !isBusy else { return }
    isBusy = true
    error = nil
    selectedBookIDs = []
    defer { isBusy = false }
    do {
      switch tool {
      case .duplicates:
        let key = scanRecoveryKey
        if scan?.requestedLibraryId != libraryID { scan = nil }
        if let scan {
          self.scan = try await api.duplicateScan(id: scan.id)
        } else if let active = try await api.duplicateScan(), active.requestedLibraryId == libraryID
        {
          scan = active
          UserDefaults.standard.set(active.id, forKey: key)
        } else {
          let retainedID = UserDefaults.standard.integer(forKey: key)
          if retainedID > 0 {
            do { scan = try await api.duplicateScan(id: retainedID) } catch {
              UserDefaults.standard.removeObject(forKey: key)
              throw error
            }
          }
        }
        if let scan, scan.status == "completed" {
          let response = try await api.duplicateGroups(scanID: scan.id, page: target)
          groups = response.groups
          total = response.total
        } else {
          groups = []
          total = 0
        }
      case .rename:
        guard let libraryID else { return }
        let response = try await api.renamePreview(libraryID: libraryID, page: target)
        renamePreviewToken = response.previewToken
        renames = response.items
        total = response.total
      case .missing:
        summary = try await api.missingSummary()
        let response = try await api.missingBooks(page: target)
        missing = response.items
        total = response.total
      }
      page = target
    } catch { self.error = error.localizedDescription }
  }

  private var scanRecoveryKey: String {
    "maintenance.duplicateScan.\(api.profile.url.absoluteString).user.\(user.id).library.\(libraryID ?? 0)"
  }

  func startScan() {
    run {
      self.scan = try await self.api.startDuplicateScan(libraryID: self.libraryID)
      if let scan = self.scan { UserDefaults.standard.set(scan.id, forKey: self.scanRecoveryKey) }
      while let scan = self.scan, scan.status == "queued" || scan.status == "running" {
        self.progress = "Scanned \(scan.processedBooks) books"
        try await Task.sleep(for: .seconds(1))
        self.scan = try await self.api.duplicateScan(id: scan.id)
      }
      if self.scan?.status == "failed" { throw ConnectionError.invalidResponse }
      self.progress = "Scan complete"
    }
  }

  func previewMerge(source: Int, target: Int) {
    guard canMerge else { return }
    run { self.merge = try await self.api.mergePreview(source: source, target: target) }
  }

  func applyMerge() {
    guard canMerge, let merge, merge.canApply else { return }
    run {
      let outcome = try await self.api.mergeBooks(merge)
      self.result =
        "Merged into book \(outcome.targetBookId). Preserved \(outcome.filesPreserved) files."
      self.merge = nil
    }
  }

  func applyRename() {
    guard canRename, let libraryID, let renamePreviewToken, !selectedBookIDs.isEmpty else {
      return
    }
    let ids = Array(selectedBookIDs).sorted()
    run {
      self.renameCompleted = false
      try await self.api.renameBooks(
        libraryID: libraryID, bookIDs: ids, previewToken: renamePreviewToken
      ) { event in
        await MainActor.run {
          if let done = event.done, done {
            self.renameCompleted = true
            self.result =
              "Renamed \(event.succeeded ?? 0), failed \(event.failed ?? 0), skipped \(event.skipped ?? 0)."
          } else if let bookID = event.bookId {
            self.progress = "Book \(bookID): \(event.status ?? "processed")"
          } else if let total = event.total {
            self.progress = "Renaming \(total) selected books"
          }
        }
      }
      guard self.renameCompleted else { throw ConnectionError.invalidResponse }
    }
  }

  func selectMissing(_ book: MissingBookEntry) {
    guard canRepair else { return }
    run {
      let detail: BookDetail = try await self.api.boundedJSON("books/\(book.id)")
      self.repairBookID = String(book.id)
      self.repairFiles = detail.files
      self.repairFileID = detail.files.first.map { String($0.id) } ?? ""
    }
  }

  func previewRepair() {
    guard canRepair, let book = Int(repairBookID), let file = Int(repairFileID),
      book > 0, file > 0, !replacementPath.isEmpty
    else { return }
    run {
      self.repair = try await self.api.repairPreview(
        .init(
          bookId: book, fileId: file, replacementPath: self.replacementPath))
    }
  }

  func applyRepair() {
    guard canRepair, let repair else { return }
    run {
      let outcome = try await self.api.repairFile(repair)
      self.result =
        outcome.alreadyApplied
        ? "The file was already repaired." : "File repaired. Reading data was preserved."
      self.repair = nil
    }
  }

  var canCleanBrokenCovers: Bool {
    canDelete && user.hasPermission(.libraryEditMetadata)
      && !user.permissions.contains(Permission.demoRestricted.rawValue)
  }
  var canCleanOrphanedCovers: Bool { canRepair }

  var coverCleanupCount: Int {
    switch cleanupCategory {
    case "broken-covers": brokenCovers.count
    case "orphaned-covers": orphanedCovers.count
    default: 0
    }
  }

  var canApplyCoverCleanup: Bool {
    guard (1...40).contains(coverCleanupCount) else { return false }
    switch cleanupCategory {
    case "broken-covers": return canCleanBrokenCovers
    case "orphaned-covers": return canCleanOrphanedCovers
    default: return false
    }
  }

  func previewCoverCleanup(category: String) {
    guard !isBusy else { return }
    cleanupCategory = category
    guard canApplyCoverCleanup else {
      cleanupCategory = nil
      return
    }
    error = nil
  }

  func reviewCoverCleanup() {
    guard canDelete else { return }
    run {
      self.cleanupCategory = nil
      self.brokenCovers = []
      self.orphanedCovers = []
      self.progress = "Loading cover cleanup preview"
      defer { self.progress = "" }
      let broken = try await self.api.brokenCovers().items
      var orphaned: [OrphanedCoverDirEntry] = []
      if self.canCleanOrphanedCovers {
        orphaned = try await self.api.orphanedCoverDirs().items
      }
      self.brokenCovers = broken
      self.orphanedCovers = orphaned
      self.result =
        "Review ready: \(broken.count) broken cover entries, \(orphaned.count) orphaned folders."
    }
  }

  func applyCoverCleanup() {
    guard !isBusy, canApplyCoverCleanup, let category = cleanupCategory else { return }
    let ids = category == "broken-covers" ? brokenCovers.map(\.id) : orphanedCovers.map(\.bookId)
    run {
      self.progress = "Cleaning \(ids.count) reviewed cover entries"
      defer { self.progress = "" }
      let outcome = try await self.api.cleanupMissingResources(category: category, bookIDs: ids)
      self.result =
        "Cleaned \(outcome.cleaned), skipped \(outcome.skipped), \(outcome.remaining) remaining. Review cover cleanup again for the next pass."
      self.cleanupCategory = nil
      if category == "broken-covers" {
        self.brokenCovers = []
      } else {
        self.orphanedCovers = []
      }
    }
  }

  func startSweep() {
    guard canDelete else { return }
    run {
      var sweep = try await self.api.startCoverSweep()
      while sweep.status == "running" {
        self.progress = "Cover check: \(sweep.processedBooks) books checked"
        try await Task.sleep(for: .seconds(1))
        if let current = try await self.api.coverSweep() { sweep = current } else { break }
      }
      if sweep.status == "failed" { throw ConnectionError.invalidResponse }
      self.progress =
        "Cover check complete: \(sweep.brokenCovers) broken covers, \(sweep.orphanedCoverDirs) orphaned folders"
    }
  }

  func cancel() {
    operation?.cancel()
    operation = nil
    progress = "Stopped. Refresh the preview before retrying. Completed work is preserved."
  }

  private func run(_ action: @MainActor @escaping () async throws -> Void) {
    guard !isBusy else { return }
    isBusy = true
    error = nil
    result = nil
    operation = Task {
      defer {
        self.isBusy = false
        self.operation = nil
      }
      do {
        try await action()
        self.isBusy = false
        await self.refresh()
      } catch is CancellationError {
        self.progress = "Stopped. Refresh the preview before retrying. Completed work is preserved."
      } catch { self.error = error.localizedDescription }
    }
  }
}
