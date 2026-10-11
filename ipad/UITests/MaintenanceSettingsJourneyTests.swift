import Foundation
import XCTest

final class MaintenanceSettingsJourneyTests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  @MainActor
  func testIPADE03A05BaselineSettingsAndConfirmedIdempotentActions() throws {
    let app = signIn(username: "ipad-owner")
    XCTAssertTrue(app.buttons["maintenanceSettingsEntry"].waitForExistence(timeout: 15))
    app.buttons["maintenanceSettingsEntry"].tap()
    let limit = app.textFields["maintenanceUploadLimit"]
    XCTAssertTrue(limit.waitForExistence(timeout: 15))
    limit.tap()
    let previous = limit.value as? String ?? "500"
    limit.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
    limit.typeText("250")
    app.buttons["maintenanceSaveUploadLimit"].tap()
    XCTAssertTrue(app.staticTexts["Settings saved."].waitForExistence(timeout: 15))
    app.buttons["maintenanceSettingsRefresh"].tap()
    waitForValue("250", element: limit)
    let updates = app.switches["maintenanceUpdateChecks"]
    XCTAssertTrue(updates.waitForExistence(timeout: 15))
    let updateValue = updates.value as? String == "1" ? "0" : "1"
    updates.tap()
    app.buttons["maintenanceSaveUpdateChecks"].tap()
    XCTAssertTrue(
      app.buttons["maintenanceSaveUpdateChecks"].wait(for: \.isEnabled, toEqual: false, timeout: 15)
    )
    app.buttons["maintenanceSettingsRefresh"].tap()
    waitForValue(updateValue, element: updates)
    capture("IPAD-E03-A05-baseline-settings-saved")
    app.buttons["maintenanceReviewRecommendations"].tap()
    XCTAssertTrue(app.buttons["maintenanceSettingsConfirm"].waitForExistence(timeout: 15))
    capture("IPAD-E03-A05-recommendation-review")
    app.buttons["Cancel"].tap()
    XCTAssertTrue(app.buttons["maintenanceReviewRecommendations"].waitForExistence(timeout: 15))
    app.buttons["maintenanceReviewRecommendations"].tap()
    app.buttons["maintenanceSettingsConfirm"].tap()
    XCTAssertTrue(app.staticTexts["maintenanceSettingsResult"].waitForExistence(timeout: 30))
    capture("IPAD-E03-A05-recommendation-outcome")
    app.swipeUp()
    let achievements = app.buttons["maintenanceReviewAchievements"]
    XCTAssertTrue(achievements.waitForExistence(timeout: 15))
    XCTAssertTrue(achievements.wait(for: \.isEnabled, toEqual: true, timeout: 60))
    achievements.tap()
    capture("IPAD-E03-A05-achievement-review")
    app.buttons["maintenanceSettingsConfirm"].tap()
    let status = app.staticTexts["maintenanceAchievementStatus"]
    XCTAssertTrue(status.waitForExistence(timeout: 15))
    let completed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label BEGINSWITH 'Reviewed '"), object: status)
    XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 120), .completed)
    capture("IPAD-E03-A05-achievement-outcome")
    app.terminate()
    app.launch()
    XCTAssertTrue(app.buttons["maintenanceSettingsEntry"].waitForExistence(timeout: 30))
    app.buttons["maintenanceSettingsEntry"].tap()
    app.swipeUp()
    XCTAssertTrue(status.waitForExistence(timeout: 15))
    XCTAssertTrue(status.label.hasPrefix("Reviewed "))
    capture("IPAD-E03-A05-baseline-relaunch-reconciled")
    if #available(iOS 17.0, *) {
      try app.performAccessibilityAudit(for: [
        .elementDetection, .hitRegion, .sufficientElementDescription,
      ])
    }
  }

  @MainActor
  func testIPADE03A05BaselineSettingsHiddenFromReader() {
    let app = signIn(username: "ipad-reader")
    XCTAssertFalse(app.buttons["maintenanceSettingsEntry"].exists)
    capture("IPAD-E03-A05-baseline-reader-denied")
  }

  @MainActor
  func testIPADE03A05SettingsPermissionDoesNotExposeSuperuserBackfill() {
    let app = signIn(username: "ipad-settings-admin")
    XCTAssertTrue(app.buttons["maintenanceSettingsEntry"].waitForExistence(timeout: 15))
    app.buttons["maintenanceSettingsEntry"].tap()
    XCTAssertTrue(app.textFields["maintenanceUploadLimit"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.buttons["maintenanceReviewRecommendations"].exists)
    app.swipeUp()
    XCTAssertFalse(app.buttons["maintenanceReviewAchievements"].exists)
    capture("IPAD-E03-A05-settings-permission-without-superuser")
  }

  @MainActor
  private func signIn(username: String) -> XCUIApplication {
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    if !app.textFields["serverURL"].waitForExistence(timeout: 5) {
      if app.buttons["signOut"].exists { app.buttons["signOut"].tap() }
      if app.buttons["Change server"].exists { app.buttons["Change server"].tap() }
    }
    let server = app.textFields["serverURL"]
    XCTAssertTrue(server.waitForExistence(timeout: 10))
    server.tap()
    let old = server.value as? String ?? ""
    server.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.utf16.count))
    server.typeText("http://localhost:16482")
    app.buttons["connectServer"].tap()
    XCTAssertTrue(app.textFields["username"].waitForExistence(timeout: 15))
    app.textFields["username"].tap()
    app.textFields["username"].typeText(username)
    app.secureTextFields["password"].tap()
    app.secureTextFields["password"].typeText("IpadFixture123")
    app.buttons["signIn"].tap()
    XCTAssertTrue(app.buttons["browseAuthors"].waitForExistence(timeout: 30))
    return app
  }

  @MainActor
  private func waitForValue(_ value: String, element: XCUIElement) {
    let saved = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", value), object: element)
    XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 15), .completed)
  }

  @MainActor
  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
