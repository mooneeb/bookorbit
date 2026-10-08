import Foundation
import Observation

@MainActor @Observable
final class SourceRecoveryModel {
  let api: BookOrbitAPI
  let bookID: Int?
  let fileID: Int?
  private(set) var versions: [OfflineSourceVersion] = []
  private(set) var drafts: [NativeAnnotationRecoveryDraft] = []
  private(set) var isBusy = false
  private(set) var error: String?
  private(set) var nextCursor: String?
  private(set) var previousCursors: [String?] = []
  private(set) var artifact: StagedBookFile?
  private(set) var exportedVersionID: String?
  private(set) var protectedVersionIDs: Set<String> = []
  var removal: OfflineSourceVersion?
  var confirmsRemoval = false
  private var cursor: String?
  private var operationID = UUID()

  init(api: BookOrbitAPI, bookID: Int?, fileID: Int?) {
    self.api = api
    self.bookID = bookID
    self.fileID = fileID
  }

  func load() async {
    guard !isBusy else { return }
    isBusy = true
    error = nil
    defer { isBusy = false }
    do {
      let session = try await api.authenticatedSessionGeneration()
      let store = try await api.offlineStore()
      let page = try await store.sourceVersions(
        bookID: bookID, fileID: fileID, after: cursor, limit: 40)
      guard page.items.count <= 40, page.nextCursor == nil || page.nextCursor != cursor else {
        throw ConnectionError.invalidResponse
      }
      let repository = try await NativeAnnotationRepository.shared(api: api)
      let drafts = try await repository.recoveryDrafts(bookID: bookID).filter { draft in
        guard let fileID else { return true }
        return draft.operation.payload?.bookFileId == fileID || draft.item?.jumpFileId == fileID
      }
      var protectedIDs = protectedVersionIDs.intersection(Set(page.items.map(\.id)))
      var protectionError: String?
      for version in page.items where protectedIDs.contains(version.id) {
        do {
          if try await api.canRemoveSourceVersion(id: version.id) {
            protectedIDs.remove(version.id)
          }
        } catch {
          if case ConnectionError.expiredSession = error { throw error }
          if protectionError == nil { protectionError = error.localizedDescription }
        }
      }
      guard try await api.authenticatedSessionGeneration() == session else {
        throw ConnectionError.expiredSession
      }
      versions = page.items
      nextCursor = page.nextCursor
      self.drafts = drafts
      protectedVersionIDs = protectedIDs
      if !protectedIDs.isEmpty {
        error =
          protectionError
          ?? String(
            localized:
              "This version is needed by pending work or a recovery draft. Export it and resolve the saved work before removing it."
          )
      }
    } catch {
      self.error = error.localizedDescription
      if case ConnectionError.expiredSession = error {
        versions = []
        drafts = []
        releaseExport()
      }
    }
  }

  func next() {
    guard !isBusy, let nextCursor else { return }
    previousCursors.append(cursor)
    cursor = nextCursor
    reload()
  }

  func previous() {
    guard !isBusy, !previousCursors.isEmpty else { return }
    cursor = previousCursors.removeLast()
    reload()
  }

  func reload() { Task { await load() } }

  func prepareExport(_ version: OfflineSourceVersion) {
    guard !isBusy else { return }
    isBusy = true
    let operation = UUID()
    operationID = operation
    Task {
      error = nil
      defer { isBusy = false }
      do {
        let session = try await api.authenticatedSessionGeneration()
        let exported = try await api.offlineStore().exportSourceVersion(id: version.id)
        guard operationID == operation,
          try await api.authenticatedSessionGeneration() == session
        else {
          exported.remove()
          throw ConnectionError.expiredSession
        }
        artifact?.remove()
        artifact = exported
        exportedVersionID = version.id
      } catch { self.error = error.localizedDescription }
    }
  }

  func requestRemoval(_ version: OfflineSourceVersion) {
    guard !isBusy else { return }
    isBusy = true
    error = nil
    Task {
      defer { isBusy = false }
      do {
        guard try await api.canRemoveSourceVersion(id: version.id) else {
          protectedVersionIDs.insert(version.id)
          self.error = String(
            localized:
              "This version is needed by pending work or a recovery draft. Export it and resolve the saved work before removing it."
          )
          return
        }
        removal = version
        confirmsRemoval = true
      } catch { self.error = error.localizedDescription }
    }
  }

  func cancelRemoval() { removal = nil }

  func removeConfirmed() {
    guard !isBusy, let version = removal else { return }
    removal = nil
    isBusy = true
    Task {
      error = nil
      do {
        try await api.removeSourceVersion(id: version.id)
        if exportedVersionID == version.id { releaseExport() }
        isBusy = false
        await load()
      } catch {
        self.error = error.localizedDescription
        isBusy = false
      }
    }
  }

  func releaseExport() {
    operationID = UUID()
    artifact?.remove()
    artifact = nil
    exportedVersionID = nil
  }

  func close() {
    operationID = UUID()
    releaseExport()
  }
}
