import Foundation
import XCTest

final class AnnotationHubJourneyTests: XCTestCase {
  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
  }

  override func tearDown() async throws {
    if let testRun, testRun.failureCount > 0 {
      let screenshot = await MainActor.run { XCUIScreen.main.screenshot().pngRepresentation }
      let attachment = XCTAttachment(data: screenshot, uniformTypeIdentifier: "public.png")
      attachment.name = "IPAD-E02-A07-hub-failure-\(name)"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    try await super.tearDown()
  }

  @MainActor
  func testIPADE02A07HubEntryAndBoundedSearch() throws {
    let app = XCUIApplication()
    let profile = ProcessInfo.processInfo.environment["IPAD_E02_PROFILE"] ?? "pro13-portrait-light"
    app.launchArguments = [
      "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
      "-AppleInterfaceStyle", profile.contains("dark") ? "Dark" : "Light",
      "-UIPreferredContentSizeCategoryName",
      profile.contains("large") ? "UICTContentSizeCategoryXXXL" : "UICTContentSizeCategoryL",
    ]
    XCUIDevice.shared.orientation = profile.contains("landscape") ? .landscapeLeft : .portrait
    E02ProfileSupport.configure(app)
    app.launch()
    if app.buttons["signOut"].waitForExistence(timeout: 3) { app.buttons["signOut"].tap() }
    if app.buttons["Change server"].exists { app.buttons["Change server"].tap() }
    let server = app.textFields["serverURL"]
    XCTAssertTrue(server.waitForExistence(timeout: 10))
    server.tap()
    let existing = server.value as? String ?? ""
    if existing != "http://localhost:16482" {
      server.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
      server.typeText("http://localhost:16482")
    }
    app.buttons["connectServer"].tap()
    let username = app.textFields["username"]
    XCTAssertTrue(username.waitForExistence(timeout: 10))
    username.tap()
    username.typeText("ipad-owner")
    app.secureTextFields["password"].tap()
    app.secureTextFields["password"].typeText("IpadFixture123")
    app.buttons["signIn"].tap()
    XCTAssertTrue(app.buttons["openAnnotationHub"].waitForExistence(timeout: 20))
    app.buttons["openAnnotationHub"].tap()
    XCTAssertTrue(app.searchFields["annotationHubSearch"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.buttons["annotationHubFilters"].exists)
    XCTAssertTrue(app.buttons["annotationHubDevices"].exists)
    XCTAssertLessThanOrEqual(
      app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "annotationHubItem"))
        .count, 40)
    capture("IPAD-E02-A07-hub-entry")
    try app.performAccessibilityAudit()
    app.searchFields["annotationHubSearch"].tap()
    app.searchFields["annotationHubSearch"].typeText("NoSuchConvertedPassageFixture\n")
    XCTAssertTrue(app.staticTexts["annotationHubEmpty"].waitForExistence(timeout: 15))
    XCTAssertEqual(
      app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "annotationHubItem"))
        .count, 0)
    capture("IPAD-E02-A07-hub-text-only-search-empty")
    try app.performAccessibilityAudit()
    app.buttons["annotationHubFilters"].tap()
    XCTAssertTrue(app.buttons["annotationHubApplyFilters"].waitForExistence(timeout: 5))
    capture("IPAD-E02-A07-hub-filters")
    try app.performAccessibilityAudit()
    app.buttons["Cancel"].tap()
    app.buttons["annotationHubDone"].tap()
  }

  @MainActor
  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    let profile = ProcessInfo.processInfo.environment["IPAD_E02_PROFILE"] ?? "pro13-portrait-light"
    attachment.name = "\(name)-\(profile)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
