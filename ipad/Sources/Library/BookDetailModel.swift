import Foundation
import Observation

@MainActor @Observable
final class BookDetailModel {
  let api: BookOrbitAPI
  let bookID: Int
  private(set) var book: BookDetail?
  private(set) var isSaving = false
  var error: String?
  var draft: MetadataDraft?
  private(set) var fileWrite: BookWriteAndRenameModel?
  private var detailSession: UUID?
  private var loadID = UUID()
  private var isUnavailable = false
  private var deletionSession: UUID?
  private var moveSession: UUID?
  private var fileSession: UUID?

  init(api: BookOrbitAPI, bookID: Int) {
    self.api = api
    self.bookID = bookID
  }

  func load() async {
    guard !isUnavailable else { return }
    let loadID = UUID()
    self.loadID = loadID
    error = nil
    do {
      if detailSession == nil { detailSession = try await api.authenticatedSessionGeneration() }
      let result: BookDetail = try await api.boundedJSON(
        "books/\(bookID)", session: deletionSession ?? moveSession ?? fileSession ?? detailSession)
      guard self.loadID == loadID, !isUnavailable else { return }
      guard result.id == bookID else { throw ConnectionError.invalidResponse }
      book = result
      beginWritingFiles()
      await fileWrite?.inspectStatus(current: result)
    } catch {
      guard self.loadID == loadID, !isUnavailable else { return }
      self.error = error.localizedDescription
    }
  }

  func discardDeletedBook() {
    loadID = UUID()
    isUnavailable = true
    book = nil
    draft = nil
    error = nil
    fileWrite?.detach()
  }

  func reconcileDeletion(session: UUID) async -> BookDeletionOutcome? {
    deletionSession = session
    let loadID = UUID()
    self.loadID = loadID
    book = nil
    error = "The deletion outcome has not been confirmed. Reload this book when connected."
    do {
      let result: BookDetail = try await api.boundedJSON("books/\(bookID)", session: session)
      guard self.loadID == loadID, !isUnavailable else { return nil }
      guard result.id == bookID else { throw ConnectionError.invalidResponse }
      book = result
      error = nil
    } catch {
      guard self.loadID == loadID, !isUnavailable else { return nil }
      guard (try? await api.authenticatedSessionGeneration()) == session else { return nil }
      if case ConnectionError.http(404) = error { return .unavailable }
      if case ConnectionError.denied = error { return .unavailable }
      self.error =
        "The deletion outcome is still unknown. Reload this book when connected. \(error.localizedDescription)"
    }
    return nil
  }

  func reconcileMove(session: UUID) async {
    moveSession = session
    loadID = UUID()
    book = nil
    draft = nil
    await load()
    if book == nil {
      error =
        "This book's current status could not be loaded after the move. It may have changed or become unavailable to your account. \(error ?? "")"
    }
  }

  func beginEditing() {
    guard let book else { return }
    error = nil
    draft = MetadataDraft(book: book)
  }

  func resetMetadata() {
    guard let draft, !isSaving else { return }
    draft.reset()
    error = nil
  }

  func awaitFileReadback(session: UUID) {
    guard !isUnavailable else { return }
    fileSession = session
    loadID = UUID()
    book = nil
    draft = nil
    error = "The file change is awaiting current server details. Reload when connected."
  }

  func acknowledgeFiles(_ saved: BookDetail) {
    guard saved.id == bookID, !isUnavailable else { return }
    loadID = UUID()
    error = nil
    book = saved
  }

  var fileWriteBlocksMetadata: Bool {
    fileWrite?.isBusy == true || fileWrite?.hasUnconfirmedWrite == true
  }

  func beginWritingFiles() {
    guard !isUnavailable, !isSaving, let detailSession else { return }
    if fileWrite == nil {
      fileWrite = BookWriteAndRenameModel(
        api: api, bookID: bookID, session: detailSession,
        willWrite: { [weak self] session in self?.awaitFileWriteReadback(session: session) },
        readBack: { [weak self] book, session in
          self?.acknowledgeFileWrite(book, session: session)
        })
    }
  }

  func detachFileWrite() { fileWrite?.detach() }

  private func awaitFileWriteReadback(session: UUID) {
    guard session == detailSession, !isUnavailable else { return }
    loadID = UUID()
    book = nil
    error = "Source-file work was requested. Reload this book to see its current files."
  }

  private func acknowledgeFileWrite(_ book: BookDetail, session: UUID) {
    guard book.id == bookID, session == detailSession, !isUnavailable else { return }
    loadID = UUID()
    self.book = book
    error = nil
  }

  func acknowledgeReading(_ saved: BookDetail) {
    guard saved.id == bookID, !isUnavailable else { return }
    book = saved
  }

  func acknowledgeAddedAt(_ saved: BookDetail) {
    guard saved.id == bookID, saved.libraryId == book?.libraryId, !isUnavailable else { return }
    loadID = UUID()
    book = saved
  }

  func acknowledgeReadAloudSync(
    _ saved: BookDetail, session: UUID, isCurrent: @MainActor () -> Bool
  ) async {
    guard (try? await api.authenticatedSessionGeneration()) == session,
      isCurrent(),
      saved.id == bookID, !isUnavailable, var current = book,
      current.files.sorted(by: { $0.id < $1.id }) == saved.files.sorted(by: { $0.id < $1.id })
    else { return }
    current.readAloudSync = saved.readAloudSync
    loadID = UUID()
    book = current
  }

  func saveMetadata() async {
    guard let book, let draft, draft.isValid, !isSaving, !fileWriteBlocksMetadata else { return }
    isSaving = true
    error = nil
    defer { isSaving = false }
    var savedMedia: [CoverMedium] = []
    do {
      var metadata = BookMetadataUpdatePayload(
        title: update(draft.title, original: book.title),
        subtitle: update(draft.subtitle, original: book.subtitle),
        description: update(draft.description, original: book.description),
        publisher: update(draft.publisher, original: book.publisher),
        publishedYear: updateNumber(draft.publishedYear, original: book.publishedYear),
        language: update(draft.language, original: book.language),
        pageCount: updateNumber(draft.pageCount, original: book.pageCount),
        isbn13: update(draft.isbn13, original: book.isbn13),
        isbn10: update(draft.isbn10, original: book.isbn10),
        genres: updateNames(draft.genres, original: book.genres),
        tags: updateNames(draft.tags, original: book.tags),
        publishedDate: update(draft.publishedDate, original: book.publishedDate),
        authors: updateNames(draft.authors, original: book.authors.map(\.name)),
        customMetadata: draft.customUpdates.isEmpty ? nil : draft.customUpdates)
      draft.extra.write(to: &metadata)
      let payload = BookMetadataAndLocksUpdatePayload(
        metadata: metadata, lockedFields: draft.lockedFields.sorted())
      let pendingMedia = [CoverMedium.ebook, .audio].filter { draft.coverURLs[$0] != nil }
      for medium in pendingMedia where !book.lockedFields.contains(medium.lockField) {
        guard
          await saveCoverSelection(
            medium, draft: draft, metadataSaved: false, savedMedia: savedMedia)
        else { return }
        savedMedia.append(medium)
      }
      self.book = try await api.send(
        "books/\(bookID)/metadata-and-locks", method: "PATCH", body: JSONEncoder().encode(payload))
      if let saved = self.book {
        draft.acknowledge(saved)
      }
      for medium in pendingMedia where draft.coverURLs[medium] != nil {
        guard self.book?.lockedFields.contains(medium.lockField) == false else {
          error =
            "\(savedCoverSummary(savedMedia))Metadata saved. Your \(medium.label.lowercased()) selection is kept. Unlock its cover field and save again."
          return
        }
        guard
          await saveCoverSelection(
            medium, draft: draft, metadataSaved: true, savedMedia: savedMedia)
        else { return }
        savedMedia.append(medium)
      }
      self.draft = nil
    } catch {
      self.error =
        savedMedia.isEmpty
        ? error.localizedDescription
        : "\(savedCoverSummary(savedMedia))Metadata has not been saved. Your metadata changes are kept. \(error.localizedDescription)"
    }
  }

  private func saveCoverSelection(
    _ medium: CoverMedium, draft: MetadataDraft, metadataSaved: Bool, savedMedia: [CoverMedium]
  ) async -> Bool {
    guard let url = draft.coverURLs[medium] else { return true }
    do {
      try await api.sendEmpty(
        "books/\(bookID)/cover/from-url",
        body: JSONEncoder().encode(UploadCoverFromUrlPayload(url: url)),
        query: [URLQueryItem(name: "medium", value: medium.rawValue)])
      draft.coverURLs[medium] = nil
    } catch {
      let metadataStatus = metadataSaved ? "Metadata saved." : "Metadata has not been saved."
      self.error =
        "\(savedCoverSummary(savedMedia))\(metadataStatus) \(medium.label) could not be saved. Your selection is kept. \(error.localizedDescription)"
      return false
    }
    do {
      self.book = try await api.send("books/\(bookID)")
    } catch {
      let savedStatus =
        metadataSaved
        ? "Metadata and \(medium.label.lowercased()) saved."
        : "\(medium.label) saved. Metadata has not been saved."
      self.error =
        "\(savedCoverSummary(savedMedia))\(savedStatus) Book details could not be refreshed. Retry to reload them. \(error.localizedDescription)"
      return false
    }
    return true
  }

  private func savedCoverSummary(_ media: [CoverMedium]) -> String {
    media.map { "\($0.label) saved. " }.joined()
  }

  private func update(_ text: String, original: String?) -> FieldUpdate<String>? {
    guard text != (original ?? "") else { return nil }
    return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .clear : .set(text)
  }

  private func updateNumber(_ text: String, original: Int?) -> FieldUpdate<Int>? {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value != original.map(String.init) ?? "" else { return nil }
    return Int(value).map(FieldUpdate.set) ?? .clear
  }

  private func updateNames(_ text: String, original: [String]) -> [String]? {
    let names = text.components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return names == original ? nil : names
  }
}

@MainActor @Observable
final class MetadataDraft: Identifiable {
  let id = UUID()
  private var original: BookDetail
  private(set) var resetGeneration = 0
  var title: String
  var subtitle: String
  var description: String
  var publisher: String
  var publishedDate: String
  var publishedYear: String
  var pageCount: String
  var language: String
  var isbn10: String
  var isbn13: String
  var authors: String
  var genres: String
  var tags: String
  var customFields: [CustomMetadataDraft]
  var extra: MetadataExtraDraft
  var coverURLs: [CoverMedium: String] = [:]
  var lockedFields: Set<String>

  init(book: BookDetail) {
    original = book
    title = book.title ?? ""
    subtitle = book.subtitle ?? ""
    description = book.description ?? ""
    publisher = book.publisher ?? ""
    publishedDate = book.publishedDate ?? ""
    publishedYear = book.publishedYear.map(String.init) ?? ""
    pageCount = book.pageCount.map(String.init) ?? ""
    language = book.language ?? ""
    isbn10 = book.isbn10 ?? ""
    isbn13 = book.isbn13 ?? ""
    authors = book.authors.map(\.name).joined(separator: "\n")
    genres = book.genres.joined(separator: "\n")
    tags = book.tags.joined(separator: "\n")
    customFields = book.customMetadata.map(CustomMetadataDraft.init)
    extra = MetadataExtraDraft(book: book)
    lockedFields = Set(book.lockedFields)
  }

  var isValid: Bool { validationMessage == nil }
  var customUpdates: [CustomMetadataBookValueInput] { customFields.compactMap(\.update) }
  var areAllLocked: Bool { Set(MetadataVocabulary.lockFields).isSubset(of: lockedFields) }

  func lockAll() {
    lockedFields = Set(MetadataVocabulary.lockFields)
  }

  func unlockAll() {
    lockedFields = []
  }

  func acknowledge(_ book: BookDetail) {
    original = book
    extra.acknowledge(book)
    customFields = book.customMetadata.map(CustomMetadataDraft.init)
  }

  func reset() {
    let restored = MetadataDraft(book: original)
    title = restored.title
    subtitle = restored.subtitle
    description = restored.description
    publisher = restored.publisher
    publishedDate = restored.publishedDate
    publishedYear = restored.publishedYear
    pageCount = restored.pageCount
    language = restored.language
    isbn10 = restored.isbn10
    isbn13 = restored.isbn13
    authors = restored.authors
    genres = restored.genres
    tags = restored.tags
    customFields = restored.customFields
    extra = restored.extra
    lockedFields = restored.lockedFields
    coverURLs = [:]
    resetGeneration += 1
  }

  var isPublicationLocked: Bool {
    lockedFields.contains("publishedYear")
  }

  func setPublishedDate(_ value: String) {
    publishedDate = value
    if Self.isValidDate(value) { publishedYear = String(value.prefix(4)) }
  }

  func setPublishedYear(_ value: String) {
    if value != publishedYear { publishedDate = "" }
    publishedYear = value
  }

  var validationMessage: String? {
    if let message = customFields.compactMap(\.validationMessage).first { return message }
    if let message = extra.validationMessage { return message }
    if title.unicodeScalars.count > 1000 || subtitle.unicodeScalars.count > 1000 {
      return "Title and subtitle must be no longer than 1,000 characters."
    }
    if publisher.unicodeScalars.count > 500 {
      return "Publisher must be no longer than 500 characters."
    }
    if language.unicodeScalars.count > 100 {
      return "Language must be no longer than 100 characters."
    }
    if isbn10.unicodeScalars.count > 10 || isbn13.unicodeScalars.count > 13 {
      return "ISBN-10 and ISBN-13 must be no longer than 10 and 13 characters."
    }
    if Self.hasExcessiveName(authors, limit: 500) {
      return "Each author must be no longer than 500 characters."
    }
    if Self.hasExcessiveName(genres, limit: 200) {
      return "Each genre must be no longer than 200 characters."
    }
    if Self.hasExcessiveName(tags, limit: 200) {
      return "Each tag must be no longer than 200 characters."
    }
    if !Self.isValidNumber(publishedYear, range: 1000...2200) {
      return "Published year must be a whole number from 1000 to 2200, or blank."
    }
    if !Self.isValidNumber(pageCount, range: 1...Int(Int32.max)) {
      return "Page count must be a positive whole number, or blank."
    }
    if !publishedDate.isEmpty && !Self.isValidDate(publishedDate) {
      return "Published date must be a real date in YYYY-MM-DD format, from 1000 to 2200."
    }
    return nil
  }

  private static func hasExcessiveName(_ text: String, limit: Int) -> Bool {
    text.components(separatedBy: .newlines).contains {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count > limit
    }
  }

  private static func isValidNumber(_ text: String, range: ClosedRange<Int>) -> Bool {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty { return true }
    guard let number = Int(value) else { return false }
    return range.contains(number)
  }

  private static func isValidDate(_ text: String) -> Bool {
    guard text.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil,
      let year = Int(text.prefix(4)), (1000...2200).contains(year)
    else { return false }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    guard let date = formatter.date(from: text) else { return false }
    return formatter.string(from: date) == text
  }
}
