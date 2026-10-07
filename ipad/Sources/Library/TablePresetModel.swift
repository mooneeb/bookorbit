import Foundation
import Observation

struct NativeTablePreset: Codable, Identifiable, Sendable, Equatable {
  var preset: TablePreset
  var location: String
  var id: String { preset.id }
}

@MainActor @Observable
final class TablePresetModel {
  private(set) var items: [NativeTablePreset] = []
  private let key: String
  private let maximumPresets = 100
  private let byteLimit = 1024 * 1024

  init(serverURL: String, userID: Int) {
    key = "bookorbit.table-presets.\(serverURL).user.\(userID)"
    if let data = UserDefaults.standard.data(forKey: key), data.count <= byteLimit,
      let stored = try? JSONDecoder().decode([NativeTablePreset].self, from: data),
      stored.count <= maximumPresets
    {
      var seen = Set<String>()
      items = stored.compactMap { item in
        guard !item.location.isEmpty, item.location.count <= 255,
          item.preset.isBuiltIn != true, seen.insert(item.id).inserted
        else { return nil }
        do {
          try Self.validate(item.preset)
          var copy = item
          copy.preset.layout = BookTableLayout.normalized(copy.preset.layout)
          return copy
        } catch { return nil }
      }
    }
  }

  func customPresets(at location: String) -> [TablePreset] {
    items.filter { $0.location == location }.map(\.preset).sorted {
      if ($0.favorite ?? false) != ($1.favorite ?? false) { return $0.favorite == true }
      return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  func presets(at location: String) -> [TablePreset] {
    Self.builtInPresets + customPresets(at: location)
  }

  func save(name: String, layout: TableLayoutState, sort: [SortSpec]?, at location: String) throws {
    let preset = TablePreset(
      id: "custom_\(UUID().uuidString)", name: try Self.validName(name),
      layout: BookTableLayout.normalized(layout), sort: sort?.isEmpty == false ? sort : nil)
    try Self.validate(preset)
    try persist(items + [NativeTablePreset(preset: preset, location: location)])
  }

  func rename(_ id: String, name: String, at location: String) throws {
    let name = try Self.validName(name)
    var next = items
    guard let index = next.firstIndex(where: { $0.id == id && $0.location == location }) else {
      return
    }
    next[index].preset.name = name
    try persist(next)
  }

  func duplicate(_ id: String, at location: String) throws {
    guard var preset = customPresets(at: location).first(where: { $0.id == id }) else { return }
    preset.id = "custom_\(UUID().uuidString)"
    preset.name = String((preset.name + " Copy").prefix(255))
    preset.isBuiltIn = false
    try persist(items + [NativeTablePreset(preset: preset, location: location)])
  }

  func remove(_ id: String, at location: String) throws {
    try persist(items.filter { $0.id != id || $0.location != location })
  }

  func toggleFavorite(_ id: String, at location: String) throws {
    var next = items
    guard let index = next.firstIndex(where: { $0.id == id && $0.location == location }) else {
      return
    }
    next[index].preset.favorite = !(next[index].preset.favorite ?? false)
    try persist(next)
  }

  func prepareImport(_ presets: [TablePreset], at location: String) throws -> [NativeTablePreset] {
    guard presets.count <= maximumPresets else { throw TablePresetError.limit }
    var imported: [NativeTablePreset] = []
    var importedBytes = 0
    for preset in presets where preset.isBuiltIn != true {
      try Self.validate(preset)
      var copy = preset
      copy.id = "custom_\(UUID().uuidString)"
      copy.name = try Self.validName(copy.name)
      copy.layout = BookTableLayout.normalized(copy.layout)
      copy.isBuiltIn = false
      let entry = NativeTablePreset(preset: copy, location: location)
      importedBytes += try JSONEncoder().encode(entry).count
      guard importedBytes <= byteLimit else {
        throw TablePresetError.storage
      }
      imported.append(entry)
    }
    let next = items + imported
    _ = try encoded(next)
    return next
  }

  @discardableResult
  func importPresets(_ presets: [TablePreset], at location: String) throws -> Int {
    let next = try prepareImport(presets, at: location)
    let count = next.count - items.count
    try persist(next)
    return count
  }

  func persistPrepared(_ presets: [NativeTablePreset]) throws { try persist(presets) }

  static func validate(_ preset: TablePreset) throws {
    _ = try validName(preset.name)
    guard !preset.id.isEmpty, preset.id.count <= 255 else { throw TablePresetError.layout }
    try BookTableLayout.validate(preset.layout)
    if let sorts = preset.sort {
      guard sorts.count <= 5, sorts.allSatisfy(validSort) else { throw TablePresetError.sort }
    }
  }

  private static func validSort(_ sort: SortSpec) -> Bool {
    let custom =
      sort.field.range(of: "^custom:[1-9][0-9]{0,8}$", options: .regularExpression) != nil
    return (SortVocabulary.fields.contains(sort.field) || custom)
      && ["asc", "desc"].contains(sort.dir)
  }

  private static func validName(_ name: String) throws -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 255 else { throw TablePresetError.name }
    return trimmed
  }

  private func encoded(_ presets: [NativeTablePreset]) throws -> Data {
    guard presets.count <= maximumPresets else { throw TablePresetError.limit }
    guard presets.allSatisfy({ !$0.location.isEmpty && $0.location.count <= 255 }),
      Set(presets.map(\.id)).count == presets.count
    else { throw TablePresetError.layout }
    for preset in presets {
      guard preset.preset.isBuiltIn != true else { throw TablePresetError.layout }
      try Self.validate(preset.preset)
    }
    let data = try JSONEncoder().encode(presets)
    guard data.count <= byteLimit else { throw TablePresetError.storage }
    return data
  }

  private func persist(_ presets: [NativeTablePreset]) throws {
    let data = try encoded(presets)
    UserDefaults.standard.set(data, forKey: key)
    items = presets
  }

  private static var builtInPresets: [TablePreset] {
    let layouts: [(String, String, [String])] = [
      (
        "default", "Default",
        [
          "cover", "title", "authors", "seriesName", "seriesIndex", "publishedYear", "rating",
          "readStatus", "format", "actions",
        ]
      ),
      ("compact", "Compact", ["cover", "title", "authors", "rating", "readStatus", "actions"]),
      (
        "metadata", "Metadata",
        [
          "cover", "title", "authors", "subtitle", "publisher", "language", "publishedDate",
          "publishedYear", "pageCount", "format", "actions",
        ]
      ),
    ]
    return layouts.map { id, name, visible in
      TablePreset(
        id: id, name: name,
        layout: TableLayoutState(
          columnOrder: BookTableLayout.presetColumns,
          hiddenColumns: BookTableLayout.presetColumns.filter { !visible.contains($0) },
          columnWidths: [:]), isBuiltIn: true)
    }
  }
}

enum TablePresetError: LocalizedError {
  case name, limit, storage, layout, sort, collectionSort

  var errorDescription: String? {
    switch self {
    case .name: "Enter a preset name with at most 255 characters."
    case .limit: "You can save up to 100 presets. Remove a preset before saving another."
    case .storage: "The presets are too large. Remove a preset before saving another."
    case .layout: "The preset contains an invalid or oversized column layout."
    case .sort: "The preset must use at most five supported sort fields and valid directions."
    case .collectionSort: "This preset's collection order sort can only be applied in a collection."
    }
  }
}
