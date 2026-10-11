import Foundation
import Observation

@MainActor @Observable
final class ContentRestrictionUsersModel {
  let api: BookOrbitAPI
  var search = ""
  private(set) var page = 0
  private(set) var users: UserRestrictionTargetPage?
  private(set) var isBusy = false
  private(set) var error: String?

  init(api: BookOrbitAPI) { self.api = api }

  func load(page: Int = 0) async {
    guard !isBusy else { return }
    isBusy = true
    error = nil
    defer { isBusy = false }
    do {
      let session = try await api.authenticatedSessionGeneration()
      let users = try await api.readingRestrictionUsers(
        search: search, page: page, session: session)
      try Task.checkCancellation()
      self.users = users
      self.page = page
    } catch {
      if !Task.isCancelled { self.error = error.localizedDescription }
    }
  }
}

@MainActor @Observable
final class ContentRestrictionEditorModel {
  let api: BookOrbitAPI
  let target: UserRestrictionTarget
  var filters = ContentFilterRulesWithNames(
    includeTags: [], excludeTags: [], includeGenres: [], excludeGenres: [],
    seeOwnRequestedBooks: false)
  private(set) var isLoaded = false
  private(set) var isBusy = false
  private(set) var error: String?
  private(set) var message: String?

  init(api: BookOrbitAPI, target: UserRestrictionTarget) {
    self.api = api
    self.target = target
  }

  func load() async {
    guard !isBusy else { return }
    isBusy = true
    error = nil
    defer { isBusy = false }
    do {
      let session = try await api.authenticatedSessionGeneration()
      let filters = try await api.readingContentRestrictions(userID: target.id, session: session)
      try Task.checkCancellation()
      self.filters = filters
      isLoaded = true
    } catch {
      if !Task.isCancelled { self.error = error.localizedDescription }
    }
  }

  func save() async {
    guard isLoaded, !isBusy, !target.isSuperuser else { return }
    isBusy = true
    error = nil
    message = nil
    defer { isBusy = false }
    do {
      let session = try await api.authenticatedSessionGeneration()
      try await api.saveReadingContentRestrictions(
        userID: target.id, filters: filters, session: session)
      let confirmed = try await api.readingContentRestrictions(userID: target.id, session: session)
      try Task.checkCancellation()
      filters = confirmed
      message = "Content restrictions saved for \(target.username)."
    } catch {
      if !Task.isCancelled {
        self.error = "Could not confirm content restrictions. " + error.localizedDescription
      }
    }
  }
}
