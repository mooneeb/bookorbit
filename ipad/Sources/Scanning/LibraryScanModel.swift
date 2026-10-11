import Foundation
import Observation

@MainActor @Observable
final class LibraryScanModel {
  let api: BookOrbitAPI
  let libraryID: Int
  private let retryKey: String
  private(set) var configuration: LibraryScanConfiguration?
  private(set) var history: [LibraryScanHistoryEntry] = []
  private(set) var progress: ScanProgressEvent?
  private(set) var preview: PrescanResult?
  private(set) var books: [BookCard] = []
  private(set) var bookPage = 0
  private(set) var bookTotal = 0
  private(set) var isBusy = false
  private(set) var message: String?
  private(set) var retryBaseline: Int?
  private var statusVerified = false
  private var configurationScanBaseline: Int?
  var paths = ""
  var watch = false
  var cron = ""
  var allowedFormats = ""
  var exclusions = ""
  var organizationMode = "book_per_file"
  var bookSearch = ""

  init(api: BookOrbitAPI, libraryID: Int, userID: Int) {
    self.api = api
    self.libraryID = libraryID
    retryKey = "serverScan.\(api.profile.url.absoluteString).\(userID).\(libraryID)"
    retryBaseline = UserDefaults.standard.object(forKey: retryKey) as? Int
  }

  var folderPaths: [String] {
    paths.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter {
      !$0.isEmpty
    }
  }
  var canStart: Bool {
    !isBusy && statusVerified && retryBaseline == nil && configurationScanBaseline == nil
      && configuration != nil
      && progress?.status != "running" && history.first?.status != "running"
      && preview != nil && !hasUnsavedConfiguration
  }
  var hasUnsavedConfiguration: Bool {
    guard let configuration else { return false }
    return folderPaths != configuration.folders.map(\.path) || watch != configuration.watch
      || cron != (configuration.autoScanCronExpression ?? "")
      || values(allowedFormats) != configuration.allowedFormats
      || values(exclusions) != configuration.excludePatterns
      || organizationMode != configuration.organizationMode
  }
  var validConfiguration: Bool {
    !folderPaths.isEmpty && folderPaths.count <= 20
      && folderPaths.allSatisfy { $0.hasPrefix("/") && $0.count <= 4096 }
      && cron.count <= 255 && values(allowedFormats).count <= 32 && values(exclusions).count <= 64
  }
  var shouldMonitorStatus: Bool {
    progress?.status == "running" || retryBaseline != nil || configurationScanBaseline != nil
  }

  func load() async {
    guard !isBusy else { return }
    isBusy = true
    statusVerified = false
    defer { isBusy = false }
    do {
      let result = try await api.scanConfiguration(libraryID: libraryID)
      guard result.id == libraryID, result.type == "books", result.folders.count <= 20 else {
        throw ConnectionError.invalidResponse
      }
      configuration = result
      apply(result)
      try await reconcile()
      message =
        retryBaseline == nil
        ? nil : "A scan request is awaiting reconciliation. Retry uses the original job baseline."
      try await loadBooks(page: 0)
    } catch { message = error.localizedDescription }
  }

  func refreshStatus() async {
    guard !isBusy else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      try await reconcile()
      if progress?.status == "completed" { try await loadBooks(page: bookPage) }
      if retryBaseline == nil { message = nil }
    } catch {
      message =
        "Connection unavailable. The server scan may continue. Reload status or retry the original request. \(error.localizedDescription)"
    }
  }

  private func reconcile() async throws {
    statusVerified = false
    let status = try await api.scanStatus(libraryID: libraryID)
    let recent = try await api.scanHistory(libraryID: libraryID)
    guard recent.count <= 5, status.progress?.libraryId == libraryID || status.progress == nil
    else { throw ConnectionError.invalidResponse }
    progress = status.progress
    history = recent
    statusVerified = true
    if let configurationScanBaseline, let latest = recent.first,
      latest.id > configurationScanBaseline
    {
      self.configurationScanBaseline = nil
    }
    if let retryBaseline, let progress, progress.jobId > retryBaseline { clearRetry() }
  }

  func previewFolders() async {
    guard !isBusy, validConfiguration else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      let result = try await api.previewScan(libraryID: libraryID, paths: folderPaths)
      guard result.paths.count == folderPaths.count, result.totalFiles >= 0,
        result.paths.allSatisfy({ $0.fileCount >= 0 })
      else { throw ConnectionError.invalidResponse }
      preview = result
      message = nil
    } catch {
      preview = nil
      message = error.localizedDescription
    }
  }

  func save() async {
    guard !isBusy, validConfiguration, retryBaseline == nil, progress?.status != "running" else {
      return
    }
    isBusy = true
    defer { isBusy = false }
    do {
      let result = try await api.saveScanConfiguration(
        libraryID: libraryID,
        request: ScanConfigurationRequest(
          folders: folderPaths, watch: watch, autoScanCronExpression: cron.isEmpty ? nil : cron,
          allowedFormats: values(allowedFormats), excludePatterns: values(exclusions),
          organizationMode: organizationMode))
      configuration = result
      apply(result)
      preview = nil
      configurationScanBaseline = history.first?.id ?? 0
      try await reconcile()
      message = "Configuration saved. The server automatically scans when scan settings change."
    } catch { message = "Reload configuration before saving again. \(error.localizedDescription)" }
  }

  func start() async {
    guard canStart else { return }
    retryBaseline = history.first?.id ?? 0
    UserDefaults.standard.set(retryBaseline, forKey: retryKey)
    await submit()
  }

  func retry() async {
    guard retryBaseline != nil, !isBusy else { return }
    await submit()
  }

  private func submit() async {
    guard let retryBaseline else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      let accepted = try await api.startScan(libraryID: libraryID, baseline: retryBaseline)
      guard accepted.jobId > retryBaseline else { throw ConnectionError.invalidResponse }
      try await reconcile()
      message = "Scan job \(accepted.jobId) accepted. Files stay on the server."
    } catch {
      message =
        "The scan response was not confirmed. Retry reconciles the same request and will not start a second job. \(error.localizedDescription)"
    }
  }

  func previousBooks() async {
    guard bookPage > 0 else { return }
    await browse(page: bookPage - 1)
  }
  func nextBooks() async {
    guard (bookPage + 1) * 40 < bookTotal else { return }
    await browse(page: bookPage + 1)
  }
  func searchBooks() async { await browse(page: 0) }
  private func browse(page: Int) async {
    guard !isBusy else { return }
    isBusy = true
    defer { isBusy = false }
    do { try await loadBooks(page: page) } catch { message = error.localizedDescription }
  }
  private func loadBooks(page: Int) async throws {
    let result: BooksPage = try await api.boundedJSON(
      "libraries/\(libraryID)/books", method: "POST",
      body: JSONEncoder().encode(
        BookQuery(
          filter: nil, sort: [SortSpec(field: "addedAt", dir: "desc")],
          pagination: BookQueryPagination(page: page, size: 40), q: bookSearch,
          collapseSeries: false, randomSeed: nil)), byteLimit: 512 * 1024, expectedStatus: 201)
    guard result.items.count <= 40, result.page == page else {
      throw ConnectionError.invalidResponse
    }
    books = result.items
    bookPage = page
    bookTotal = result.total
  }
  private func clearRetry() {
    retryBaseline = nil
    UserDefaults.standard.removeObject(forKey: retryKey)
  }
  private func values(_ value: String) -> [String] {
    value.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter {
      !$0.isEmpty
    }
  }
  private func apply(_ value: LibraryScanConfiguration) {
    paths = value.folders.map(\.path).joined(separator: "\n")
    watch = value.watch
    cron = value.autoScanCronExpression ?? ""
    allowedFormats = value.allowedFormats.joined(separator: "\n")
    exclusions = value.excludePatterns.joined(separator: "\n")
    organizationMode = value.organizationMode
  }
}
