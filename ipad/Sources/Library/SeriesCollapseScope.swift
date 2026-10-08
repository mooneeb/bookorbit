import Foundation

struct SeriesCollapseScope: Equatable {
  var libraryID: Int?
  var collectionID: Int?
  var smartScopeID: Int?
  var authorPages = false

  static let global = Self()
  static let authors = Self(authorPages: true)

  var title: String {
    if authorPages { return "Author pages" }
    if smartScopeID != nil { return "This smart scope" }
    if collectionID != nil { return "This collection" }
    if libraryID != nil { return "This library" }
    return "All books"
  }

  var canInherit: Bool {
    !authorPages && (smartScopeID != nil || collectionID != nil || libraryID != nil)
  }

  func effective(_ preferences: SeriesCollapsePreferences?) -> Bool {
    guard let preferences else { return false }
    if authorPages { return preferences.authorPages ?? false }
    if let smartScopeID, let value = preferences.smartScopes?[String(smartScopeID)] { return value }
    if let collectionID, let value = preferences.collections[String(collectionID)] { return value }
    if let libraryID, let value = preferences.libraries[String(libraryID)] { return value }
    return preferences.global
  }

  func hasOverride(_ preferences: SeriesCollapsePreferences?) -> Bool {
    guard let preferences, canInherit else { return false }
    if let smartScopeID { return preferences.smartScopes?[String(smartScopeID)] != nil }
    if let collectionID { return preferences.collections[String(collectionID)] != nil }
    if let libraryID { return preferences.libraries[String(libraryID)] != nil }
    return false
  }

  func payload(value: Bool?) -> UpdateSeriesCollapsePreferencesPayload {
    var payload = UpdateSeriesCollapsePreferencesPayload()
    if authorPages {
      payload.authorPages = value ?? false
    } else if let smartScopeID {
      payload.smartScopes = [String(smartScopeID): value]
    } else if let collectionID {
      payload.collections = [String(collectionID): value]
    } else if let libraryID {
      payload.libraries = [String(libraryID): value]
    } else {
      payload.global = value ?? false
    }
    return payload
  }

  func matches(_ preferences: SeriesCollapsePreferences?, value: Bool?) -> Bool {
    guard let preferences else { return value == nil || value == false }
    if authorPages { return (preferences.authorPages ?? false) == (value ?? false) }
    if let smartScopeID { return preferences.smartScopes?[String(smartScopeID)] == value }
    if let collectionID { return preferences.collections[String(collectionID)] == value }
    if let libraryID { return preferences.libraries[String(libraryID)] == value }
    return preferences.global == (value ?? false)
  }
}

extension BookLocation {
  var seriesCollapseScope: SeriesCollapseScope {
    switch self {
    case .all: .global
    case .library(let id, _): SeriesCollapseScope(libraryID: id)
    case .collection(let id, _): SeriesCollapseScope(collectionID: id)
    case .scope(let id, _, _): SeriesCollapseScope(smartScopeID: id)
    }
  }

  var seriesLibraryID: Int? {
    if case .library(let id, _) = self { return id }
    return nil
  }
}
