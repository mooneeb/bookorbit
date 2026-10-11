import Foundation

extension BookOrbitAPI {
  func readingActivity(session: UUID) async throws -> ActivityOverviewResponse {
    let response: ActivityOverviewResponse = try await boundedJSON(
      "user-statistics/activity-overview", byteLimit: 512 * 1024, session: session)
    guard response.dailyActivity.days.count <= 84, response.calendar.days.count <= 366,
      response.goal.points.count <= 12, response.rhythm.hours.count <= 24,
      response.rhythm.weekdays.count <= 7, response.sources.slices.count <= 6
    else { throw ConnectionError.invalidResponse }
    return response
  }

  func readingAchievements(session: UUID) async throws -> AchievementCatalogueResponse {
    let response: AchievementCatalogueResponse = try await boundedJSON(
      "achievements", byteLimit: 512 * 1024, session: session)
    guard response.categories.count <= 5,
      response.categories.reduce(0, { $0 + $1.achievements.count }) <= 1000
    else { throw ConnectionError.invalidResponse }
    return response
  }

  func saveAnnualReadingGoal(_ books: Int?, userID: Int, session: UUID) async throws {
    guard books.map({ (1...10_000).contains($0) }) ?? true else {
      throw ReadingStatisticsError.invalidGoal
    }
    let user: AuthUser = try await boundedJSON("auth/me", session: session)
    guard user.id == userID else { throw ConnectionError.expiredSession }
    var config =
      user.settings.dashboardConfig
      ?? DashboardConfig(readingGoal: nil, widgets: nil, libraryIds: nil)
    config.readingGoal = books.map(Double.init)
    let body = UserDashboardSettingsResponse(
      settings: UserSettings(dashboardConfig: config, dashboardShelfConfig: nil))
    try await sendEmpty(
      "users/me/settings", method: "PATCH", body: JSONEncoder().encode(body), session: session)
  }

  func saveReadingAchievementPreference(_ enabled: Bool, userID: Int, session: UUID) async throws {
    let user: AuthUser = try await boundedJSON("auth/me", session: session)
    guard user.id == userID else { throw ConnectionError.expiredSession }
    var settings = UserSettings(dashboardConfig: nil, dashboardShelfConfig: nil)
    settings.achievementPreferences = .init(enabled: enabled)
    let body = UserDashboardSettingsResponse(settings: settings)
    try await sendEmpty(
      "users/me/settings", method: "PATCH", body: JSONEncoder().encode(body), session: session)
  }
}
