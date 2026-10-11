import Foundation
import Observation

struct ReadingActivityChartPoint: Identifiable {
  let day: String
  let date: Date
  let readingSeconds: Double
  let listeningSeconds: Double
  var id: String { day }
}

struct ReadingGoalChartPoint: Identifiable {
  let month: Int
  let completed: Double
  let target: Double?
  var id: Int { month }
}

enum ReadingAchievementFilter: String, CaseIterable, Identifiable {
  case all, earned, inProgress, locked
  var id: String { rawValue }
  var title: String {
    switch self {
    case .all: String(localized: "All achievements")
    case .earned: String(localized: "Earned")
    case .inProgress: String(localized: "In progress")
    case .locked: String(localized: "Locked")
    }
  }
}

@MainActor @Observable
final class ReadingStatisticsModel {
  let api: BookOrbitAPI
  let userID: Int
  private(set) var activity: ActivityOverviewResponse?
  private(set) var catalogue: AchievementCatalogueResponse?
  private(set) var isLoading = false
  private(set) var isLoadingAchievements = false
  private(set) var isSavingGoal = false
  private(set) var isSavingPreferences = false
  var error: String?
  var achievementsError: String?
  var goalError: String?
  var preferencesError: String?
  var notice: String?
  var chartDays = 14
  var achievementFilter = ReadingAchievementFilter.all
  var achievementCategory = "all"
  var achievementPage = 0
  let achievementPageSize = 20
  private var requestID = UUID()
  private var catalogueRequestID = UUID()
  private var session: UUID?
  private var preferenceRetry: Bool?

  init(api: BookOrbitAPI, user: AuthUser) {
    self.api = api
    userID = user.id
  }

  var dailyPoints: [ReadingActivityChartPoint] {
    (activity?.dailyActivity.days.suffix(chartDays) ?? []).compactMap { day in
      guard let date = Self.date(day.day) else { return nil }
      return ReadingActivityChartPoint(
        day: day.day, date: date, readingSeconds: day.readingSeconds,
        listeningSeconds: day.listeningSeconds)
    }
  }

  var goalPoints: [ReadingGoalChartPoint] {
    (activity?.goal.points ?? []).map {
      ReadingGoalChartPoint(
        month: Int($0.month), completed: $0.actualCumulative, target: $0.targetCumulative)
    }
  }

  var matchingAchievements: [AchievementItem] {
    (catalogue?.categories ?? [])
      .filter { achievementCategory == "all" || $0.key == achievementCategory }
      .flatMap(\.achievements)
      .filter { item in
        switch achievementFilter {
        case .all: true
        case .earned: item.earned
        case .inProgress: !item.earned && !item.hidden && (item.currentProgress ?? 0) > 0
        case .locked: !item.earned
        }
      }
  }

  var achievementPageCount: Int {
    max(1, (matchingAchievements.count + achievementPageSize - 1) / achievementPageSize)
  }

  var visibleAchievements: [AchievementItem] {
    Array(
      matchingAchievements.dropFirst(achievementPage * achievementPageSize).prefix(
        achievementPageSize))
  }

  func resetAchievementPage() { achievementPage = 0 }
  func previousAchievementPage() { achievementPage = max(0, achievementPage - 1) }
  func nextAchievementPage() {
    achievementPage = min(achievementPageCount - 1, achievementPage + 1)
  }

  func load() async {
    guard !isSavingGoal && !isSavingPreferences else { return }
    let id = UUID()
    requestID = id
    isLoading = true
    error = nil
    defer { if requestID == id { isLoading = false } }
    do {
      let generation = try await api.authenticatedSessionGeneration()
      session = generation
      let value = try await api.readingActivity(session: generation)
      guard requestID == id else { return }
      activity = value
      if !value.achievementsEnabled { catalogue = nil }
    } catch is CancellationError {
    } catch {
      guard requestID == id else { return }
      self.error = Self.feedback(error)
    }
  }

  func loadAchievements() async {
    guard activity?.achievementsEnabled == true else { return }
    let id = UUID()
    catalogueRequestID = id
    isLoadingAchievements = true
    achievementsError = nil
    defer { if catalogueRequestID == id { isLoadingAchievements = false } }
    do {
      let generation = try await api.authenticatedSessionGeneration()
      let value = try await api.readingAchievements(session: generation)
      guard catalogueRequestID == id, activity?.achievementsEnabled == true else { return }
      catalogue = value
      achievementPage = min(achievementPage, achievementPageCount - 1)
    } catch is CancellationError {
    } catch {
      guard catalogueRequestID == id else { return }
      achievementsError = Self.feedback(error)
    }
  }

  func saveGoal(_ books: Int?) async -> Bool {
    guard !isSavingGoal && !isSavingPreferences, let session else { return false }
    isSavingGoal = true
    goalError = nil
    notice = nil
    defer { isSavingGoal = false }
    do {
      try await api.saveAnnualReadingGoal(books, userID: userID, session: session)
      notice = String(
        localized: "Reading goal saved. Progress uses your completed books for this year.")
      do {
        activity = try await api.readingActivity(session: session)
      } catch {
        self.error = Self.feedback(error)
        notice = String(localized: "Reading goal saved. Refresh to load updated progress.")
      }
      return true
    } catch {
      goalError = Self.feedback(error)
      return false
    }
  }

  func saveAchievementPreference(_ enabled: Bool) async {
    guard !isSavingGoal && !isSavingPreferences, let session else { return }
    isSavingPreferences = true
    preferencesError = nil
    preferenceRetry = enabled
    defer { isSavingPreferences = false }
    do {
      try await api.saveReadingAchievementPreference(enabled, userID: userID, session: session)
      activity?.achievementsEnabled = enabled
      if !enabled { catalogue = nil }
      preferenceRetry = nil
      notice = String(localized: "Achievement preferences saved.")
    } catch {
      preferencesError = Self.feedback(error)
    }
  }

  func retryAchievementPreference() async {
    guard let preferenceRetry else { return }
    await saveAchievementPreference(preferenceRetry)
  }

  func close() {
    requestID = UUID()
    catalogueRequestID = UUID()
  }

  static func duration(_ seconds: Double) -> String {
    let safe = max(0, seconds.isFinite ? seconds : 0)
    return Duration.seconds(safe).formatted(
      .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
  }

  static func sourceTitle(_ source: String) -> String {
    switch source {
    case "bookorbit": "BookOrbit"
    case "ios": String(localized: "iOS app")
    case "watchos": "Apple Watch"
    case "android": String(localized: "Android app")
    case "kobo": "Kobo"
    case "koreader": "KOReader"
    default: String(localized: "Unknown source")
    }
  }

  static func date(_ day: String) -> Date? {
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.timeZone = TimeZone(secondsFromGMT: 0)
    format.dateFormat = "yyyy-MM-dd"
    return format.date(from: day)
  }

  static func dayTitle(_ date: Date) -> String {
    date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt))
  }

  static func feedback(_ error: any Error) -> String {
    switch error {
    case ReadingStatisticsError.invalidGoal:
      String(localized: "Choose a whole number of books from 1 to 10,000.")
    case ConnectionError.expiredSession:
      String(localized: "Your session expired. Sign in again to load your reading activity.")
    case ConnectionError.denied:
      String(localized: "This account cannot access this reading information.")
    case is URLError:
      String(localized: "Could not connect to your server. Check your connection and retry.")
    default:
      String(localized: "Could not load reading information. Retry to refresh from your server.")
    }
  }
}

enum ReadingStatisticsError: Error { case invalidGoal }
