import CoreFoundation
import Foundation

enum NativeViewBackupValidation {
  static func decode(_ data: Data) throws -> TableViewBackup {
    guard data.count <= NativeViewBackupFile.byteLimit else { throw NativeViewBackupError.fileSize }
    let raw: Any
    do { raw = try JSONSerialization.jsonObject(with: data) } catch {
      throw NativeViewBackupError.invalidFile
    }
    let root = try object(
      raw, required: ["version", "presets", "savedViews"], optional: [], path: "backup")
    guard let version = root["version"] as? NSNumber,
      CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1
    else { throw NativeViewBackupError.version }
    guard let presets = root["presets"] as? [Any], let views = root["savedViews"] as? [Any] else {
      throw NativeViewBackupError.invalidFile
    }
    guard presets.count <= 100, views.count <= 100 else { throw NativeViewBackupError.entries }
    for (index, preset) in presets.enumerated() {
      let path = "presets[\(index)]"
      let entry = try object(
        preset, required: ["id", "name", "layout"],
        optional: ["sort", "isBuiltIn", "favorite"], path: path)
      try layout(entry["layout"], path: path + ".layout")
      if let sort = entry["sort"] { try sorts(sort, path: path + ".sort") }
    }
    for (index, view) in views.enumerated() {
      let path = "savedViews[\(index)]"
      let entry = try object(
        view, required: ["id", "name", "layout", "sort"],
        optional: ["filter", "favorite"], path: path)
      try layout(entry["layout"], path: path + ".layout")
      try sorts(entry["sort"], path: path + ".sort")
      if let filter = entry["filter"] {
        var count = 0
        try group(filter, path: path + ".filter", depth: 1, count: &count)
      }
    }
    do { return try JSONDecoder().decode(TableViewBackup.self, from: data) } catch {
      throw NativeViewBackupError.invalidFile
    }
  }

  static func validate(sort: [SortSpec]) throws {
    guard sort.count <= 5,
      sort.allSatisfy({
        (SortVocabulary.fields.contains($0.field) || isCustom($0.field))
          && ["asc", "desc"].contains($0.dir)
      })
    else { throw NativeViewBackupError.sort }
  }

  @MainActor static func validate(layout: TableLayoutState) throws {
    try BookTableLayout.validate(layout)
    let groups = [
      layout.columnOrder, layout.hiddenColumns, Array(layout.columnWidths.keys),
      Array((layout.pinnedColumns ?? [:]).keys),
    ]
    for columns in groups {
      let canonical = columns.map { BookTableLayout.canonicalID($0) }
      guard Set(canonical).count == canonical.count else { throw NativeViewBackupError.layout }
    }
  }

  static func validate(filter: GroupRule) throws {
    var pending = [(filter, 1)]
    var count = 1
    while let (group, depth) = pending.popLast() {
      guard group.type == "group", ["AND", "OR"].contains(group.join),
        depth <= 5, !group.rules.isEmpty
      else { throw NativeViewBackupError.filter }
      for node in group.rules {
        count += 1
        guard count <= 65 else { throw NativeViewBackupError.filter }
        switch node {
        case .group(let child): pending.append((child, depth + 1))
        case .rule(let rule): try validate(rule: rule)
        }
      }
    }
  }

  private static func object(
    _ raw: Any?, required: Set<String>, optional: Set<String>, path: String
  ) throws -> [String: Any] {
    guard let raw = raw as? [String: Any], required.isSubset(of: Set(raw.keys)),
      !raw.values.contains(where: { $0 is NSNull })
    else { throw NativeViewBackupError.invalidFile }
    if let unsupported = Set(raw.keys).subtracting(required.union(optional)).sorted().first {
      throw NativeViewBackupError.unsupportedField(path + "." + String(unsupported.prefix(80)))
    }
    return raw
  }

  private static func layout(_ raw: Any?, path: String) throws {
    _ = try object(
      raw, required: ["columnOrder", "hiddenColumns", "columnWidths"],
      optional: ["pinnedColumns"], path: path)
  }

  private static func sorts(_ raw: Any?, path: String) throws {
    guard let raw = raw as? [Any], raw.count <= 5 else { throw NativeViewBackupError.sort }
    for (index, sort) in raw.enumerated() {
      _ = try object(sort, required: ["field", "dir"], optional: [], path: "\(path)[\(index)]")
    }
  }

  private static func group(_ raw: Any, path: String, depth: Int, count: inout Int) throws {
    count += 1
    guard depth <= 5, count <= 65 else { throw NativeViewBackupError.filter }
    let raw = try object(raw, required: ["type", "join", "rules"], optional: [], path: path)
    guard raw["type"] as? String == "group", let rules = raw["rules"] as? [Any],
      !rules.isEmpty, rules.count <= 64
    else { throw NativeViewBackupError.filter }
    for (index, node) in rules.enumerated() {
      let childPath = "\(path).rules[\(index)]"
      if (node as? [String: Any])?["type"] as? String == "group" {
        try group(node, path: childPath, depth: depth + 1, count: &count)
      } else {
        count += 1
        guard count <= 65 else { throw NativeViewBackupError.filter }
        _ = try object(
          node, required: ["type", "field", "operator"],
          optional: ["value", "valueTo", "provider"], path: childPath)
      }
    }
  }

  private static func isCustom(_ field: String) -> Bool {
    field.range(of: "^custom:[1-9][0-9]{0,8}$", options: .regularExpression) != nil
  }

  private static func validate(rule: Rule) throws {
    let custom = isCustom(rule.field)
    let operators =
      custom
      ? NativeViewBackupVocabulary.customOperators : FilterVocabulary.operators[rule.field] ?? []
    guard rule.type == "rule", operators.contains(rule.operator), valid(rule.value),
      valid(rule.valueTo)
    else { throw NativeViewBackupError.filter }
    if let provider = rule.provider {
      guard ["communityRating", "communityRatingCount"].contains(rule.field),
        FilterVocabulary.ratingProviders.contains(provider)
      else { throw NativeViewBackupError.filter }
    }
    if custom {
      switch rule.value {
      case .strings, .numbers: throw NativeViewBackupError.filter
      default: break
      }
      if ["gt", "gte", "lt", "lte"].contains(rule.operator) {
        guard case .number = rule.value else { throw NativeViewBackupError.filter }
      }
      if ["before", "after"].contains(rule.operator), !validDate(rule.value) {
        throw NativeViewBackupError.filter
      }
      if rule.operator == "between" {
        switch (rule.value, rule.valueTo) {
        case (.number, .number): break
        default:
          guard validDate(rule.value), validDate(rule.valueTo) else {
            throw NativeViewBackupError.filter
          }
        }
      }
    } else if ["addedAt", "startedAt", "finishedAt", "publishedDate"].contains(rule.field),
      ["before", "after", "between"].contains(rule.operator)
    {
      guard validDate(rule.value), rule.operator != "between" || validDate(rule.valueTo) else {
        throw NativeViewBackupError.filter
      }
    }
  }

  private static func valid(_ value: RuleValue?) -> Bool {
    switch value {
    case .number(let number): number.isFinite
    case .numbers(let values):
      !values.isEmpty && values.count <= 20 && values.allSatisfy(\.isFinite)
    case .strings(let values): !values.isEmpty && values.count <= 20 && !values.contains("")
    case .string, nil: true
    }
  }

  private static func valid(_ value: RuleValueTo?) -> Bool {
    switch value {
    case .number(let number): number.isFinite
    case .string, nil: true
    }
  }

  private static func validDate(_ value: RuleValue?) -> Bool {
    switch value {
    case .number(let number): number.isFinite && abs(number) <= 8_640_000_000_000_000
    case .string(let text): validDate(text)
    default: false
    }
  }

  private static func validDate(_ value: RuleValueTo?) -> Bool {
    switch value {
    case .number(let number): number.isFinite && abs(number) <= 8_640_000_000_000_000
    case .string(let text): validDate(text)
    default: false
    }
  }

  private static func validDate(_ text: String) -> Bool {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let date = String(text.prefix(10))
    guard date.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else {
      return false
    }
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    guard let parsed = formatter.date(from: date), formatter.string(from: parsed) == date else {
      return false
    }
    if text.count == 10 { return true }
    let pattern =
      "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
      + "(?:\\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})$"
    guard text.range(of: pattern, options: .regularExpression) != nil else { return false }
    let iso = ISO8601DateFormatter()
    if iso.date(from: text) != nil { return true }
    iso.formatOptions.insert(.withFractionalSeconds)
    return iso.date(from: text) != nil
  }
}

enum NativeViewBackupError: LocalizedError, Equatable {
  case invalidFile, version, entries, builtIn, fileSize, unreadableFile, layout, sort, filter,
    restore
  case unsupportedField(String)

  var errorDescription: String? {
    switch self {
    case .invalidFile: "Choose a valid table backup JSON file with presets and saved views."
    case .version: "This backup version is unsupported. Choose a version 1 table backup."
    case .entries: "A backup can contain at most 100 presets and 100 saved views."
    case .builtIn: "Backups can import custom presets only. Remove built-in presets from the file."
    case .fileSize: "Choose a backup file no larger than 4 MiB."
    case .unreadableFile: "The backup file could not be read. Choose a JSON file in Files."
    case .layout: "The backup contains duplicate column IDs or conflicting legacy column settings."
    case .sort: "The backup must use at most five supported sort fields and valid directions."
    case .filter:
      "The backup contains an invalid filter. Use at most five group levels and 64 conditions and groups."
    case .restore:
      "The backup could not finish saving. Check your presets and saved views before importing again."
    case .unsupportedField(let field): "This backup contains unsupported data at \(field)."
    }
  }
}
