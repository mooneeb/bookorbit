import CryptoKit
import Foundation
import XCTest

final class StoryGraphJourneyTests: XCTestCase {
  private let accessibilityAudit = E04AccessibilityAudit()
  private let remoteID = "e0400000-0000-4000-8000-000000000101"
  private var server: String {
    ProcessInfo.processInfo.environment["IPAD_E04_BASE_URL"]
      ?? ProcessInfo.processInfo.environment["TEST_RUNNER_IPAD_E04_BASE_URL"]
      ?? "http://127.0.0.1:16502"
  }
  private var receiver: String {
    get throws {
      try XCTUnwrap(
        ProcessInfo.processInfo.environment["IPAD_E04_RECEIVER_URL"]
          ?? ProcessInfo.processInfo.environment["TEST_RUNNER_IPAD_E04_RECEIVER_URL"])
    }
  }

  override func setUpWithError() throws {
    continueAfterFailure = false
    try super.setUpWithError()
  }

  override func tearDownWithError() throws {
    accessibilityAudit.reportFailures(testCase: self)
    try super.tearDownWithError()
  }

  @MainActor
  func testIPADE04A05StoryGraphConnectionMappingAndRetry() async throws {
    try await control("accept")
    let credentials = try await http(
      "auth/login", method: "POST",
      body: [
        "username": "ipad-owner", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "StoryGraph UI fixture setup",
      ])
    let token = try XCTUnwrap(credentials["accessToken"] as? String)
    let refresh = try XCTUnwrap(credentials["refreshToken"] as? String)
    addTeardownBlock { [server] in
      var request = URLRequest(url: URL(string: "\(server)/api/v1/auth/logout")!)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: ["refreshToken": refresh])
      _ = try await E04FixtureHTTP.data(for: request)
    }
    _ = try await http("books/1/status", method: "PATCH", token: token, body: ["status": "reading"])
    _ = try await http(
      "books/files/1/progress", method: "POST", token: token,
      body: ["percentage": 42, "source": "text"])
    _ = try await http(
      "storygraph/settings", method: "PATCH", token: token,
      body: [
        "sessionCookie": "e04-native-storygraph", "rememberToken": "e04-native-remember",
        "enabled": false, "bookSyncMode": "selected_only",
        "autoSyncOnStatusChange": false, "autoSyncOnProgressUpdate": false,
      ])
    let app = launchAndSignIn("ipad-owner")
    openSettings(app)
    capture("IPAD-E04-A05-SG-native-settings")
    XCTAssertTrue(
      app.staticTexts[
        "Import, ratings, personal notes, highlights, and book files are not supported by this integration."
      ].exists)
    let cookie = app.secureTextFields["storygraphSessionCookie"]
    reveal(cookie, app: app)
    cookie.tap()
    cookie.typeText("e04-native-storygraph")
    let remember = app.secureTextFields["storygraphRememberToken"]
    remember.tap()
    remember.typeText("e04-native-remember")
    let enabled = app.switches["Enable StoryGraph sync"]
    reveal(enabled, app: app)
    if enabled.value as? String == "0" { enabled.tap() }
    reveal(app.buttons["storygraphSave"], app: app)
    app.buttons["storygraphSave"].tap()
    XCTAssertTrue(app.staticTexts["storygraphResult"].waitForExistence(timeout: 10))
    reveal(app.buttons["storygraphValidate"], app: app)
    app.buttons["storygraphValidate"].tap()
    XCTAssertTrue(
      app.staticTexts["StoryGraph accepted the connection."].waitForExistence(timeout: 15))
    capture("IPAD-E04-A05-SG-native-connected")
    accessibilityAudit.collect(app, screen: "IPAD-E04-A05-SG-native-connected", testCase: self)
    let match = app.buttons["storygraphMatch1"]
    reveal(match, app: app)
    match.tap()
    let included = app.switches["storygraphBookSelected"]
    XCTAssertTrue(included.waitForExistence(timeout: 10))
    if included.value as? String == "0" { included.tap() }
    app.buttons["Save book selection"].tap()
    XCTAssertTrue(
      app.staticTexts["Book included in StoryGraph sync."].waitForExistence(timeout: 10))
    let link = app.textFields["storygraphBookLinkInput"]
    reveal(link, app: app)
    link.tap()
    link.typeText(remoteID)
    app.buttons["storygraphBookLink"].tap()
    XCTAssertTrue(
      app.staticTexts["StoryGraph match saved. Review the sync outcome below."].waitForExistence(
        timeout: 30))
    let first = try await receivedBook()
    XCTAssertEqual(first["status"] as? String, "currently-reading")
    XCTAssertEqual(first["progress"] as? Int, 42)
    capture("IPAD-E04-A05-SG-native-mapped-provider-result")
    reveal(app.buttons["storygraphEditions"], app: app)
    app.buttons["storygraphEditions"].tap()
    let edition = app.buttons["storygraphEdition\(remoteID)"]
    XCTAssertTrue(edition.waitForExistence(timeout: 15))
    reveal(edition, app: app)
    edition.tap()
    XCTAssertTrue(
      app.staticTexts["StoryGraph edition selected. Review the sync outcome below."]
        .waitForExistence(timeout: 20))
    _ = try await http(
      "books/files/1/progress", method: "POST", token: token,
      body: ["percentage": 43, "source": "text"])
    try await control("auth")
    reveal(app.buttons["Refresh book result"], app: app)
    app.buttons["Refresh book result"].tap()
    let sync = app.buttons["storygraphBookSync"]
    reveal(sync, app: app)
    XCTAssertTrue(sync.wait(for: \.isEnabled, toEqual: true, timeout: 10))
    sync.tap()
    XCTAssertTrue(app.staticTexts["storygraphBookError"].waitForExistence(timeout: 20))
    capture("IPAD-E04-A05-SG-native-auth-failure")
    app.terminate()
    try await control("accept")
    app.launch()
    openSettings(app)
    reveal(app.buttons["storygraphMatch1"], app: app)
    app.buttons["storygraphMatch1"].tap()
    XCTAssertTrue(app.staticTexts["storygraphBookSyncError"].waitForExistence(timeout: 10))
    capture("IPAD-E04-A05-SG-native-reconnected-retained-failure")
    reveal(app.buttons["storygraphBookSync"], app: app)
    app.buttons["storygraphBookSync"].tap()
    XCTAssertTrue(
      app.staticTexts["StoryGraph accepted the reading status and supported progress."]
        .waitForExistence(timeout: 25))
    let acceptedRetry = try await receivedBook()
    XCTAssertEqual(acceptedRetry["progress"] as? Int, 43)
    capture("IPAD-E04-A05-SG-native-retry-confirmed")
    accessibilityAudit.collect(
      app, screen: "IPAD-E04-A05-SG-native-retry-confirmed", testCase: self)
    try await handoff()
  }

  @MainActor
  func testIPADE04A05StoryGraphRestrictedControls() {
    let app = launchAndSignIn("ipad-restricted")
    XCTAssertTrue(app.staticTexts["0 books"].waitForExistence(timeout: 20))
    XCTAssertFalse(app.buttons["storygraphSettings"].exists)
    capture("IPAD-E04-A05-SG-native-restricted")
  }

  @MainActor private func launchAndSignIn(_ username: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    if app.buttons["signOut"].waitForExistence(timeout: 3) { app.buttons["signOut"].tap() }
    if app.buttons["Change server"].exists { app.buttons["Change server"].tap() }
    let field = app.textFields["serverURL"]
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    field.tap()
    field.typeText(
      String(
        repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String ?? "").count))
    field.typeText(server)
    app.buttons["connectServer"].tap()
    XCTAssertTrue(app.textFields["username"].waitForExistence(timeout: 10))
    app.textFields["username"].tap()
    app.textFields["username"].typeText(username)
    app.secureTextFields["password"].tap()
    app.secureTextFields["password"].typeText("IpadFixture123")
    app.buttons["signIn"].tap()
    return app
  }

  @MainActor private func openSettings(_ app: XCUIApplication) {
    let entry = app.buttons["storygraphSettings"]
    XCTAssertTrue(entry.wait(for: \.isHittable, toEqual: true, timeout: 20))
    entry.tap()
    XCTAssertTrue(app.buttons["storygraphSave"].waitForExistence(timeout: 15))
  }

  @MainActor private func reveal(_ element: XCUIElement, app: XCUIApplication) {
    for _ in 0..<12 {
      if element.exists && element.isHittable { return }
      let list = app.collectionViews.firstMatch
      if element.exists && element.frame.minY < list.frame.minY {
        list.swipeDown()
      } else {
        list.swipeUp()
      }
    }
    XCTAssertTrue(element.isHittable, "StoryGraph control must be reachable: \(element.identifier)")
  }

  @MainActor
  private func http(
    _ path: String, method: String = "GET", token: String? = nil, body: [String: Any]? = nil
  ) async throws -> [String: Any] {
    var request = URLRequest(url: URL(string: "\(server)/api/v1/\(path)")!)
    request.httpMethod = method
    request.timeoutInterval = 45
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await E04FixtureHTTP.data(for: request)
    XCTAssertTrue((200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0), path)
    return data.isEmpty
      ? [:] : try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @MainActor
  private func control(_ mode: String) async throws {
    var request = URLRequest(url: URL(string: "\(try receiver)/control")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "provider": "storygraph", "mode": mode,
    ])
    let (_, response) = try await E04FixtureHTTP.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
  }

  @MainActor
  private func receivedBook() async throws -> [String: Any] {
    let (data, response) = try await E04FixtureHTTP.data(
      from: URL(string: "\(try receiver)/receipts?provider=storygraph&limit=100")!)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    let receipts = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let provider = try XCTUnwrap(receipts["storygraph"] as? [String: Any])
    let books = try XCTUnwrap(provider["books"] as? [[String: Any]])
    let namespace = SHA256.hash(
      data: Data(
        "remember_user_token=e04-native-remember; _storygraph_session=e04-native-storygraph".utf8)
    )
    .map { String(format: "%02x", $0) }.joined().prefix(12)
    return try XCTUnwrap(
      books.first {
        $0["id"] as? String == remoteID && $0["namespace"] as? String == String(namespace)
      })
  }

  @MainActor
  private func handoff() async throws {
    var request = URLRequest(url: URL(string: "\(try receiver)/native-handoff")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "testId": "IPAD-E04-A05", "case": "A05", "username": "ipad-owner",
      "storygraph": ["enabled": true, "remoteBookIds": [remoteID]],
    ])
    let (_, response) = try await E04FixtureHTTP.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
  }

  private func capture(_ name: String) {
    let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    image.name = name
    image.lifetime = .keepAlways
    add(image)
  }
}
