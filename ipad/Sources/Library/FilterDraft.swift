import Foundation

enum FilterValueKind: String, CaseIterable, Identifiable {
  case text = "Text"
  case number = "Number"
  case texts = "Text list"
  case numbers = "Number list"
  var id: String { rawValue }
}

struct FilterDraft: Identifiable, Equatable {
  var id = UUID()
  var isGroup = false
  var join = "AND"
  var children: [FilterDraft] = []
  var field = "title"
  var operation = "contains"
  var value = ""
  var valueTo = ""
  var valueKind = FilterValueKind.text
  var provider: String?

  static let valueless = Set([
    "isEmpty", "isNotEmpty", "isMissing", "isPresent", "isUnread", "isInProgress",
    "isFinished", "isLocked", "isUnlocked", "isUpNext", "isTrue", "isFalse",
  ])
  static let numericFields = Set([
    "seriesIndex", "publishedYear", "pageCount", "fileSize", "rating", "communityRating",
    "communityRatingCount", "metadataScore",
  ])

  var operators: [String] { FilterVocabulary.operators[field] ?? [] }
  var needsValue: Bool { !Self.valueless.contains(operation) }
  var nodeCount: Int { 1 + children.reduce(0) { $0 + $1.nodeCount } }

  static func group(_ filter: GroupRule? = nil) -> Self {
    var draft = Self(isGroup: true)
    if let filter {
      draft.join = filter.join
      draft.children = filter.rules.map(Self.init)
    }
    return draft
  }

  init() {}

  private init(isGroup: Bool) { self.isGroup = isGroup }

  init(_ node: FilterNode) {
    switch node {
    case .group(let group): self = Self.group(group)
    case .rule(let rule):
      field = rule.field
      operation = rule.operator
      provider = rule.provider
      switch rule.value {
      case .string(let text): value = text
      case .number(let number):
        valueKind = .number
        value = String(number)
      case .strings(let texts):
        valueKind = .texts
        value = texts.joined(separator: "\n")
      case .numbers(let numbers):
        valueKind = .numbers
        value = numbers.map { String($0) }.joined(separator: "\n")
      case nil: break
      }
      switch rule.valueTo {
      case .string(let text): valueTo = text
      case .number(let number): valueTo = String(number)
      case nil: break
      }
    }
  }

  mutating func changeField() {
    operation = operators.first ?? "contains"
    provider = nil
    value = ""
    valueTo = ""
    changeOperation()
  }

  mutating func changeOperation() {
    if ["includesAny", "includesAll", "excludesAll"].contains(operation) {
      valueKind = .texts
    } else if Self.numericFields.contains(field) || operation == "withinLast" {
      valueKind = .number
    } else {
      valueKind = .text
    }
  }

  func filter() throws -> GroupRule? {
    guard isGroup else { throw FilterDraftError.invalidGroup }
    guard nodeCount <= 65 else { throw FilterDraftError.tooManyRules }
    if children.isEmpty { return nil }
    guard case .group(let filter) = try node(depth: 1) else { throw FilterDraftError.invalidGroup }
    return filter
  }

  private func node(depth: Int) throws -> FilterNode {
    if isGroup {
      guard depth <= 5, !children.isEmpty else { throw FilterDraftError.invalidGroup }
      return .group(
        GroupRule(
          type: "group", join: join, rules: try children.map { try $0.node(depth: depth + 1) }))
    }
    var encodedValue: RuleValue?
    var encodedTo: RuleValueTo?
    if needsValue {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, trimmed.count <= 1000 else { throw FilterDraftError.missingValue }
      switch valueKind {
      case .text: encodedValue = .string(trimmed)
      case .number: encodedValue = .number(try number(trimmed))
      case .texts, .numbers:
        let values = trimmed.components(separatedBy: .newlines)
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !values.isEmpty, values.count <= 20 else { throw FilterDraftError.invalidList }
        encodedValue = valueKind == .texts ? .strings(values) : .numbers(try values.map(number))
      }
      if operation == "between" {
        let end = valueTo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !end.isEmpty else { throw FilterDraftError.missingValue }
        encodedTo = valueKind == .number ? .number(try number(end)) : .string(end)
      }
    }
    return .rule(
      Rule(
        type: "rule", field: field, operator: operation, value: encodedValue, valueTo: encodedTo,
        provider: provider))
  }

  private func number(_ text: String) throws -> Double {
    guard let number = Double(text), number.isFinite else { throw FilterDraftError.invalidNumber }
    return number
  }
}

enum FilterDraftError: LocalizedError {
  case missingValue, invalidNumber, invalidList, invalidGroup, tooManyRules
  var errorDescription: String? {
    switch self {
    case .missingValue: "Enter a value for every filter condition."
    case .invalidNumber: "Enter a valid number for the numeric filter."
    case .invalidList: "Enter between one and twenty values, one per line."
    case .invalidGroup: "Each filter group needs a condition. Use at most five group levels."
    case .tooManyRules: "Use at most 64 filter conditions and groups."
    }
  }
}

func queryFieldLabel(_ value: String) -> String {
  value.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
    .capitalized
}
