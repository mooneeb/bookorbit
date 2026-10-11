import CryptoKit
import Foundation
import Observation

private struct BulkActionsRecovery: Codable {
  var request: SelectedBulkMetadataRequest
  var confirmedBookIDs: [Int]
}

private enum BulkActionsDraftError: LocalizedError {
  case missingValue, invalidYear, invalidCustomValue
  var errorDescription: String? {
    switch self {
    case .missingValue: String(localized: "Enter a value, or choose Clear this field.")
    case .invalidYear: String(localized: "Enter a whole publication year of zero or greater.")
    case .invalidCustomValue:
      String(localized: "Choose a custom field and enter a value matching its type.")
    }
  }
}

@MainActor @Observable
final class BulkActionsModel {
  enum Action: String, CaseIterable {
    case edit = "Edit metadata"
    case content = "Export books"
    case json = "Export JSON"
    case csv = "Export CSV"
  }
  enum Field: String, CaseIterable {
    case publisher, language, publishedYear, seriesName, authors, genres, tags, narrators,
      customMetadata
    var label: String {
      switch self {
      case .publisher: String(localized: "Publisher")
      case .language: String(localized: "Language")
      case .publishedYear: String(localized: "Publication year")
      case .seriesName: String(localized: "Series")
      case .authors: String(localized: "Authors")
      case .genres: String(localized: "Genres")
      case .tags: String(localized: "Tags")
      case .narrators: String(localized: "Narrators")
      case .customMetadata: String(localized: "Custom field")
      }
    }
  }
  let api: BookOrbitAPI
  let user: AuthUser
  let bookIDs: [Int]
  var action: Action = .edit
  var field: Field = .publisher
  var value = ""
  var arrayMode = "add"
  var clearValue = false
  var allFormats = false
  var audioOnly = false
  var includePersonalData = false
  var includeFilePaths = false
  var customFields: [CustomMetadataFieldSummary] = []
  var customFieldID: Int?
  var preview: BulkMetadataPreview?
  var exportSummary: String?
  var message: String?
  var isBusy = false
  var completedCount = 0
  var needsReview = false
  var artifact: StagedBookFile?
  var progress: BookFileTransferProgress?
  var delivery: BookFileDeliveryPresentation?
  private var task: Task<Void, Never>?
  private var request: SelectedBulkMetadataRequest?
  private var exportBody: Data?
  private var exportPath: String?
  private var session: UUID?

  init(api: BookOrbitAPI, user: AuthUser, bookIDs: [Int]) {
    self.api = api
    self.user = user
    self.bookIDs = Array(Set(bookIDs)).sorted()
  }

  var canEdit: Bool {
    user.hasPermission(.libraryEditMetadata)
      && !user.permissions.contains(Permission.demoRestricted.rawValue)
  }
  var canExport: Bool {
    user.hasPermission(.libraryDownload)
      && !user.permissions.contains(Permission.demoRestricted.rawValue)
  }
  var canApply: Bool { !isBusy && (preview != nil || exportSummary != nil) && !needsReview }
  var isArray: Bool { [.authors, .genres, .tags, .narrators].contains(field) }
  private var journalURL: URL {
    let scope =
      "\(api.profile.url.absoluteString).\(user.id).\(bookIDs.map(String.init).joined(separator: ","))"
    let key = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("bulk-\(key).json")
  }

  func load() async {
    isBusy = true
    defer { isBusy = false }
    do {
      session = try await api.authenticatedSessionGeneration()
      customFields = try await api.boundedJSON("custom-metadata/fields/active", session: session)
      customFieldID = customFields.first?.id
      if FileManager.default.fileExists(atPath: journalURL.path) {
        let recovery = try JSONDecoder().decode(
          BulkActionsRecovery.self, from: Data(contentsOf: journalURL))
        restore(recovery.request.fields)
        completedCount = recovery.confirmedBookIDs.count
        needsReview = true
        message =
          "An interrupted batch confirmed \(completedCount) of \(bookIDs.count) selected books. Additional work may have completed before the connection ended. Reload a preview to inspect current values before applying again."
      }
    } catch { message = error.localizedDescription }
  }

  private func restore(_ fields: BulkMetadataEditFields) {
    guard let data = try? JSONEncoder().encode(fields),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let key = object.keys.sorted().first, let selected = Field(rawValue: key)
    else { return }
    field = selected
    action = .edit
    if let array = object[key] as? [String: Any], let values = array["values"] as? [String] {
      arrayMode = array["mode"] as? String ?? "replace"
      clearValue = values.isEmpty
      value = values.joined(separator: "\n")
    } else if let scalar = object[key] as? [String: Any] {
      clearValue = scalar["value"] is NSNull
      value = clearValue ? "" : String(describing: scalar["value"] ?? "")
    } else if let values = object[key] as? [[String: Any]], let first = values.first {
      customFieldID = first["fieldId"] as? Int
      clearValue = first["value"] is NSNull
      value = clearValue ? "" : String(describing: first["value"] ?? "")
    }
  }

  private func fields() throws -> BulkMetadataEditFields {
    guard clearValue || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw BulkActionsDraftError.missingValue
    }
    let raw: Any = clearValue ? NSNull() : value.trimmingCharacters(in: .whitespacesAndNewlines)
    let values = value.split(separator: "\n").map {
      String($0).trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty }
    var payload: [String: Any]
    if isArray {
      guard clearValue || !values.isEmpty else { throw BulkActionsDraftError.missingValue }
      payload = [
        field.rawValue: [
          "mode": clearValue ? "replace" : arrayMode, "values": clearValue ? [] : values,
        ]
      ]
    } else if field == .customMetadata {
      guard let id = customFieldID, let definition = customFields.first(where: { $0.id == id })
      else { throw BulkActionsDraftError.invalidCustomValue }
      var custom: Any = raw
      if !clearValue && definition.type == "number" {
        guard let number = Double(value), number.isFinite else {
          throw BulkActionsDraftError.invalidCustomValue
        }
        custom = number
      } else if !clearValue && definition.type == "boolean" {
        guard ["true", "false"].contains(value.lowercased()) else {
          throw BulkActionsDraftError.invalidCustomValue
        }
        custom = value.lowercased() == "true"
      }
      payload = ["customMetadata": [["fieldId": id, "value": custom]]]
    } else if field == .publishedYear && !clearValue {
      guard let year = Int(value), year >= 0 else { throw BulkActionsDraftError.invalidYear }
      payload = [field.rawValue: ["value": year]]
    } else {
      payload = [field.rawValue: ["value": raw]]
    }
    return try JSONDecoder().decode(
      BulkMetadataEditFields.self, from: JSONSerialization.data(withJSONObject: payload))
  }

  func prepare() {
    guard !isBusy else { return }
    preview = nil
    exportSummary = nil
    message = nil
    task = Task {
      isBusy = true
      defer {
        isBusy = false
        task = nil
      }
      do {
        guard !bookIDs.isEmpty, bookIDs.count <= 100, let session else {
          throw ConnectionError.invalidResponse
        }
        if action == .edit {
          guard canEdit else { throw ConnectionError.denied }
          let candidate = SelectedBulkMetadataRequest(
            bookIds: bookIDs, fields: try fields(), expectedVersions: nil)
          preview = try await api.bulkMetadataPreview(candidate, session: session)
          request = candidate
        } else if action == .content {
          guard canExport else { throw ConnectionError.denied }
          let candidate = SelectedBookExportRequest(
            bookIds: bookIDs, allFormats: allFormats, audioOnly: audioOnly)
          let result = try await api.bulkBookExportPreview(candidate, session: session)
          exportSummary =
            "\(result.bookCount) books, \(result.fileCount) files, \(result.projectedBytes) bytes"
          exportBody = try JSONEncoder().encode(candidate)
          exportPath = "books/export"
        } else {
          guard canExport else { throw ConnectionError.denied }
          let candidate = SelectedMetadataExportRequest(
            bookIds: bookIDs, format: action == .csv ? "csv" : "json",
            options: SelectedMetadataExportOptions(
              includePersonalData: includePersonalData, includeFilePaths: includeFilePaths,
              includeContextMeta: true, columnsMode: "canonical", visibleColumns: nil))
          let result = try await api.bulkMetadataExportPreview(candidate, session: session)
          exportSummary = "\(result.rowCount) rows, approximately \(result.estimatedBytes) bytes"
          exportBody = try JSONEncoder().encode(candidate)
          exportPath = "books/metadata-export/download"
        }
        needsReview = false
      } catch { message = error.localizedDescription }
    }
  }

  func apply(completed: @escaping () -> Void) {
    guard canApply, let session else { return }
    task = Task {
      isBusy = true
      message = nil
      defer {
        isBusy = false
        task = nil
      }
      do {
        if let preview, let request {
          try FileManager.default.createDirectory(
            at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
          var recovery = BulkActionsRecovery(request: request, confirmedBookIDs: [])
          recovery.request.expectedVersions = preview.books.map {
            BulkMetadataVersion(bookId: $0.bookId, updatedAt: $0.updatedAt)
          }
          try JSONEncoder().encode(recovery).write(to: journalURL, options: .atomic)
          completedCount = 0
          for start in stride(from: 0, to: bookIDs.count, by: 25) {
            try Task.checkCancellation()
            let ids = Array(bookIDs[start..<min(start + 25, bookIDs.count)])
            let versions = preview.books.filter { ids.contains($0.bookId) }.map {
              BulkMetadataVersion(bookId: $0.bookId, updatedAt: $0.updatedAt)
            }
            let result = try await api.applyBulkMetadata(
              SelectedBulkMetadataRequest(
                bookIds: ids, fields: request.fields, expectedVersions: versions), session: session)
            completedCount += ids.count
            recovery.confirmedBookIDs.append(contentsOf: ids)
            try JSONEncoder().encode(recovery).write(to: journalURL, options: .atomic)
            message =
              "Reviewed \(completedCount) of \(bookIDs.count) books. Last batch updated \(result.updatedBooks)."
          }
          try FileManager.default.removeItem(at: journalURL)
          self.preview = nil
          message = "Selected batch completed. Reading progress and annotations were preserved."
          completed()
        } else if let exportBody, let exportPath {
          artifact?.remove()
          artifact = nil
          artifact = try await api.boundedBulkDownload(
            path: exportPath, body: exportBody, session: session
          ) { [weak self] in self?.progress = $0 }
          message = "Export ready. Save or share the downloaded file."
        }
      } catch {
        needsReview = action == .edit
        message =
          action == .edit
          ? "Batch stopped after \(completedCount) confirmed books. Reload preview before retrying. \(error.localizedDescription)"
          : error.localizedDescription
      }
    }
  }

  func invalidatePreview() {
    preview = nil
    exportSummary = nil
    request = nil
    exportBody = nil
    exportPath = nil
  }
  func cancel() { task?.cancel() }
  func close() {
    cancel()
    artifact?.remove()
  }
  func save() { if let artifact { delivery = .init(artifact: artifact, kind: .save) } }
  func share() { if let artifact { delivery = .init(artifact: artifact, kind: .share) } }
  func delivered(_ result: BookFileDeliveryResult, _ id: UUID) {
    delivery = nil
    message =
      result == .cancelled
      ? "Export kept. Save or share when ready."
      : result == .failed
        ? "Delivery failed. The downloaded export is available to retry." : "Export delivered."
  }
}
