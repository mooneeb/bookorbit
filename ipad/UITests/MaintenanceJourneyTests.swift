import Foundation
import XCTest

final class MaintenanceJourneyTests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  @MainActor
  func testIPADE03A05MaintenancePreviewPagingAndCoverReview() throws {
    let app = signIn(username: "ipad-owner")
    XCTAssertTrue(app.buttons["maintenanceEntry"].waitForExistence(timeout: 15))
    app.buttons["maintenanceEntry"].tap()
    XCTAssertTrue(app.buttons["maintenanceScan"].waitForExistence(timeout: 15))
    capture("IPAD-E03-A05-maintenance-duplicates-preview")
    app.buttons["maintenanceScan"].tap()
    XCTAssertTrue(app.staticTexts["Scan complete"].waitForExistence(timeout: 60))
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Duplicate group '"))
        .firstMatch.exists)
    capture("IPAD-E03-A05-maintenance-duplicate-result")
    app.buttons["maintenanceTool"].tap()
    app.buttons["Missing resources"].tap()
    XCTAssertTrue(app.buttons["maintenanceSweep"].waitForExistence(timeout: 15))
    app.buttons["maintenanceSweep"].tap()
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Cover check complete:'"))
        .firstMatch.waitForExistence(timeout: 60))
    app.buttons["maintenanceReviewCleanup"].tap()
    XCTAssertTrue(
      app.buttons["maintenanceReviewCleanup"].wait(for: \.isEnabled, toEqual: true, timeout: 15))
    capture("IPAD-E03-A05-maintenance-cover-cleanup-preview")
    if #available(iOS 17.0, *) {
      try app.performAccessibilityAudit(for: [
        .elementDetection, .hitRegion, .sufficientElementDescription,
      ])
    }
    XCUIDevice.shared.orientation = .landscapeLeft
    XCTAssertTrue(
      app.buttons["maintenanceReviewCleanup"].wait(for: \.isHittable, toEqual: true, timeout: 10))
    capture("IPAD-E03-A05-maintenance-landscape")
  }

  @MainActor
  func testIPADE03A05MergePreviewApplyAndReadableFileRepair() throws {
    let app = signIn(username: "ipad-owner")
    app.buttons["maintenanceEntry"].tap()
    XCTAssertTrue(app.buttons["maintenanceScan"].waitForExistence(timeout: 15))
    app.buttons["maintenanceScan"].tap()
    XCTAssertTrue(app.staticTexts["Scan complete"].waitForExistence(timeout: 60))
    let configuration = ProcessInfo.processInfo.environment
    let sourceID = try XCTUnwrap(configuration["IPAD_MAINTENANCE_SOURCE_BOOK_ID"])
    let targetID = try XCTUnwrap(configuration["IPAD_MAINTENANCE_TARGET_BOOK_ID"])
    let keeper = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH 'maintenanceKeeper'")
    ).firstMatch
    XCTAssertTrue(keeper.waitForExistence(timeout: 15))
    keeper.tap()
    app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Keep book \(targetID):")
    ).firstMatch.tap()
    let merge = app.buttons["maintenanceMerge\(sourceID)"]
    XCTAssertTrue(merge.waitForExistence(timeout: 15))
    merge.tap()
    XCTAssertTrue(app.buttons["maintenanceApplyMerge"].waitForExistence(timeout: 15))
    capture("IPAD-E03-A05-native-merge-preview")
    app.buttons["maintenanceApplyMerge"].tap()
    XCTAssertTrue(app.staticTexts["maintenanceResult"].waitForExistence(timeout: 30))
    capture("IPAD-E03-A05-native-merge-result")
    app.buttons["maintenanceTool"].tap()
    app.buttons["Missing resources"].tap()
    let bookID = try XCTUnwrap(configuration["IPAD_MAINTENANCE_MISSING_BOOK_ID"])
    let path = try XCTUnwrap(configuration["IPAD_MAINTENANCE_REPLACEMENT_PATH"])
    let missing = app.buttons["maintenanceMissing\(bookID)"]
    XCTAssertTrue(missing.waitForExistence(timeout: 15))
    missing.tap()
    let replacement = app.textFields["maintenanceReplacementPath"]
    XCTAssertTrue(replacement.waitForExistence(timeout: 15))
    replacement.tap()
    replacement.typeText(path + "\n")
    app.buttons["maintenancePreviewRepair"].tap()
    XCTAssertTrue(app.buttons["maintenanceApplyRepair"].waitForExistence(timeout: 15))
    capture("IPAD-E03-A05-native-repair-preview")
    app.buttons["maintenanceApplyRepair"].tap()
    XCTAssertTrue(
      app.staticTexts["File repaired. Reading data was preserved."].waitForExistence(timeout: 30))
    XCTAssertFalse(app.buttons["maintenanceMissing\(bookID)"].exists)
    capture("IPAD-E03-A05-native-repair-result")
  }

  @MainActor
  func testIPADE03A05MaintenanceHiddenWithoutSpecificPermission() {
    let app = signIn(username: "ipad-reader")
    XCTAssertFalse(app.buttons["maintenanceEntry"].exists)
    capture("IPAD-E03-A05-maintenance-reader-denied")
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
  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
