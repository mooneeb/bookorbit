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
  private let api: BookOrbitAPI
  private let bookID: Int
  private(set) var book: BookDetail
  private(set) var images: [CoverMedium: UIImage] = [:]
  private(set) var pending: [CoverMedium: StagedCoverImage] = [:]
  private(set) var importing: Set<CoverMedium> = []
  private(set) var isSaving = false
  private(set) var isReloading = false
  private(set) var requiresReload = false
  private(set) var errors: [CoverMedium: String] = [:]
  private(set) var message: String?
  @ObservationIgnored private var importTasks: [CoverMedium: Task<Void, Never>] = [:]
  @ObservationIgnored private var isClosed = false
  @ObservationIgnored private var imageLoadID = UUID()

  init(api: BookOrbitAPI, book: BookDetail) {
    self.api = api
    self.book = book
    bookID = book.id
  }

  var media: [CoverMedium] { book.coverMedia.isEmpty ? [.ebook] : book.coverMedia }
  var isBusy: Bool { isSaving || isReloading || !importing.isEmpty }

  func slot(_ medium: CoverMedium) -> BookCoverSlot? {
    medium == .ebook ? book.covers.ebook : book.covers.audio
  }

  func isLocked(_ medium: CoverMedium) -> Bool { book.lockedFields.contains(medium.lockField) }

  func canEdit(_ medium: CoverMedium) -> Bool { !requiresReload && !isLocked(medium) }

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
    if let image = pending.removeValue(forKey: medium) {
      try? FileManager.default.removeItem(at: image.file)
    }
  }

  func save(_ medium: CoverMedium) async {
    guard let selection = pending[medium], !isBusy, canEdit(medium), !isClosed else { return }
    imageLoadID = UUID()
    isSaving = true
    errors[medium] = nil
    message = nil
    defer { isSaving = false }
    do {
      try await api.uploadCover(bookID: bookID, medium: medium, selection: selection)
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

  private func handleWriteFailure(_ error: Error, medium: CoverMedium) async {
    guard !isClosed else { return }
    if case .http(409)? = error as? ConnectionError {
      requiresReload = true
      let recovery =
        pending[medium] != nil
        ? "Your selection is kept. Reload before saving."
        : "Reload to check the current cover."
      let lockRecovery =
        pending[medium] != nil
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
    for task in importTasks.values { task.cancel() }
    for medium in Array(pending.keys) { discard(medium) }
  }
}
