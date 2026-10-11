import XCTest

final class LibraryManagementJourneyTests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  override func tearDown() async throws {
    if let testRun, testRun.failureCount > 0 {
      let screenshot = await MainActor.run { XCUIScreen.main.screenshot().pngRepresentation }
      let attachment = XCTAttachment(data: screenshot, uniformTypeIdentifier: "public.png")
      attachment.name = "failure-\(name)"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    try await super.tearDown()
  }

  @MainActor
  func testIPADE03ManagementNavigationUsesSpecificPermissions() throws {
    let app = XCUIApplication()
    XCUIDevice.shared.orientation = .portrait
    app.terminate()
    signIn(app, username: "ipad-owner")
    for identifier in [
      "acquisitionEntry", "openServerScanning", "openRequests", "requestAdministration",
      "migrationImportEntry", "entityManagementEntry", "maintenanceEntry",
      "maintenanceSettingsEntry",
    ] {
      assertSidebarContains(identifier, in: app)
    }
    app.buttons["signOut"].tap()
    signIn(app, username: "ipad-editor")
    XCTAssertTrue(app.buttons["entityManagementEntry"].waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["requestAdministration"].exists)
    XCTAssertFalse(app.buttons["migrationImportEntry"].exists)
    XCTAssertFalse(app.buttons["maintenanceSettingsEntry"].exists)
    app.buttons["signOut"].tap()
    signIn(app, username: "ipad-reader")
    XCTAssertTrue(app.buttons["signOut"].waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["entityManagementEntry"].exists)
    XCTAssertFalse(app.buttons["maintenanceEntry"].exists)
    XCTAssertFalse(app.buttons["openServerScanning"].exists)
    XCTAssertFalse(app.buttons["requestAdministration"].exists)
    XCTAssertFalse(app.buttons["migrationImportEntry"].exists)
    XCTAssertFalse(app.buttons["maintenanceSettingsEntry"].exists)
    capture("IPAD-E03-permission-scoped-management-navigation")
  }

  @MainActor
  private func assertSidebarContains(_ identifier: String, in app: XCUIApplication) {
    let sidebar = app.descendants(matching: .any)["librarySidebar"].firstMatch
    for _ in 0..<4 {
      if app.buttons[identifier].exists { return }
      sidebar.swipeUp()
    }
    XCTAssertTrue(app.buttons[identifier].exists, identifier)
  }

  @MainActor
  private func signIn(_ app: XCUIApplication, username: String) {
    if app.state != .runningForeground { app.launch() }
    if !app.textFields["serverURL"].waitForExistence(timeout: 5), app.buttons["signOut"].exists {
      app.buttons["signOut"].tap()
    }
    if app.buttons["Change server"].exists { app.buttons["Change server"].tap() }
    let server = app.textFields["serverURL"]
    XCTAssertTrue(server.waitForExistence(timeout: 10))
    server.tap()
    let old = server.value as? String ?? ""
    if old != "http://localhost:16482" {
      server.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
      server.typeText("http://localhost:16482")
    }
    app.buttons["connectServer"].tap()
    let usernameField = app.textFields["username"]
    XCTAssertTrue(usernameField.waitForExistence(timeout: 10))
    usernameField.tap()
    usernameField.typeText(username)
    app.secureTextFields["password"].tap()
    app.secureTextFields["password"].typeText("IpadFixture123")
    app.buttons["signIn"].tap()
    XCTAssertTrue(app.buttons["signOut"].waitForExistence(timeout: 20))
  }

  @MainActor
  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
