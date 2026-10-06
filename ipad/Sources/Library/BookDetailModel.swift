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

  init(api: BookOrbitAPI, bookID: Int) {
    self.api = api
    self.bookID = bookID
  }

  func load() async {
    error = nil
    do { book = try await api.send("books/\(bookID)") } catch {
      self.error = error.localizedDescription
    }
  }

  func beginEditing() {
    guard let book else { return }
    error = nil
    draft = MetadataDraft(book: book)
  }

  func acknowledgeReading(_ saved: BookDetail) {
    guard saved.id == bookID else { return }
    book = saved
  }

  func saveMetadata() async {
    guard let book, let draft, draft.isValid, !isSaving else { return }
    isSaving = true
    error = nil
    defer { isSaving = false }
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
      self.book = try await api.send(
        "books/\(bookID)/metadata-and-locks", method: "PATCH", body: JSONEncoder().encode(payload))
      if let saved = self.book {
        draft.extra.acknowledge(saved)
        draft.customFields = saved.customMetadata.map(CustomMetadataDraft.init)
      }
      for medium in [CoverMedium.ebook, .audio] {
        if let url = draft.coverURLs[medium] {
          do {
            try await api.sendEmpty(
              "books/\(bookID)/cover/from-url",
              body: JSONEncoder().encode(UploadCoverFromUrlPayload(url: url)),
              query: [URLQueryItem(name: "medium", value: medium.rawValue)])
            draft.coverURLs[medium] = nil
          } catch {
            self.error =
              "Metadata saved. \(medium.label) could not be saved. Your selection is kept. \(error.localizedDescription)"
            return
          }
          do {
            self.book = try await api.send("books/\(bookID)")
          } catch {
            self.error =
              "Metadata and \(medium.label.lowercased()) saved. Book details could not be refreshed. Retry to reload them. \(error.localizedDescription)"
            return
          }
        }
      }
      self.draft = nil
    } catch { self.error = error.localizedDescription }
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
