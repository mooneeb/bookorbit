import SwiftUI

struct BookAddedAtSection: View {
  let api: BookOrbitAPI
  let book: BookDetail
  let userID: Int
  let canEditMetadata: Bool
  let acknowledged: (BookDetail) -> Void
  @State private var timeZone: TimeZone?
  @State private var hasMetadataPermission = false
  @State private var editor: BookAddedAtModel?
  @State private var error: String?
  @State private var isLoading = true
  @State private var isAttached = true
  @State private var operation = UUID()

  var body: some View {
    Section("Added date") {
      if let timeZone, let date = BookAddedAtDate.key(book.addedAt, timeZone: timeZone) {
        Text(date).accessibilityIdentifier("bookAddedAtDate")
        Text("Account time zone: \(timeZone.identifier)").font(.footnote)
          .fixedSize(horizontal: false, vertical: true)
          .foregroundStyle(.secondary).accessibilityIdentifier("bookAddedAtTimeZone")
      } else if isLoading {
        ProgressView("Loading added date…")
      }
      if let error {
        Text(error).fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("bookAddedAtLoadError")
        Button(action: retry) {
          Text("Reload added date").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        .disabled(isLoading).accessibilityIdentifier("bookAddedAtLoadRetry")
      }
      if canEditMetadata, hasMetadataPermission, userID > 0, timeZone != nil {
        Button(action: edit) {
          Text("Edit added date").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        .disabled(isLoading).accessibilityIdentifier("editAddedAt")
      }
    }
    .task { await load(refreshBook: false) }
    .fullScreenCover(item: $editor, onDismiss: refresh) { editor in
      BookAddedAtEditorView(model: editor, saved: saved)
    }
    .onDisappear {
      if editor == nil {
        isAttached = false
        operation = UUID()
      }
    }
  }

  private func edit() {
    guard isAttached, canEditMetadata, hasMetadataPermission, !isLoading, userID > 0 else {
      return
    }
    editor = BookAddedAtModel(api: api, book: book, userID: userID)
  }

  private func saved(_ source: BookAddedAtModel, _ saved: BookDetail) {
    guard isAttached, editor?.id == source.id, source.userID == userID,
      saved.id == book.id, saved.libraryId == book.libraryId
    else { return }
    acknowledged(saved)
  }

  private func retry() { Task { await load(refreshBook: false) } }
  private func refresh() { Task { await load(refreshBook: true) } }

  private func load(refreshBook: Bool) async {
    guard isAttached else { return }
    let operation = UUID()
    self.operation = operation
    isLoading = true
    error = nil
    hasMetadataPermission = false
    defer { if self.operation == operation { isLoading = false } }
    do {
      let session = try await api.authenticatedSessionGeneration()
      let user: AuthUser = try await api.boundedJSON(
        "auth/me", session: session, expectedStatus: 200)
      guard isAttached, self.operation == operation else { return }
      guard user.id == userID else { throw ConnectionError.expiredSession }
      let zone = BookAddedAtDate.timeZone(user.settings.timezone)
      timeZone = zone
      hasMetadataPermission = user.hasPermission(.libraryEditMetadata)
      guard BookAddedAtDate.key(book.addedAt, timeZone: zone) != nil else {
        throw ConnectionError.invalidResponse
      }
      if refreshBook {
        let current: BookDetail = try await api.boundedJSON(
          "books/\(book.id)", session: session, expectedStatus: 200)
        guard isAttached, self.operation == operation,
          (try? await api.authenticatedSessionGeneration()) == session
        else { return }
        guard current.id == book.id, current.libraryId == book.libraryId else {
          throw ConnectionError.invalidResponse
        }
        acknowledged(current)
      }
    } catch {
      guard isAttached, self.operation == operation, !Task.isCancelled else { return }
      timeZone = nil
      hasMetadataPermission = false
      self.error = "Could not load the added date. \(error.localizedDescription)"
    }
  }
}
