import Foundation

enum BookTableDensity: String, Codable, CaseIterable, Identifiable {
  case compact, comfortable, roomy
  var id: String { rawValue }
  var label: String { rawValue.capitalized }
  var verticalPadding: Double {
    switch self {
    case .compact: 4
    case .comfortable: 8
    case .roomy: 12
    }
  }
}

@MainActor
final class TablePresentationModel {
  private struct Preferences: Codable {
    var layouts: [String: TableLayoutState] = [:]
    var density = BookTableDensity.comfortable
  }

  private let key: String
  private var preferences = Preferences()
  private let scopeLimit = 100
  private let byteLimit = 1024 * 1024

  init(serverURL: String, userID: Int) {
    key = "bookorbit.table-presentation.\(serverURL).user.\(userID)"
    if let data = UserDefaults.standard.data(forKey: key), data.count <= byteLimit,
      let stored = try? JSONDecoder().decode(Preferences.self, from: data),
      stored.layouts.count <= scopeLimit,
      stored.layouts.keys.allSatisfy({ !$0.isEmpty && $0.count <= 255 }),
      stored.layouts.values.allSatisfy({ layout in
        do {
          try BookTableLayout.validate(layout)
          return true
        } catch { return false }
      })
    {
      preferences = stored
    }
  }

  var density: BookTableDensity { preferences.density }

  func layout(at location: String) -> TableLayoutState {
    BookTableLayout.normalized(preferences.layouts[location] ?? BookTableLayout.defaults)
  }

  func save(layout: TableLayoutState, at location: String) throws {
    guard !location.isEmpty, location.count <= 255 else { throw TablePresetError.layout }
    try BookTableLayout.validate(layout)
    var next = preferences
    next.layouts[location] = BookTableLayout.normalized(layout)
    guard next.layouts.count <= scopeLimit else { throw TablePresentationError.limit }
    try persist(next)
  }

  func save(density: BookTableDensity) throws {
    var next = preferences
    next.density = density
    try persist(next)
  }

  private func persist(_ next: Preferences) throws {
    let data = try JSONEncoder().encode(next)
    guard data.count <= byteLimit else { throw TablePresentationError.storage }
    UserDefaults.standard.set(data, forKey: key)
    preferences = next
  }
}

enum TablePresentationError: LocalizedError {
  case limit, storage
  var errorDescription: String? {
    switch self {
    case .limit: "Column settings can be remembered for up to 100 library locations."
    case .storage: "The column settings are too large to remember on this iPad."
    }
  }
}
