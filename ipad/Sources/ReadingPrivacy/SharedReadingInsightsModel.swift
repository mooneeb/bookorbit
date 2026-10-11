import Foundation
import Observation

@MainActor @Observable
final class SharedReadingInsightsModel {
  let api: BookOrbitAPI
  var search = ""
  private(set) var accounts: AccountActivityListResponse?
  private(set) var selectedAccount: AccountActivityListItem?
  private(set) var summary: SharedReadingInsightsSummary?
  private(set) var detail: SharedReadingInsightsDetail?
  private(set) var isBusy = false
  private(set) var error: String?
  private var viewSession: SharedReadingInsightsViewSession?

  init(api: BookOrbitAPI) { self.api = api }

  func loadAccounts(page: Int = 1) async {
    guard !isBusy else { return }
    isBusy = true
    error = nil
    defer { isBusy = false }
    do {
      let session = try await api.authenticatedSessionGeneration()
      let accounts = try await api.sharedReadingAccounts(
        search: search, page: page, session: session)
      try Task.checkCancellation()
      self.accounts = accounts
    } catch {
      if !Task.isCancelled { self.error = error.localizedDescription }
    }
  }

  func open(_ account: AccountActivityListItem) async {
    guard !isBusy else { return }
    selectedAccount = account
    viewSession = nil
    await refresh()
  }

  func refresh() async {
    guard !isBusy, let account = selectedAccount else { return }
    isBusy = true
    summary = nil
    detail = nil
    error = nil
    defer { isBusy = false }
    do {
      let session = try await api.authenticatedSessionGeneration()
      let view: SharedReadingInsightsViewSession
      if let existing = viewSession {
        view = existing
      } else {
        view = try await api.sharedReadingViewSession(userID: account.id, session: session)
      }
      viewSession = view
      let summary = try await api.sharedReadingSummary(
        userID: account.id, viewSessionID: view.viewSessionId, session: session)
      let detail =
        summary.sharingLevel == "detailed"
        ? try await api.sharedReadingDetail(
          userID: account.id, viewSessionID: view.viewSessionId, session: session)
        : nil
      try Task.checkCancellation()
      self.summary = summary
      self.detail = detail
    } catch {
      viewSession = nil
      if !Task.isCancelled {
        self.error =
          error is ConnectionError
          ? "These shared insights are unavailable or permission has changed. "
            + error.localizedDescription
          : error.localizedDescription
      }
    }
  }
}
