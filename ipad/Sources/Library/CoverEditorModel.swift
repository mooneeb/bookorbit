import Foundation
import Observation
import PhotosUI
import SwiftUI
import UIKit

extension CoverMedium {
  var label: String { self == .ebook ? "Ebook cover" : "Audio cover" }
  var identifier: String { self == .ebook ? "Ebook" : "Audio" }
  var lockField: String { self == .ebook ? "cover" : "audioCover" }
}

@MainActor @Observable
final class CoverEditorModel {
  let api: BookOrbitAPI
  private let bookID: Int
  private(set) var book: BookDetail
  private(set) var images: [CoverMedium: UIImage] = [:]
  private(set) var pending: [CoverMedium: StagedCoverImage] = [:]
  private(set) var pendingURLs: [CoverMedium: String] = [:]
  private(set) var importing: Set<CoverMedium> = []
  private(set) var isSaving = false
  private(set) var isReloading = false
  private(set) var reExtracting: CoverMedium?
  private(set) var canReExtractCovers = false
  private(set) var failedReExtractions: Set<CoverMedium> = []
  private(set) var requiresReload = false
  private(set) var errors: [CoverMedium: String] = [:]
  private(set) var message: String?
  @ObservationIgnored private var importTasks: [CoverMedium: Task<Void, Never>] = [:]
  @ObservationIgnored private var isClosed = false
  @ObservationIgnored private var imageLoadID = UUID()
  @ObservationIgnored private var extractionTask: Task<Void, Never>?
  @ObservationIgnored private var extractionOperation = UUID()

  init(api: BookOrbitAPI, book: BookDetail) {
    self.api = api
    self.book = book
    bookID = book.id
  }

  var media: [CoverMedium] { book.coverMedia.isEmpty ? [.ebook] : book.coverMedia }
  var isBusy: Bool { isSaving || isReloading || reExtracting != nil || !importing.isEmpty }

  func slot(_ medium: CoverMedium) -> BookCoverSlot? {
    medium == .ebook ? book.covers.ebook : book.covers.audio
  }

  func isLocked(_ medium: CoverMedium) -> Bool { book.lockedFields.contains(medium.lockField) }

  func canEdit(_ medium: CoverMedium) -> Bool { !requiresReload && !isLocked(medium) }

  func hasSelection(_ medium: CoverMedium) -> Bool {
    pending[medium] != nil || pendingURLs[medium] != nil
  }

  func chooseURL(_ url: String, medium: CoverMedium) {
    guard !isBusy, !isClosed, canEdit(medium) else { return }
    discard(medium)
    pendingURLs[medium] = url
    errors[medium] = nil
    message = nil
  }

  func load() async {
    let allowed = await api.canReExtractCovers()
    guard !isClosed, !Task.isCancelled else { return }
    canReExtractCovers = allowed
    await loadImages()
  }

  func loadImages() async {
    let operation = UUID()
    imageLoadID = operation
    let version = book.coverVersion
    for medium in media {
      guard !isClosed, imageLoadID == operation, book.coverVersion == version else { return }
      errors[medium] = nil
      guard slot(medium) != nil else {
        images[medium] = nil
        continue
      }
      do {
        let bytes = try await api.coverImage(
          bookID: bookID, medium: medium, version: version)
        guard !isClosed, imageLoadID == operation, book.coverVersion == version else { return }
        let preview = try await CoverImageImport.shared.preview(bytes)
        guard !isClosed, imageLoadID == operation, book.coverVersion == version else { return }
        images[medium] = UIImage(data: preview)
      } catch {
        guard !isClosed, imageLoadID == operation, book.coverVersion == version else { return }
        errors[medium] = error.localizedDescription
      }
    }
  }

  func choose(_ item: PhotosPickerItem?, medium: CoverMedium) {
    guard let item, !isBusy, !isClosed, canEdit(medium) else { return }
    importing.insert(medium)
    errors[medium] = nil
    message = nil
    importTasks[medium] = Task {
      defer {
        importing.remove(medium)
        importTasks[medium] = nil
      }
      do {
        guard let selection = try await item.loadTransferable(type: StagedCoverImage.self) else {
          throw CoverImageError.invalidImage
        }
        guard !Task.isCancelled, !isClosed else {
          try? FileManager.default.removeItem(at: selection.file)
          return
        }
        discard(medium)
        pending[medium] = selection
      } catch {
        if !isClosed, !Task.isCancelled { errors[medium] = error.localizedDescription }
      }
    }
  }

  func reload(_ medium: CoverMedium) async {
    guard !isBusy, !isClosed else { return }
    imageLoadID = UUID()
    isReloading = true
    message = nil
    defer { isReloading = false }
    do {
      let current: BookDetail = try await api.send("books/\(bookID)")
      guard !isClosed else { return }
      book = current
      requiresReload = false
      await loadImages()
    } catch { errors[medium] = error.localizedDescription }
  }

  func discard(_ medium: CoverMedium) {
    pendingURLs[medium] = nil
    if let image = pending.removeValue(forKey: medium) {
      try? FileManager.default.removeItem(at: image.file)
    }
  }

  func save(_ medium: CoverMedium) async {
    guard hasSelection(medium), !isBusy, canEdit(medium), !isClosed else { return }
    imageLoadID = UUID()
    isSaving = true
    errors[medium] = nil
    message = nil
    defer { isSaving = false }
    do {
      if let selection = pending[medium] {
        try await api.uploadCover(bookID: bookID, medium: medium, selection: selection)
      } else if let url = pendingURLs[medium] {
        try await api.sendEmpty(
          "books/\(bookID)/cover/from-url",
          body: JSONEncoder().encode(UploadCoverFromUrlPayload(url: url)),
          query: [URLQueryItem(name: "medium", value: medium.rawValue)])
      }
      book = try await api.send("books/\(bookID)")
      discard(medium)
      await loadImages()
      message = "\(medium.label) saved."
    } catch { await handleWriteFailure(error, medium: medium) }
  }

  func revert(_ medium: CoverMedium) async {
    guard !isBusy, canEdit(medium), !isClosed else { return }
    imageLoadID = UUID()
    isSaving = true
    errors[medium] = nil
    message = nil
    defer { isSaving = false }
    do {
      try await api.sendEmpty(
        "books/\(bookID)/cover", method: "DELETE",
        query: [URLQueryItem(name: "medium", value: medium.rawValue)])
      book = try await api.send("books/\(bookID)")
      discard(medium)
      await loadImages()
      message = "\(medium.label) reverted."
    } catch { await handleWriteFailure(error, medium: medium) }
  }

  func reExtract(_ medium: CoverMedium) {
    guard canReExtractCovers, media.contains(medium), !isBusy, canEdit(medium), !isClosed else {
      return
    }
    imageLoadID = UUID()
    extractionOperation = UUID()
    let operation = extractionOperation
    reExtracting = medium
    failedReExtractions.remove(medium)
    errors[medium] = nil
    message = nil
    extractionTask = Task { [weak self] in
      await self?.performReExtraction(medium, operation: operation)
    }
  }

  private func performReExtraction(_ medium: CoverMedium, operation: UUID) async {
    defer {
      if extractionOperation == operation {
        reExtracting = nil
        extractionTask = nil
      }
    }
    var result: CoverReExtractionResult?
    do {
      let session = try await api.authenticatedSessionGeneration()
      result = try await api.reExtractCover(bookID: bookID, medium: medium, session: session)
      guard isCurrentExtraction(operation) else { return }
      requiresReload = true
      if result?.updated == 1 { images[medium] = nil }
      let current: BookDetail = try await api.boundedJSON("books/\(bookID)", session: session)
      guard isCurrentExtraction(operation) else { return }
      if book.coverVersion != current.coverVersion { images = [:] }
      book = current
      requiresReload = false
      await loadImages()
      guard isCurrentExtraction(operation), let result else { return }
      message = extractionMessage(result, medium: medium)
    } catch {
      guard isCurrentExtraction(operation) else { return }
      if let result {
        message =
          result.updated == 0
          ? noExtractionMessage(medium) : "\(medium.label) re-extracted on the server."
        errors[medium] =
          "Current cover information could not be refreshed. Reload cover to check the result."
      } else {
        failedReExtractions.insert(medium)
        if case .http(403)? = error as? ConnectionError { canReExtractCovers = false }
        await handleWriteFailure(error, medium: medium)
      }
    }
  }

  private func isCurrentExtraction(_ operation: UUID) -> Bool {
    !isClosed && !Task.isCancelled && extractionOperation == operation
  }

  private func noExtractionMessage(_ medium: CoverMedium) -> String {
    "No \(medium.rawValue) cover was re-extracted. The server did not update this cover."
  }

  private func extractionMessage(_ result: CoverReExtractionResult, medium: CoverMedium) -> String {
    guard result.updated > 0 else {
      return isLocked(medium)
        ? "\(medium.label) is locked. No cover was re-extracted."
        : noExtractionMessage(medium)
    }
    var message = "\(medium.label) re-extracted."
    if slot(medium)?.source == "custom" {
      message += " Your custom cover remains selected."
    }
    if hasSelection(medium) { message += " Your unsaved selection is kept." }
    return message
  }

  private func handleWriteFailure(_ error: Error, medium: CoverMedium) async {
    guard !isClosed else { return }
    if case .http(409)? = error as? ConnectionError {
      requiresReload = true
      let recovery =
        hasSelection(medium)
        ? "Your selection is kept. Reload before saving."
        : "Reload to check the current cover."
      let lockRecovery =
        hasSelection(medium)
        ? "Your selection is kept. Unlock it, then reload before saving."
        : "Unlock it, then reload before editing."
      do {
        let current: BookDetail = try await api.send("books/\(bookID)")
        guard !isClosed else { return }
        book = current
        requiresReload = false
        errors[medium] =
          isLocked(medium)
          ? "Another session locked this cover. \(lockRecovery)"
          : "The cover changed on the server. \(recovery)"
      } catch {
        errors[medium] =
          "Cover information could not be refreshed. \(recovery)"
      }
    } else {
      errors[medium] = error.localizedDescription
    }
  }

  func close() {
    isClosed = true
    imageLoadID = UUID()
    extractionOperation = UUID()
    extractionTask?.cancel()
    extractionTask = nil
    reExtracting = nil
    for task in importTasks.values { task.cancel() }
    for medium in Set(pending.keys).union(pendingURLs.keys) { discard(medium) }
  }
}
