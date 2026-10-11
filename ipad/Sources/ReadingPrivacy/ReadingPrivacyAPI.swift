import Foundation

extension BookOrbitAPI {
  func readingPrivacySettings(session: UUID) async throws -> ReadingInsightsSharingSettings {
    try await boundedJSONOnline("reading-insights-sharing/me", session: session)
  }

  func updateReadingPrivacy(
    level: String, session: UUID
  ) async throws -> ReadingInsightsSharingSettings {
    try await boundedJSONOnline(
      "reading-insights-sharing/me", method: "PATCH",
      body: JSONEncoder().encode(UpdateReadingInsightsSharingRequest(sharingLevel: level)),
      session: session)
  }

  func readingPrivacyPreview(session: UUID) async throws -> ReadingInsightsPreview {
    try await boundedJSONOnline(
      "reading-insights-sharing/me/preview", query: [URLQueryItem(name: "days", value: "30")],
      byteLimit: 256 * 1024, session: session)
  }

  func readingPrivacyHistory(page: Int, session: UUID) async throws
    -> ReadingInsightsAccessHistoryPage
  {
    try await boundedJSONOnline(
      "reading-insights-sharing/me/access-history",
      query: [
        URLQueryItem(name: "page", value: String(page)),
        URLQueryItem(name: "pageSize", value: "20"),
      ],
      byteLimit: 128 * 1024, session: session)
  }

  func readingContentRestrictions(userID: Int? = nil, session: UUID) async throws
    -> ContentFilterRulesWithNames
  {
    try await boundedJSONOnline(
      userID.map { "users/\($0)/content-filters" } ?? "users/me/content-filters", session: session)
  }

  func saveReadingContentRestrictions(
    userID: Int, filters: ContentFilterRulesWithNames, session: UUID
  ) async throws {
    try await sendEmpty(
      "users/\(userID)/content-filters", method: "PUT",
      body: JSONEncoder().encode(
        SetContentFiltersRequest(
          includeTagIds: filters.includeTags.map(\.id),
          excludeTagIds: filters.excludeTags.map(\.id),
          includeGenreIds: filters.includeGenres.map(\.id),
          excludeGenreIds: filters.excludeGenres.map(\.id),
          seeOwnRequestedBooks: filters.seeOwnRequestedBooks)),
      session: session, expectedStatus: 204)
  }

  func readingRestrictionUsers(search: String, page: Int, session: UUID) async throws
    -> UserRestrictionTargetPage
  {
    try await boundedJSONOnline(
      "users",
      query: [
        URLQueryItem(name: "search", value: search),
        URLQueryItem(name: "page", value: String(page)),
        URLQueryItem(name: "pageSize", value: "20"),
      ], byteLimit: 256 * 1024, session: session)
  }

  func readingRestrictionChoices(kind: String, search: String, session: UUID) async throws
    -> [CatalogSearchResult]
  {
    guard ["tags", "genres"].contains(kind),
      !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return [] }
    return try await boundedJSONOnline(
      "metadata/\(kind)", query: [URLQueryItem(name: "q", value: search)], byteLimit: 128 * 1024,
      session: session)
  }

  func sharedReadingAccounts(search: String, page: Int, session: UUID) async throws
    -> AccountActivityListResponse
  {
    try await boundedJSONOnline(
      "account-activity",
      query: [
        URLQueryItem(name: "search", value: search),
        URLQueryItem(name: "page", value: String(page)),
        URLQueryItem(name: "pageSize", value: "20"),
      ], byteLimit: 256 * 1024, session: session)
  }

  func sharedReadingViewSession(userID: Int, session: UUID) async throws
    -> SharedReadingInsightsViewSession
  {
    try await boundedJSONOnline(
      "shared-reading-insights/\(userID)/view-sessions", method: "POST", session: session)
  }

  func sharedReadingSummary(userID: Int, viewSessionID: String, session: UUID) async throws
    -> SharedReadingInsightsSummary
  {
    try await boundedJSONOnline(
      "shared-reading-insights/\(userID)/summary", query: [URLQueryItem(name: "days", value: "30")],
      byteLimit: 256 * 1024, session: session,
      headers: ["x-reading-insights-view-session": viewSessionID])
  }

  func sharedReadingDetail(userID: Int, viewSessionID: String, session: UUID) async throws
    -> SharedReadingInsightsDetail
  {
    try await boundedJSONOnline(
      "shared-reading-insights/\(userID)/detailed",
      query: [URLQueryItem(name: "days", value: "30")],
      byteLimit: 256 * 1024, session: session,
      headers: ["x-reading-insights-view-session": viewSessionID])
  }
}
