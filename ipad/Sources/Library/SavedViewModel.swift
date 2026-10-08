import Foundation
import Observation

struct NativeSavedView: Codable, Identifiable, Sendable, Equatable {
  var view: SavedView
  var location: String
  var presentation: String
  var search: String
  var id: String { view.id }
}

@MainActor @Observable
final class SavedViewModel {
  private(set) var items: [NativeSavedView] = []
  private let key: String
  private let maximumViews = 100
  private let byteLimit = 1024 * 1024

  init(serverURL: String, userID: Int) {
    key = "bookorbit.saved-views.\(serverURL).user.\(userID)"
    if let data = UserDefaults.standard.data(forKey: key), data.count <= byteLimit,
      let views = try? JSONDecoder().decode([NativeSavedView].self, from: data)
    {
      items = Array(views.prefix(maximumViews)).filter {
        !$0.view.name.isEmpty && $0.view.name.count <= 255
          && ["list", "grid", "table"].contains($0.presentation)
      }
    }
  }

  func views(at location: String) -> [NativeSavedView] {
    items.filter { $0.location == location }.sorted {
      if ($0.view.favorite ?? false) != ($1.view.favorite ?? false) {
        return $0.view.favorite == true
      }
      return $0.view.name.localizedStandardCompare($1.view.name) == .orderedAscending
    }
  }

  func exportedViews(at location: String) -> [SavedView] { views(at: location).map(\.view) }

  func prepareImport(_ views: [SavedView], at location: String) throws -> [NativeSavedView] {
    guard !location.isEmpty, location.count <= 255 else { throw SavedViewError.layout }
    guard views.count <= maximumViews, items.count + views.count <= maximumViews else {
      throw SavedViewError.limit
    }
    var imported: [NativeSavedView] = []
    var importedBytes = 0
    for view in views {
      try Self.validate(view)
      var copy = view
      copy.id = "saved_view_\(UUID().uuidString)"
      copy.name = try validName(copy.name)
      copy.layout = BookTableLayout.normalized(copy.layout)
      try Self.validate(copy)
      let entry = NativeSavedView(
        view: copy, location: location, presentation: "table", search: "")
      importedBytes += try JSONEncoder().encode(entry).count
      guard importedBytes <= byteLimit else { throw SavedViewError.storage }
      imported.append(entry)
    }
    let next = items + imported
    _ = try encoded(next)
    return next
  }

  func persistPrepared(_ views: [NativeSavedView]) throws { try persist(views) }

  static func validate(_ view: SavedView) throws {
    let name = view.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 255 else { throw SavedViewError.name }
    guard !view.id.isEmpty, view.id.count <= 255 else { throw SavedViewError.layout }
    do { try NativeViewBackupValidation.validate(layout: view.layout) } catch {
      throw SavedViewError.layout
    }
    try NativeViewBackupValidation.validate(sort: view.sort)
    if let filter = view.filter { try NativeViewBackupValidation.validate(filter: filter) }
  }

  func save(name: String, library: LibraryModel, presentation: String, layout: TableLayoutState)
    throws
  {
    guard items.count < maximumViews else { throw SavedViewError.limit }
    let name = try validName(name)
    let view = SavedView(
      id: UUID().uuidString, name: name, layout: BookTableLayout.normalized(layout),
      sort: [SortSpec(field: library.sort, dir: library.descending ? "desc" : "asc")]
        + library.secondarySort, filter: library.filter)
    try persist(
      items + [
        NativeSavedView(
          view: view, location: library.location.storageKey, presentation: presentation,
          search: library.search)
      ])
  }

  func rename(_ view: NativeSavedView, name: String) throws {
    let name = try validName(name)
    var copy = items
    guard let index = copy.firstIndex(where: { $0.id == view.id }) else { return }
    copy[index].view.name = name
    try persist(copy)
  }

  func duplicate(_ view: NativeSavedView) throws {
    guard items.count < maximumViews else { throw SavedViewError.limit }
    var copy = view
    copy.view.id = UUID().uuidString
    copy.view.name = String((copy.view.name + " Copy").prefix(255))
    try persist(items + [copy])
  }

  func remove(_ view: NativeSavedView) throws { try persist(items.filter { $0.id != view.id }) }

  func toggleFavorite(_ view: NativeSavedView) throws {
    var copy = items
    guard let index = copy.firstIndex(where: { $0.id == view.id }) else { return }
    copy[index].view.favorite = !(copy[index].view.favorite ?? false)
    try persist(copy)
  }

  private func validName(_ name: String) throws -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 255 else { throw SavedViewError.name }
    return trimmed
  }

  private func encoded(_ views: [NativeSavedView]) throws -> Data {
    guard views.count <= maximumViews else { throw SavedViewError.limit }
    let data = try JSONEncoder().encode(views)
    guard data.count <= byteLimit else { throw SavedViewError.storage }
    return data
  }

  private func persist(_ views: [NativeSavedView]) throws {
    let data = try encoded(views)
    UserDefaults.standard.set(data, forKey: key)
    items = views
  }
}

enum SavedViewError: LocalizedError {
  case name, limit, storage, layout
  var errorDescription: String? {
    switch self {
    case .name: "Enter a view name with at most 255 characters."
    case .limit: "You can save up to 100 views. Remove a view before saving another."
    case .storage: "The saved views are too large. Use fewer filter conditions."
    case .layout: "The saved view contains an invalid or oversized column layout."
    }
  }
}
