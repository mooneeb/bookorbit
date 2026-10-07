import Foundation
import Observation

@MainActor @Observable
final class BookTableCellEditorModel: Identifiable {
  let id = UUID()
  let api: BookOrbitAPI
  let book: BookCard
  let column: BookTableColumnDefinition
  var text: String
  var choice: String
  var custom: CustomMetadataDraft?
  let suggestions: BookTableSuggestionsModel?
  private(set) var isSaving = false
  private(set) var isComplete = false
  private(set) var error: String?
  private(set) var savedBook: BookDetail?
  private(set) var savedStatus: UserBookStatus?
  private let originalText: String
  private let originalChoice: String

  init(api: BookOrbitAPI, book: BookCard, column: BookTableColumnDefinition) {
    self.api = api
    self.book = book
    self.column = column
    suggestions = BookTableSuggestionsModel.make(api: api, column: column.id)
    let value: String
    switch column.id {
    case "title": value = book.title ?? ""
    case "subtitle": value = book.subtitle ?? ""
    case "authors": value = book.authors.joined(separator: "\n")
    case "genres": value = book.genres.joined(separator: "\n")
    case "tags": value = book.tags.joined(separator: "\n")
    case "narrators": value = book.narrators.joined(separator: "\n")
    case "seriesName": value = book.seriesName ?? ""
    case "seriesIndex": value = book.seriesIndex ?? ""
    case "publishedYear": value = book.publishedYear.map(String.init) ?? ""
    case "language": value = book.language ?? ""
    case "publisher": value = book.publisher ?? ""
    case "pageCount": value = book.pageCount.map(String.init) ?? ""
    default: value = ""
    }
    text = value
    originalText = value
    let initialChoice =
      column.id == "readStatus"
      ? book.readStatus?.status ?? "unread" : book.rating.map { String(Int($0)) } ?? "unset"
    choice = initialChoice
    originalChoice = initialChoice
    if let fieldID = column.customField?.id,
      let field = book.customMetadata.first(where: { $0.fieldId == fieldID })
    {
      custom = CustomMetadataDraft(field: field)
    }
  }

  var isNames: Bool { ["authors", "genres", "tags", "narrators"].contains(column.id) }
  var suggestionQuery: String {
    isNames ? text.components(separatedBy: .newlines).last ?? "" : text
  }
  var hasChanges: Bool {
    if let custom { return custom.update != nil }
    if ["rating", "readStatus"].contains(column.id) { return choice != originalChoice }
    return text != originalText
  }

  var validationMessage: String? {
    if !BookTableColumnSchema.canEdit(book, definition: column) {
      return "This field cannot be edited. Unlock it or reload the book."
    }
    if let custom { return custom.validationMessage }
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    switch column.id {
    case "title", "subtitle":
      if value.unicodeScalars.count > 1000 { return "Enter at most 1,000 characters." }
    case "publisher", "seriesName":
      if value.unicodeScalars.count > 500 { return "Enter at most 500 characters." }
    case "language":
      if value.unicodeScalars.count > 100 { return "Enter at most 100 characters." }
    case "publishedYear":
      if !value.isEmpty && Int(value).map({ (1000...2200).contains($0) }) != true {
        return "Enter a whole year from 1000 to 2200, or clear the value."
      }
    case "pageCount":
      if !value.isEmpty && Int(value).map({ (1...Int(Int32.max)).contains($0) }) != true {
        return "Enter a positive whole page count, or clear the value."
      }
    case "seriesIndex":
      if !value.isEmpty
        && (value.count > 20
          || value.range(of: "^[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) == nil)
      {
        return "Enter a nonnegative decimal with at most 20 characters, or clear the value."
      }
    case "rating":
      if choice != "unset" && Int(choice).map({ (1...5).contains($0) }) != true {
        return "Choose a rating from 1 to 5, or Not rated."
      }
    case "readStatus":
      if !BookReadingVocabulary.statuses.contains(choice) { return "Choose a reading status." }
    default: break
    }
    if isNames {
      let limit = ["genres", "tags"].contains(column.id) ? 200 : 500
      if names.contains(where: { $0.unicodeScalars.count > limit }) {
        return "Each name must have at most \(limit) characters."
      }
    }
    return nil
  }

  func clear() {
    if var field = custom {
      field.text = ""
      field.boolean = "unset"
      custom = field
    } else if column.id == "rating" {
      choice = "unset"
    } else {
      text = ""
    }
  }

  func chooseSuggestion(_ name: String) {
    if isNames {
      var lines = text.components(separatedBy: .newlines)
      if !lines.isEmpty { lines.removeLast() }
      text = (lines + [name]).joined(separator: "\n")
    } else {
      text = name
    }
    suggestions?.clear(selected: name)
  }

  func save() async {
    guard !isSaving, !isComplete, hasChanges, validationMessage == nil else { return }
    isSaving = true
    error = nil
    defer { isSaving = false }
    do {
      if column.id == "readStatus" {
        let result: UserBookStatus = try await api.boundedJSON(
          "books/\(book.id)/status", method: "PATCH",
          body: JSONEncoder().encode(SetBookReadingStatusPayload(status: choice)))
        guard BookReadingVocabulary.statuses.contains(result.status) else {
          throw ConnectionError.invalidResponse
        }
        savedStatus = result
      } else {
        let result: BookDetail = try await api.boundedJSON(
          "books/\(book.id)/metadata", method: "PATCH", body: JSONEncoder().encode(metadataPayload))
        guard result.id == book.id else { throw ConnectionError.invalidResponse }
        savedBook = result
      }
      isComplete = true
    } catch {
      self.error =
        "Your change could not be confirmed. Your draft is kept. \(error.localizedDescription)"
    }
  }

  private var names: [String] {
    text.components(separatedBy: .newlines).map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }
  }

  private var metadataPayload: BookMetadataUpdatePayload {
    var payload = BookMetadataUpdatePayload()
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let string: FieldUpdate<String> = value.isEmpty ? .clear : .set(value)
    switch column.id {
    case "title": payload.title = string
    case "subtitle": payload.subtitle = string
    case "authors": payload.authors = names
    case "genres": payload.genres = names
    case "tags": payload.tags = names
    case "narrators": payload.audioMetadata = .init(narrators: names)
    case "seriesName": payload.seriesName = string
    case "seriesIndex": payload.seriesIndex = string
    case "publishedYear":
      payload.publishedYear = Int(value).map(FieldUpdate.set) ?? .clear
      payload.publishedDate = .clear
    case "language": payload.language = string
    case "publisher": payload.publisher = string
    case "pageCount": payload.pageCount = Int(value).map(FieldUpdate.set) ?? .clear
    case "rating": payload.rating = Double(choice).map(FieldUpdate.set) ?? .clear
    default:
      if let update = custom?.update { payload.customMetadata = [update] }
    }
    return payload
  }
}
