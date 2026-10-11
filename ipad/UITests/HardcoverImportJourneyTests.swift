import Foundation
import XCTest

@MainActor
final class HardcoverImportJourneyTests: XCTestCase {
  private let accessibilityAudit = E04AccessibilityAudit()
  private var server: String {
    ProcessInfo.processInfo.environment["IPAD_E04_BASE_URL"] ?? "http://127.0.0.1:16502"
  }
  private var receiver: String {
    ProcessInfo.processInfo.environment["IPAD_E04_RECEIVER_URL"] ?? "http://127.0.0.1:16509"
  }

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
  }

  override func tearDownWithError() throws {
    if let testRun, testRun.failureCount > 0 { capture("IPAD-E04-A05-HCI-native-failure") }
    accessibilityAudit.reportFailures(testCase: self)
    try super.tearDownWithError()
  }

  func testIPADE04QA5HardcoverNativeImportPreviewApplyRetryAndPages() async throws {
    let session = try await http(
      "auth/login", method: "POST",
      body: [
        "username": "ipad-reader", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "Hardcover import native acceptance",
      ])
    let token = try XCTUnwrap(session["accessToken"] as? String)
    let providerToken = "fixture-native-import"
    try await receiverRequest("control", body: ["provider": "hardcover", "mode": "accept"])
    _ = try await http(
      "hardcover/settings", method: "PATCH", token: token,
      body: [
        "apiToken": providerToken, "enabled": true, "bookSyncMode": "selected_only",
        "autoSyncOnStatusChange": false, "autoSyncOnProgressUpdate": false,
        "autoSyncOnRatingChange": false,
      ])
    _ = try await http("books/1/status", method: "PATCH", token: token, body: ["status": "unread"])
    let externalReadID = 79001
    let userBooks: [[String: Any]] = (0..<101).map { index in
      [
        "id": 70000 + index, "book_id": index == 0 ? 101 : 80000 + index,
        "status_id": 3, "edition_id": 501,
        "book": [
          "id": index == 0 ? 101 : 80000 + index, "title": "Native import fixture",
          "cached_contributors": [],
        ],
      ]
    }
    try await receiverRequest(
      "fixtures",
      body: [
        "provider": "hardcover", "token": providerToken,
        "userBooks": userBooks,
        "reads": [
          [
            "id": externalReadID, "user_book_id": 70000,
            "started_at": "2026-08-01", "finished_at": "2026-08-03", "progress": 100,
          ]
        ],
      ], expectedStatus: 200)
    let app = launchAndSignIn()
    openHardcover(app)
    try await receiverRequest(
      "control", body: ["provider": "hardcover", "mode": "auth", "count": 1])
    tap("hardcoverImport", app: app)
    XCTAssertTrue(app.staticTexts["hardcoverImportError"].waitForExistence(timeout: 15))
    capture("IPAD-E04-A05-HCI-native-preview-failure")
    try await receiverRequest("control", body: ["provider": "hardcover", "mode": "accept"])
    tap("hardcoverImportRetry", app: app)
    XCTAssertTrue(app.buttons["hardcoverImportRow70000"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["hardcoverImportSummary"].label.contains("1 ready"))
    reveal(app.buttons["hardcoverImportRow70000"], app: app)
    XCTAssertEqual(app.buttons["hardcoverImportRow70000"].value as? String, "Selected")
    capture("IPAD-E04-A05-HCI-native-bounded-preview")
    accessibilityAudit.collect(
      app, screen: "IPAD-E04-A05-HCI-native-bounded-preview", testCase: self)
    tap("hardcoverImportApply", app: app)
    tap("hardcoverImportConfirm", app: app)
    XCTAssertTrue(app.staticTexts["hardcoverImportResult"].waitForExistence(timeout: 20))
    XCTAssertTrue(
      app.staticTexts["hardcoverImportResult"].label.contains("1 status records imported"))
    reveal(app.staticTexts["hardcoverImportResult"], app: app)
    capture("IPAD-E04-A05-HCI-native-import-confirmed")
    let book = try await http("books/1", token: token)
    XCTAssertEqual((book["readStatus"] as? [String: Any])?["status"] as? String, "read")
    let history = try await http("books/1/reading-attempts?pageSize=100", token: token)
    let attempts = try XCTUnwrap(history["items"] as? [[String: Any]])
    XCTAssertEqual(
      attempts.filter {
        $0["externalProvider"] as? String == "hardcover"
          && $0["externalId"] as? String == String(externalReadID)
      }.count, 1)
    tap("hardcoverImportRefresh", app: app)
    XCTAssertTrue(app.staticTexts["hardcoverImportSummary"].waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["hardcoverImportRow70000"].isEnabled)
    capture("IPAD-E04-A05-HCI-native-existing-status-preserved")
    tap("hardcoverImportNext", app: app)
    XCTAssertTrue(app.buttons["hardcoverImportRow70100"].waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["hardcoverImportNext"].exists)
    capture("IPAD-E04-A05-HCI-native-final-cursor-page")
    app.terminate()
    app.launch()
    openHardcover(app)
    tap("hardcoverImport", app: app)
    XCTAssertTrue(app.buttons["hardcoverImportRow70000"].waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["hardcoverImportRow70000"].isEnabled)
    capture("IPAD-E04-A05-HCI-native-reconnected-import")
    try await receiverRequest(
      "native-handoff",
      body: [
        "case": "A05", "testId": "testIPADE04QA5HardcoverNativeImportPreviewApplyRetryAndPages",
        "username": "ipad-owner",
        "hardcover": [
          "import": [
            "username": "ipad-reader", "bookId": 1, "externalReadId": String(externalReadID),
            "status": "read", "userBookId": 70000, "startedOn": "2026-08-01",
            "endedOn": "2026-08-03",
          ]
        ],
      ])
    _ = try await http(
      "auth/logout", method: "POST", body: ["refreshToken": session["refreshToken"] ?? ""])
  }

  private func launchAndSignIn() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    E02ProfileSupport.configure(app)
    app.launch()
    if app.buttons["signOut"].waitForExistence(timeout: 3) { app.buttons["signOut"].tap() }
    if app.buttons["Change server"].exists { app.buttons["Change server"].tap() }
    let field = app.textFields["serverURL"]
    XCTAssertTrue(field.wait(for: \.isHittable, toEqual: true, timeout: 10))
    field.tap()
    let existing = field.value as? String ?? ""
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
    field.typeText(server)
    app.buttons["connectServer"].tap()
    XCTAssertTrue(E02ProfileSupport.ensureSignInForm(app: app, serverURL: server))
    app.textFields["username"].tap()
    app.textFields["username"].typeText("ipad-reader")
    app.secureTextFields["password"].tap()
    app.secureTextFields["password"].typeText("IpadFixture123")
    app.buttons["signIn"].tap()
    XCTAssertTrue(app.buttons["signOut"].waitForExistence(timeout: 20))
    return app
  }

  private func openHardcover(_ app: XCUIApplication) {
    let link = app.buttons["hardcoverSettings"]
    XCTAssertTrue(
      E02ProfileSupport.reveal(link, in: app.collectionViews["librarySidebar"], app: app))
    link.tap()
    XCTAssertTrue(app.navigationBars["Hardcover"].waitForExistence(timeout: 15))
  }

  private func reveal(_ element: XCUIElement, app: XCUIApplication) {
    XCTAssertTrue(E02ProfileSupport.reveal(element, in: app.collectionViews.firstMatch, app: app))
  }

  private func tap(_ identifier: String, app: XCUIApplication) {
    let element = app.buttons[identifier]
    reveal(element, app: app)
    XCTAssertTrue(element.wait(for: \.isEnabled, toEqual: true, timeout: 20))
    element.tap()
  }

  private func receiverRequest(_ path: String, body: [String: Any], expectedStatus: Int = 204)
    async throws
  {
    var request = URLRequest(url: URL(string: "\(receiver)/\(path)")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (_, response) = try await E04FixtureHTTP.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, expectedStatus)
  }

  @discardableResult
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

  nonisolated private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
