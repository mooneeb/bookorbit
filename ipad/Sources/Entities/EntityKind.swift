import Foundation

enum EntityKind: String, CaseIterable, Identifiable {
  case author, series, publisher, tag, genre, narrator, language
  var id: String { rawValue }
  var title: String {
    switch self {
    case .author: "Authors"
    case .series: "Series"
    case .publisher: "Publishers"
    case .tag: "Tags"
    case .genre: "Genres"
    case .narrator: "Narrators"
    case .language: "Languages"
    }
  }
  var isInline: Bool { self == .publisher || self == .language }
  var canSplit: Bool { !isInline && self != .series }
  var canDetach: Bool { canSplit }
}

extension StringOrNumber {
  var entityPath: String {
    switch self {
    case .number(let value): Int(exactly: value).map(String.init) ?? ""
    case .string(let value): value
    }
  }
  var entityNumber: Int? {
    if case .number(let value) = self { return Int(exactly: value) }
    return nil
  }
  var entityValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }
}
