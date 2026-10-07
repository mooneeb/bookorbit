import Foundation

struct BookTableColumnDefinition: Identifiable, Equatable {
  let id: String
  let label: String
  let defaultWidth: Double
  let minimumWidth: Double
  var defaultVisible = false
  var defaultPin: String?
  var isEditable = false
  var sortField: String?
  var lockField: String?
  var customField: CustomMetadataFieldSummary?
}

@MainActor enum BookTableColumnSchema {
  static let staticDefinitions: [BookTableColumnDefinition] = [
    .init(
      id: "lockRow", label: "Metadata locks", defaultWidth: 36, minimumWidth: 36, defaultPin: "left"
    ),
    .init(
      id: "cover", label: "Cover", defaultWidth: 48, minimumWidth: 48, defaultVisible: true,
      defaultPin: "left"),
    .init(id: "read", label: "Read", defaultWidth: 72, minimumWidth: 72),
    .init(
      id: "title", label: "Title", defaultWidth: 240, minimumWidth: 120, defaultVisible: true,
      isEditable: true, sortField: "title", lockField: "title"),
    .init(
      id: "authors", label: "Authors", defaultWidth: 180, minimumWidth: 100, defaultVisible: true,
      isEditable: true, sortField: "author", lockField: "authors"),
    .init(
      id: "seriesName", label: "Series", defaultWidth: 160, minimumWidth: 100, defaultVisible: true,
      isEditable: true, sortField: "series", lockField: "seriesName"),
    .init(
      id: "seriesIndex", label: "Series index", defaultWidth: 60, minimumWidth: 48,
      defaultVisible: true, isEditable: true, sortField: "seriesIndex", lockField: "seriesIndex"),
    .init(
      id: "publishedDate", label: "Published", defaultWidth: 132, minimumWidth: 108,
      sortField: "publishedDate", lockField: "publishedYear"),
    .init(
      id: "publishedYear", label: "Year", defaultWidth: 110, minimumWidth: 95, defaultVisible: true,
      isEditable: true, sortField: "publishedYear", lockField: "publishedYear"),
    .init(
      id: "language", label: "Language", defaultWidth: 100, minimumWidth: 72, isEditable: true,
      sortField: "language", lockField: "language"),
    .init(
      id: "rating", label: "Rating", defaultWidth: 110, minimumWidth: 88, defaultVisible: true,
      isEditable: true, sortField: "rating", lockField: "rating"),
    .init(
      id: "metadataScore", label: "Metadata Score", defaultWidth: 126, minimumWidth: 110,
      sortField: "metadataScore"),
    .init(
      id: "genres", label: "Genres", defaultWidth: 160, minimumWidth: 100, isEditable: true,
      lockField: "genres"),
    .init(
      id: "tags", label: "Tags", defaultWidth: 160, minimumWidth: 100, isEditable: true,
      lockField: "tags"),
    .init(
      id: "subtitle", label: "Subtitle", defaultWidth: 200, minimumWidth: 100, isEditable: true,
      lockField: "subtitle"),
    .init(
      id: "publisher", label: "Publisher", defaultWidth: 140, minimumWidth: 80, isEditable: true,
      sortField: "publisher", lockField: "publisher"),
    .init(
      id: "pageCount", label: "Pages", defaultWidth: 80, minimumWidth: 60, isEditable: true,
      sortField: "pageCount", lockField: "pageCount"),
    .init(id: "isbn13", label: "ISBN-13", defaultWidth: 150, minimumWidth: 100),
    .init(
      id: "narrators", label: "Narrators", defaultWidth: 180, minimumWidth: 100, isEditable: true,
      lockField: "narrators"),
    .init(
      id: "readingProgress", label: "Progress", defaultWidth: 120, minimumWidth: 80,
      sortField: "readProgress"),
    .init(
      id: "finishedAt", label: "Date Read", defaultWidth: 110, minimumWidth: 80,
      sortField: "finishedAt"),
    .init(
      id: "readStatus", label: "Status", defaultWidth: 130, minimumWidth: 100, defaultVisible: true,
      isEditable: true, sortField: "readStatus"),
    .init(
      id: "format", label: "Format", defaultWidth: 80, minimumWidth: 64, defaultVisible: true,
      sortField: "format"),
    .init(
      id: "fileSize", label: "File Size", defaultWidth: 100, minimumWidth: 84, defaultVisible: true,
      sortField: "fileSize"),
    .init(
      id: "updatedAt", label: "Updated", defaultWidth: 110, minimumWidth: 84, sortField: "updatedAt"
    ),
    .init(id: "addedAt", label: "Added", defaultWidth: 100, minimumWidth: 80, sortField: "addedAt"),
    .init(
      id: "actions", label: "Actions", defaultWidth: 48, minimumWidth: 48, defaultVisible: true,
      defaultPin: "right"),
  ]

  static let staticColumns = staticDefinitions.map(\.id)
  static let defaultLayout = TableLayoutState(
    columnOrder: staticColumns,
    hiddenColumns: staticDefinitions.filter { !$0.defaultVisible }.map(\.id),
    columnWidths: Dictionary(
      uniqueKeysWithValues: staticDefinitions.map { ($0.id, $0.defaultWidth) }))

  static func definitions(customFields: [CustomMetadataFieldSummary]) -> [BookTableColumnDefinition]
  {
    staticDefinitions
      + customFields.map {
        .init(
          id: "custom:\($0.id)", label: $0.label, defaultWidth: 160, minimumWidth: 80,
          isEditable: $0.type != "date", sortField: "custom:\($0.id)", customField: $0)
      }
  }

  static func definition(id: String, customFields: [CustomMetadataFieldSummary] = [])
    -> BookTableColumnDefinition?
  {
    if let definition = staticDefinitions.first(where: { $0.id == id }) { return definition }
    guard let fieldID = customFieldID(id),
      let field = customFields.first(where: { $0.id == fieldID })
    else { return nil }
    return .init(
      id: id, label: field.label, defaultWidth: 160, minimumWidth: 80,
      isEditable: field.type != "date", sortField: id, customField: field)
  }

  static func customFieldID(_ column: String) -> Int? {
    guard column.hasPrefix("custom:"), let id = Int(column.dropFirst(7)), id > 0,
      column == "custom:\(id)"
    else { return nil }
    return id
  }

  static func canEdit(_ book: BookCard, definition: BookTableColumnDefinition) -> Bool {
    guard definition.isEditable else { return false }
    if definition.id == "narrators",
      AudioStreamFormat.mimeTypes[primaryFile(book)?.format?.lowercased() ?? ""] == nil
    {
      return false
    }
    if let lock = definition.lockField, book.lockedFields.contains(lock) { return false }
    if let field = definition.customField {
      return book.customMetadata.contains { $0.fieldId == field.id && $0.type == field.type }
    }
    return true
  }

  static func text(_ book: BookCard, column: String) -> String {
    if let id = customFieldID(column) {
      guard let field = book.customMetadata.first(where: { $0.fieldId == id }) else {
        return "Not enabled"
      }
      if field.type == "date", case .string(let value) = field.value { return date(value) }
      return field.value.displayText
    }
    switch column {
    case "title": return book.title ?? "Untitled book"
    case "authors": return names(book.authors, empty: "Unknown author")
    case "seriesName": return book.seriesName ?? "No series"
    case "seriesIndex": return book.seriesIndex ?? "Not set"
    case "publishedDate": return date(book.publishedDate)
    case "publishedYear": return book.publishedYear.map(String.init) ?? "Not set"
    case "language": return book.language ?? "Not set"
    case "rating": return book.rating.map { "\(number($0)) of 5" } ?? "Not rated"
    case "metadataScore":
      return book.metadataScore.map { String(Int(min(100, max(0, $0)).rounded())) } ?? "Not scored"
    case "genres": return names(book.genres)
    case "tags": return names(book.tags)
    case "subtitle": return book.subtitle ?? "Not set"
    case "publisher": return book.publisher ?? "Not set"
    case "pageCount": return book.pageCount.map(String.init) ?? "Not set"
    case "isbn13": return book.isbn13 ?? "Not set"
    case "narrators": return names(book.narrators)
    case "readingProgress":
      return book.readingProgress.map { "\(number(min(100, max(0, $0))))%" } ?? "Not started"
    case "finishedAt": return date(ReadingDate.key(book.readStatus?.finishedAt, timeZone: .current))
    case "readStatus": return BookReadingDraft.label(book.readStatus?.status ?? "unread")
    case "format":
      var seen = Set<String>()
      let formats = displayFiles(book).compactMap { file -> String? in
        guard let format = file.format?.uppercased() else { return nil }
        let key =
          format == "EPUB" && file.mediaOverlay?.available == true ? "EPUB Read Along" : format
        return seen.insert(key).inserted ? key : nil
      }
      return names(formats, empty: "No files")
    case "fileSize":
      guard let bytes = primaryFile(book)?.sizeBytes, bytes.isFinite, bytes >= 0,
        bytes < Double(Int64.max)
      else { return "Not set" }
      return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    case "updatedAt": return date(book.updatedAt)
    case "addedAt": return date(book.addedAt)
    case "lockRow": return "\(book.lockedFields.count) metadata fields locked"
    case "cover": return book.hasCover ? "View cover" : "No cover"
    case "read": return contentFiles(book).isEmpty ? "No readable files" : "Read or listen"
    case "actions": return "Book actions"
    default: return "Unavailable column"
    }
  }

  static func contentFiles(_ book: BookCard) -> [BookFileRef] {
    displayFiles(book).filter { isReadable($0.format) }
  }

  static func displayFiles(_ book: BookCard) -> [BookFileRef] {
    book.files.filter {
      ($0.role == "content" || $0.role == "primary")
        && BookFileVocabulary.formats.contains($0.format?.lowercased() ?? "")
    }
  }

  static func primaryFile(_ book: BookCard) -> BookFileRef? {
    book.files.first { $0.role == "primary" } ?? contentFiles(book).first
  }

  static func isReadable(_ format: String?) -> Bool {
    guard let format = format?.lowercased() else { return false }
    return NativeEbookVocabulary.mimeTypes[format] != nil
      || AudioStreamFormat.mimeTypes[format] != nil
      || ["pdf", "cbz", "cbr", "cb7"].contains(format)
  }

  private static func names(_ values: [String], empty: String = "Not set") -> String {
    values.isEmpty ? empty : values.joined(separator: ", ")
  }

  private static func number(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...2)))
  }

  private static func date(_ value: String?) -> String {
    guard let value, !value.isEmpty else { return "Not set" }
    let key = String(value.prefix(10))
    guard ReadingDate.isValid(key) else { return value }
    let parser = DateFormatter()
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.timeZone = TimeZone(secondsFromGMT: 0)
    parser.dateFormat = "yyyy-MM-dd"
    guard let date = parser.date(from: key) else { return value }
    let display = DateFormatter()
    display.timeZone = TimeZone(secondsFromGMT: 0)
    display.dateStyle = .medium
    return display.string(from: date)
  }
}
