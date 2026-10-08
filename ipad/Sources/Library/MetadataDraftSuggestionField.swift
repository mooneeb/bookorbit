import Foundation

enum MetadataDraftSuggestionField: String, Sendable {
  case authors, narrators, seriesName, publisher, genres, tags, language

  var endpoint: String {
    switch self {
    case .seriesName: "series"
    case .publisher: "publishers"
    case .language: "languages"
    default: rawValue
    }
  }

  var isMultiple: Bool {
    switch self {
    case .authors, .narrators, .genres, .tags: true
    default: false
    }
  }

  var maximumNameLength: Int {
    switch self {
    case .genres, .tags: 200
    case .language: 100
    default: 500
    }
  }

  func adding(_ name: String, to text: String) -> String {
    guard isMultiple else { return name }
    let names = text.components(separatedBy: .newlines).map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !names.contains(name) else { return text }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return name }
    return text + (text.last?.isNewline == true ? "" : "\n") + name
  }
}

struct MetadataDraftSuggestionScope: Identifiable {
  let id = UUID()
  let bookID: Int
  let draftID: UUID
  let extraDraftID: ObjectIdentifier
  let field: MetadataDraftSuggestionField
  let entryID: UUID?
  let initialQuery: String
}
