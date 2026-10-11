import Foundation
import XCTest

final class E05AcceptanceJourneyTests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  @MainActor
  func testIPADE05A01ProfilePersistsAcrossRelaunch() throws {
    let app = signIn(username: "ipad-owner")
    openSettings(app)
    tapReachable(app.buttons["profileSettings"], in: app)
    let name = app.textFields["profileName"]
    XCTAssertTrue(name.waitForExistence(timeout: 15))
    replace(name, with: "E05 Native Profile")
    tapReachable(app.buttons["saveProfile"], in: app)
    XCTAssertTrue(app.staticTexts["profileSaved"].waitForExistence(timeout: 15))
    capture("IPAD-E05-A01-native-profile-saved")
    app.terminate()
    app.launch()
    XCTAssertTrue(app.buttons["openSettings"].waitForExistence(timeout: 30))
    openSettings(app)
    tapReachable(app.buttons["profileSettings"], in: app)
    XCTAssertTrue(name.waitForExistence(timeout: 15))
    XCTAssertEqual(name.value as? String, "E05 Native Profile")
    capture("IPAD-E05-A01-native-profile-relaunched")
    if #available(iOS 17.0, *) {
      try app.performAccessibilityAudit(for: [
        .elementDetection, .hitRegion, .sufficientElementDescription,
      ])
    }
  }

  @MainActor
  func testIPADE05A02AccountSwitchDoesNotExposePreviousIdentity() {
    let app = signIn(username: "ipad-owner")
    openSettings(app)
    tapReachable(app.buttons["settingsAccountAccess"], in: app)
    XCTAssertTrue(app.staticTexts["ipad-owner"].waitForExistence(timeout: 15))
    capture("IPAD-E05-A02-native-owner-access")
    tapReachable(app.buttons["accountSwitchUser"], in: app)
    XCTAssertTrue(app.textFields["username"].waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["openSettings"].exists)
    fillCredentials(app, username: "ipad-reader")
    XCTAssertTrue(app.buttons["openSettings"].waitForExistence(timeout: 30))
    openSettings(app)
    tapReachable(app.buttons["settingsAccountAccess"], in: app)
    XCTAssertTrue(app.staticTexts["ipad-reader"].waitForExistence(timeout: 15))
    XCTAssertFalse(app.staticTexts["ipad-owner"].exists)
    capture("IPAD-E05-A02-native-switched-reader")
  }

  @MainActor
  func testIPADE05A03AuthorizedSettingsAdmin() {
    let app = signIn(username: "ipad-editor")
    openSettings(app)
    tapReachable(app.buttons["serverAdministrationSettings"], in: app)
    XCTAssertTrue(app.buttons["adminAuthenticationEntry"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.buttons["adminSystemEntry"].exists)
    XCTAssertFalse(app.buttons["adminUsersEntry"].exists)
    XCTAssertFalse(app.buttons["adminLibrariesEntry"].exists)
    capture("IPAD-E05-A03-native-settings-permission-menu")
    app.buttons["adminAuthenticationEntry"].tap()
    let registration = app.switches["adminRegistrationEnabled"]
    XCTAssertTrue(registration.waitForExistence(timeout: 15))
    let expected = registration.value as? String == "1" ? "0" : "1"
    registration.tap()
    tapReachable(app.buttons["adminSaveRegistration"], in: app)
    XCTAssertTrue(app.staticTexts["Registration policy saved."].waitForExistence(timeout: 15))
    tapReachable(app.buttons["adminReloadAuthentication"], in: app)
    let reloaded = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", expected), object: registration)
    XCTAssertEqual(XCTWaiter.wait(for: [reloaded], timeout: 15), .completed)
    capture("IPAD-E05-A03-native-authentication-policy")
  }

  @MainActor
  func testIPADE05A04ReaderCannotOpenAdministration() {
    let app = signIn(username: "ipad-reader")
    openSettings(app)
    XCTAssertTrue(app.buttons["profileSettings"].waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["serverAdministrationSettings"].exists)
    XCTAssertFalse(app.buttons["adminUsersEntry"].exists)
    capture("IPAD-E05-A04-native-reader-settings")
  }

  @MainActor
  func testIPADE05A05RenewalGuidancePreservesIdentity() {
    let app = signIn(username: "ipad-owner")
    openSettings(app)
    tapReachable(app.buttons["renewalInformation"], in: app)
    XCTAssertTrue(
      app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'AltStore'")).firstMatch
        .waitForExistence(timeout: 15))
    capture("IPAD-E05-A05-native-renewal-guidance")
    app.terminate()
    app.launch()
    XCTAssertTrue(app.buttons["openSettings"].waitForExistence(timeout: 30))
    openSettings(app)
    tapReachable(app.buttons["settingsAccountAccess"], in: app)
    XCTAssertTrue(app.staticTexts["ipad-owner"].waitForExistence(timeout: 15))
    capture("IPAD-E05-A05-native-same-identity-relaunch")
  }

  @MainActor
  private func signIn(username: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    XCUIDevice.shared.orientation = profile.contains("landscape") ? .landscapeLeft : .portrait
    app.launch()
    if !app.textFields["serverURL"].waitForExistence(timeout: 3) {
      if app.buttons["signOut"].exists {
        app.buttons["signOut"].tap()
      } else if app.buttons["openSettings"].exists {
        openSettings(app)
        tapReachable(app.buttons["settingsAccountAccess"], in: app)
        tapReachable(app.buttons["accountSwitchUser"], in: app)
      }
      if app.buttons["Change server"].exists { app.buttons["Change server"].tap() }
    }
    if app.textFields["serverURL"].exists {
      replace(
        app.textFields["serverURL"],
        with: environment("IPAD_E05_SERVER_URL") ?? "http://localhost:16486")
      app.buttons["connectServer"].tap()
    }
    XCTAssertTrue(app.textFields["username"].waitForExistence(timeout: 15))
    fillCredentials(app, username: username)
    XCTAssertTrue(app.buttons["openSettings"].waitForExistence(timeout: 30))
    return app
  }

  @MainActor
  private func fillCredentials(_ app: XCUIApplication, username: String) {
    replace(app.textFields["username"], with: username)
    replace(app.secureTextFields["password"], with: "IpadFixture123")
    app.buttons["signIn"].tap()
  }

  @MainActor
  private func replace(_ element: XCUIElement, with value: String) {
    element.tap()
    let previous = element.value as? String ?? ""
    element.typeText(
      String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.utf16.count))
    element.typeText(value)
  }

  @MainActor
  private func openSettings(_ app: XCUIApplication) {
    tapReachable(app.buttons["openSettings"], in: app)
    XCTAssertTrue(app.buttons["profileSettings"].waitForExistence(timeout: 15))
  }

  @MainActor
  private func tapReachable(_ element: XCUIElement, in app: XCUIApplication) {
    XCTAssertTrue(element.waitForExistence(timeout: 15))
    for _ in 0..<5 where !element.isHittable { app.swipeUp() }
    XCTAssertTrue(element.isHittable)
    element.tap()
  }

  @MainActor
  private var profile: String { environment("IPAD_E05_PROFILE") ?? "pro13-portrait-light" }

  private func environment(_ key: String) -> String? {
    ProcessInfo.processInfo.environment["TEST_RUNNER_\(key)"]
      ?? ProcessInfo.processInfo.environment[key]
  }

  @MainActor
  private func capture(_ name: String) {
    let screenshot = XCUIScreen.main.screenshot()
    XCTAssertEqual(
      screenshot.image.size.width > screenshot.image.size.height, profile.contains("landscape"))
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
