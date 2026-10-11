import Foundation
import XCTest

final class ReadingStatisticsJourneyTests: XCTestCase {
  private let accessibilityAudit = E04AccessibilityAudit()
  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
  }

  override func tearDownWithError() throws {
    if let testRun, testRun.failureCount > 0 { capture("IPAD-E04-A01-statistics-failure") }
    accessibilityAudit.reportFailures(testCase: self)
    try super.tearDownWithError()
  }

  @MainActor
  func testIPADE04A01StatisticsChartsGoalAndAchievements() async throws {
    let app = launchAndSignIn(username: "ipad-e04-statistics")
    app.buttons["readingStatistics"].tap()
    let total = element("readingSevenDayTotal", app: app)
    XCTAssertTrue(total.waitForExistence(timeout: 15))
    XCTAssertEqual(total.value as? String, "900 seconds")
    XCTAssertEqual(element("readingSevenDayReading", app: app).value as? String, "600 seconds")
    XCTAssertEqual(element("readingSevenDayListening", app: app).value as? String, "300 seconds")
    capture("IPAD-E04-A01-statistics-worked-example")
    accessibilityAudit.collect(
      app, screen: "IPAD-E04-A01-statistics-worked-example", testCase: self)
    reveal(element("readingDailyChart", app: app), app: app)
    XCTAssertTrue(element("readingDailyChart", app: app).exists)
    capture("IPAD-E04-A01-statistics-daily-chart")
    reveal(element("readingSourceios", app: app), app: app)
    XCTAssertEqual(element("readingSourceios", app: app).value as? String, "900 seconds")
    reveal(app.buttons["editReadingGoal"], app: app)
    app.buttons["editReadingGoal"].tap()
    let goal = app.textFields["readingGoalBooks"]
    XCTAssertTrue(goal.waitForExistence(timeout: 5))
    goal.tap()
    let existing = goal.value as? String ?? ""
    goal.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
    goal.typeText("24")
    capture("IPAD-E04-A01-statistics-goal-draft")
    app.buttons["saveReadingGoal"].tap()
    XCTAssertTrue(app.staticTexts["readingGoalProgress"].waitForExistence(timeout: 15))
    reveal(app.staticTexts["readingGoalProgress"], app: app)
    XCTAssertEqual(app.staticTexts["readingGoalProgress"].label, "1 of 24 books completed")
    capture("IPAD-E04-A01-statistics-synchronized-goal")
    XCUIDevice.shared.orientation = .landscapeLeft
    XCTAssertTrue(app.staticTexts["readingGoalProgress"].exists)
    capture("IPAD-E04-A01-statistics-goal-landscape")
    XCUIDevice.shared.orientation = .portrait
    let tracking = app.switches["readingAchievementsEnabled"]
    reveal(tracking, app: app)
    tracking.tap()
    XCTAssertTrue(
      app.staticTexts["Achievements are turned off for this account."].waitForExistence(timeout: 15)
    )
    XCTAssertFalse(app.buttons["readingAchievements"].exists)
    capture("IPAD-E04-A01-statistics-achievements-disabled")
    tracking.tap()
    XCTAssertTrue(app.buttons["readingAchievements"].waitForExistence(timeout: 15))
    reveal(app.buttons["readingAchievements"], app: app)
    app.buttons["readingAchievements"].tap()
    XCTAssertTrue(app.staticTexts["readingAchievementsTotal"].waitForExistence(timeout: 15))
    let first = element("readingAchievementbooks_finished_1", app: app)
    XCTAssertTrue(first.exists)
    XCTAssertTrue(first.label.contains("Ink Initiate"))
    XCTAssertTrue(first.label.contains("Earned"))
    XCTAssertLessThanOrEqual(achievementRows(app).count, 20)
    capture("IPAD-E04-A01-statistics-earned-achievements")
    accessibilityAudit.collect(
      app, screen: "IPAD-E04-A01-statistics-earned-achievements", testCase: self)
    reveal(app.buttons["Next"], app: app)
    XCTAssertTrue(app.buttons["Next"].isEnabled)
    app.buttons["Next"].tap()
    XCTAssertTrue(app.staticTexts["readingAchievementsPage"].label.hasPrefix("Page 2"))
    XCTAssertLessThanOrEqual(achievementRows(app).count, 20)
    XCTAssertFalse(first.exists)
    capture("IPAD-E04-A01-statistics-achievements-second-page")
    try await handoff()
    app.navigationBars.buttons["Reading activity"].tap()
    app.buttons["Done"].tap()
    app.buttons["signOut"].tap()
  }

  @MainActor
  func testIPADE04A01StatisticsFailureRetryAndIsolation() async throws {
    try await fault("reading-statistics", action: "recover")
    try await fault("achievements", action: "recover")
    let app = launchAndSignIn(username: "ipad-e04-statistics", useFaultProxy: true)
    try await fault("reading-statistics", action: "fail")
    app.buttons["readingStatistics"].tap()
    XCTAssertTrue(element("readingStatisticsError", app: app).waitForExistence(timeout: 15))
    XCTAssertTrue(app.buttons["retryReadingStatistics"].exists)
    capture("IPAD-E04-A01-statistics-error")
    accessibilityAudit.collect(app, screen: "IPAD-E04-A01-statistics-error", testCase: self)
    try await fault("reading-statistics", action: "recover")
    app.buttons["retryReadingStatistics"].tap()
    XCTAssertTrue(element("readingSevenDayTotal", app: app).waitForExistence(timeout: 15))
    XCTAssertEqual(element("readingSevenDayTotal", app: app).value as? String, "900 seconds")
    capture("IPAD-E04-A01-statistics-retry-recovered")
    try await fault("achievements", action: "fail")
    reveal(app.buttons["readingAchievements"], app: app)
    app.buttons["readingAchievements"].tap()
    XCTAssertTrue(element("readingAchievementsError", app: app).waitForExistence(timeout: 15))
    capture("IPAD-E04-A01-achievements-error")
    try await fault("achievements", action: "recover")
    app.buttons["retryReadingAchievements"].tap()
    XCTAssertTrue(app.staticTexts["readingAchievementsTotal"].waitForExistence(timeout: 15))
    capture("IPAD-E04-A01-achievements-retry-recovered")
    app.terminate()
    let restricted = launchAndSignIn(username: "ipad-restricted")
    restricted.buttons["readingStatistics"].tap()
    let total = element("readingSevenDayTotal", app: restricted)
    XCTAssertTrue(total.waitForExistence(timeout: 15))
    XCTAssertEqual(total.value as? String, "0 seconds")
    XCTAssertFalse(element("readingSourceios", app: restricted).exists)
    capture("IPAD-E04-A01-statistics-account-isolation")
    restricted.buttons["Done"].tap()
    restricted.buttons["signOut"].tap()
  }

  @MainActor
  private func launchAndSignIn(username: String, useFaultProxy: Bool = false) -> XCUIApplication {
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    if !app.textFields["serverURL"].waitForExistence(timeout: 3) {
      if app.navigationBars.buttons["Reading activity"].exists {
        app.navigationBars.buttons["Reading activity"].tap()
      }
      if app.buttons["Done"].exists { app.buttons["Done"].tap() }
      if app.buttons["signOut"].exists { app.buttons["signOut"].tap() }
      if app.buttons["Change server"].exists { app.buttons["Change server"].tap() }
    }
    let server = app.textFields["serverURL"]
    XCTAssertTrue(server.waitForExistence(timeout: 10))
    server.tap()
    let existing = server.value as? String ?? ""
    server.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.utf16.count))
    let url =
      useFaultProxy
      ? environment("IPAD_E04_FAULT_URL", fallback: "http://127.0.0.1:16505")
      : environment("IPAD_E04_API_URL", fallback: "http://127.0.0.1:16502/api/v1")
        .replacingOccurrences(of: "/api/v1", with: "")
    server.typeText(url)
    app.buttons["connectServer"].tap()
    XCTAssertTrue(app.textFields["username"].wait(for: \.isHittable, toEqual: true, timeout: 10))
    app.textFields["username"].tap()
    app.textFields["username"].typeText(username)
    app.secureTextFields["password"].tap()
    app.secureTextFields["password"].typeText("IpadFixture123")
    app.buttons["signIn"].tap()
    XCTAssertTrue(app.buttons["readingStatistics"].waitForExistence(timeout: 20))
    return app
  }

  @MainActor
  private func element(_ id: String, app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  @MainActor
  private func achievementRows(_ app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(
      NSPredicate(
        format: "identifier BEGINSWITH %@ AND NOT (identifier BEGINSWITH %@)",
        "readingAchievement", "readingAchievements"))
  }

  @MainActor
  private func reveal(_ target: XCUIElement, app: XCUIApplication) {
    for _ in 0..<12 {
      if target.exists && target.isHittable { return }
      if target.exists && target.frame.minY < app.frame.minY + 60 {
        app.swipeDown()
      } else {
        app.swipeUp()
      }
    }
    XCTAssertTrue(target.exists && target.isHittable)
  }

  private func environment(_ key: String, fallback: String) -> String {
    ProcessInfo.processInfo.environment[key]
      ?? ProcessInfo.processInfo.environment["TEST_RUNNER_\(key)"] ?? fallback
  }

  @MainActor
  private func fault(_ feature: String, action: String) async throws {
    let base = environment("IPAD_E04_FAULT_URL", fallback: "http://127.0.0.1:16505")
    var request = URLRequest(
      url: try XCTUnwrap(URL(string: "\(base)/__faults/\(feature)/\(action)")))
    request.httpMethod = "POST"
    let (_, response) = try await E04FixtureHTTP.data(for: request)
    XCTAssertTrue((200..<300).contains(try XCTUnwrap(response as? HTTPURLResponse).statusCode))
  }

  @MainActor
  private func handoff() async throws {
    let base = try XCTUnwrap(
      ProcessInfo.processInfo.environment["IPAD_E04_RECEIVER_URL"]
        ?? ProcessInfo.processInfo.environment["TEST_RUNNER_IPAD_E04_RECEIVER_URL"])
    var request = URLRequest(url: try XCTUnwrap(URL(string: "\(base)/native-handoff")))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "testId": "IPAD-E04-A01-statistics", "case": "A01", "username": "ipad-e04-statistics",
      "statistics": [
        "username": "ipad-e04-statistics", "totalSeconds": 900, "totalSessions": 2,
        "completedBooks": 1, "goalBooks": 24, "source": "ios", "sourceSeconds": 900,
        "earnedAchievementKey": "books_finished_1",
      ],
    ])
    let (_, response) = try await E04FixtureHTTP.data(for: request)
    XCTAssertTrue((200..<300).contains(try XCTUnwrap(response as? HTTPURLResponse).statusCode))
  }

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
