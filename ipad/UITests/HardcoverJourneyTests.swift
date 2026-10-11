import Foundation
import XCTest

@MainActor
final class HardcoverJourneyTests: XCTestCase {
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
    if let testRun, testRun.failureCount > 0 { capture("IPAD-E04-A05-HC-native-failure") }
    accessibilityAudit.reportFailures(testCase: self)
    try super.tearDownWithError()
  }

  func testIPADE04A05HardcoverNativeSettingsMappingFailureRetryAndReconnect() async throws {
    let session = try await http(
      "auth/login", method: "POST",
      body: [
        "username": "ipad-owner", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "Hardcover native acceptance assertions",
      ])
    let token = try XCTUnwrap(session["accessToken"] as? String)
    try await control("accept")
    _ = try await http(
      "hardcover/settings", method: "PATCH", token: token,
      body: [
        "apiToken": "fixture-hardcover", "enabled": false, "bookSyncMode": "selected_only",
        "autoSyncOnStatusChange": false, "autoSyncOnProgressUpdate": false,
        "autoSyncOnRatingChange": false, "privacySettingId": 3,
      ])
    _ = try await http(
      "books/1/status", method: "PATCH", token: token,
      body: [
        "status": "reading", "startedAt": "2026-10-10",
      ])
    _ = try await http(
      "books/1/personal-note", method: "PATCH", token: token,
      body: [
        "note": "HARDCOVER_NATIVE_PRIVATE_NOTE"
      ])
    _ = try await http(
      "hardcover/books/1/sync-state", method: "PATCH", token: token, body: ["syncEnabled": false])
    let app = launchAndSignIn()
    openHardcover(app)
    XCTAssertTrue(app.secureTextFields["hardcoverToken"].waitForExistence(timeout: 15))
    capture("IPAD-E04-A05-HC-native-settings")
    accessibilityAudit.collect(app, screen: "IPAD-E04-A05-HC-native-settings", testCase: self)
    let credential = app.secureTextFields["hardcoverToken"]
    credential.tap()
    credential.typeText("invalid-fixture-hardcover")
    app.buttons["hardcoverValidate"].tap()
    XCTAssertTrue(app.staticTexts["hardcoverError"].waitForExistence(timeout: 15))
    capture("IPAD-E04-A05-HC-native-token-rejected")
    credential.tap()
    credential.typeText(
      String(repeating: XCUIKeyboardKey.delete.rawValue, count: "invalid-fixture-hardcover".count))
    credential.typeText("fixture-hardcover")
    let enabled = app.switches["hardcoverEnabled"]
    if enabled.value as? String == "0" { enabled.tap() }
    tap("hardcoverSave", app: app)
    XCTAssertTrue(app.staticTexts["Settings confirmed by BookOrbit."].waitForExistence(timeout: 15))
    tap("hardcoverRefresh", app: app)
    let book = app.buttons["hardcoverBook1"]
    reveal(book, app: app)
    XCTAssertTrue(book.wait(for: \.isHittable, toEqual: true, timeout: 15))
    book.tap()
    XCTAssertTrue(app.navigationBars["Hardcover book"].waitForExistence(timeout: 10))
    tap("hardcoverBookInclude", app: app)
    XCTAssertTrue(
      app.staticTexts["Book selection confirmed. Refresh to check any resulting sync."]
        .waitForExistence(timeout: 15))
    _ = try await waitState(token: token) {
      $0["lastSyncedAt"] is String && $0["syncError"] is NSNull
    }
    _ = try await http(
      "books/bulk-set-rating", method: "POST", token: token, body: ["bookIds": [1], "rating": 4])
    tap("hardcoverBookSync", app: app)
    XCTAssertTrue(
      app.staticTexts["Reading record confirmed by Hardcover."].waitForExistence(timeout: 30))
    tap("hardcoverBookEditions", app: app)
    let edition = app.buttons["hardcoverEdition501"]
    reveal(edition, app: app)
    XCTAssertTrue(edition.wait(for: \.isHittable, toEqual: true, timeout: 15))
    edition.tap()
    XCTAssertTrue(app.staticTexts["Edition 501 selected."].waitForExistence(timeout: 30))
    XCTAssertTrue(app.staticTexts["hardcoverBookLastSynced"].label.hasPrefix("Last synced:"))
    capture("IPAD-E04-A05-HC-native-mapped-record")
    let first = try await providerReceipts()
    let records = try XCTUnwrap(first["userBooks"] as? [[String: Any]])
    let matching = records.filter { $0["book_id"] as? Int == 101 }
    XCTAssertEqual(matching.count, 1)
    XCTAssertEqual(matching.first?["rating"] as? Int, 4)
    XCTAssertEqual(matching.first?["privacy_setting_id"] as? Int, 3)
    XCTAssertFalse(String(describing: first).contains("HARDCOVER_NATIVE_PRIVATE_NOTE"))
    app.navigationBars["Hardcover book"].buttons.element(boundBy: 0).tap()
    try await verifyNoMatchFeedback(app, token: token)
    _ = try await http(
      "books/bulk-set-rating", method: "POST", token: token, body: ["bookIds": [1], "rating": 5])
    try await control("auth")
    tap("hardcoverSync", app: app)
    XCTAssertTrue(app.staticTexts["Failed"].waitForExistence(timeout: 30))
    capture("IPAD-E04-A05-HC-native-auth-failure")
    tap("hardcoverBook1", app: app)
    XCTAssertTrue(app.staticTexts["hardcoverBookSyncError"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["hardcoverBookLastSynced"].label.hasPrefix("Last checked:"))
    XCTAssertFalse(app.staticTexts["Reading record confirmed by Hardcover."].exists)
    capture("IPAD-E04-A05-HC-native-previous-check-provider-failure")
    app.navigationBars["Hardcover book"].buttons.element(boundBy: 0).tap()
    app.terminate()
    app.launch()
    openHardcover(app)
    XCTAssertTrue(app.staticTexts["Failed"].waitForExistence(timeout: 15))
    capture("IPAD-E04-A05-HC-native-reconnected-durable-failure")
    try await control("accept")
    tap("hardcoverSync", app: app)
    XCTAssertTrue(app.staticTexts["Completed"].waitForExistence(timeout: 40))
    capture("IPAD-E04-A05-HC-native-retry-confirmed")
    accessibilityAudit.collect(
      app, screen: "IPAD-E04-A05-HC-native-retry-confirmed", testCase: self)
    let outcome = try await http("hardcover/sync/outcome", token: token)
    XCTAssertEqual(outcome["status"] as? String, "completed")
    let final = try await providerReceipts()
    let finalBooks = try XCTUnwrap(final["userBooks"] as? [[String: Any]])
    XCTAssertEqual(finalBooks.filter { $0["book_id"] as? Int == 101 }.count, 1)
    XCTAssertEqual(final["totalReads"] as? Int, first["totalReads"] as? Int)
    try await receiverRequest(
      "native-handoff",
      body: [
        "case": "A05",
        "testId": "testIPADE04A05HardcoverNativeSettingsMappingFailureRetryAndReconnect",
        "username": "ipad-owner",
        "hardcover": [
          "bookId": 1, "hardcoverBookId": 101, "editionId": 501, "enabled": true,
          "privacySettingId": 3, "expectedStatus": "completed", "username": "fixture-hardcover",
          "rating": 5, "runId": outcome["runId"] ?? 0,
        ],
      ])
    _ = try await http(
      "auth/logout", method: "POST", body: ["refreshToken": session["refreshToken"] ?? ""])
  }

  private func verifyNoMatchFeedback(_ app: XCUIApplication, token: String) async throws {
    let detail = try await http("books/2", token: token)
    let previous = try await http("hardcover/books/2/sync-state", token: token)
    XCTAssertTrue(previous["lastSyncedAt"] is NSNull, "The no-match probe needs an unmapped book")
    let before = try await providerReceipts()
    let previousRecords = try XCTUnwrap(before["userBooks"] as? [[String: Any]])
      .filter { $0["book_id"] as? Int == 102 }.count
    try await control("search-empty", operation: "SearchBooks")
    _ = try await http(
      "books/2/metadata", method: "PATCH", token: token,
      body: [
        "authors": ["E04 Search Author"], "hardcoverId": NSNull(),
        "isbn10": NSNull(), "isbn13": NSNull(),
      ])
    _ = try await http(
      "books/2/status", method: "PATCH", token: token,
      body: [
        "status": "reading", "startedAt": "2026-10-11",
      ])
    _ = try await http(
      "hardcover/books/2/sync-state", method: "PATCH", token: token,
      body: ["syncEnabled": true])
    _ = try await waitState(token: token, bookID: 2) {
      $0["syncError"] as? String == "no_match" && $0["lastSyncedAt"] is String
    }
    tap("hardcoverRefresh", app: app)
    tap("hardcoverBook2", app: app)
    let feedback = "No matching Hardcover book was found. No reading record was sent."
    XCTAssertTrue(app.staticTexts[feedback].waitForExistence(timeout: 15))
    XCTAssertTrue(
      app.staticTexts["hardcoverBookLastSynced"].label.hasPrefix("Last checked (no match):"))
    XCTAssertFalse(app.staticTexts["Reading record confirmed by Hardcover."].exists)
    capture("IPAD-E04-A05-HC-native-no-match-checked")
    tap("hardcoverBookSync", app: app)
    XCTAssertTrue(app.staticTexts["hardcoverBookMessage"].waitForExistence(timeout: 15))
    XCTAssertEqual(app.staticTexts["hardcoverBookMessage"].label, feedback)
    let repeated = try await http("hardcover/books/2/sync-state", token: token)
    XCTAssertEqual(repeated["syncError"] as? String, "no_match")
    let after = try await providerReceipts()
    let records = try XCTUnwrap(after["userBooks"] as? [[String: Any]])
    XCTAssertEqual(records.filter { $0["book_id"] as? Int == 102 }.count, previousRecords)
    XCTAssertEqual(after["totalReads"] as? Int, before["totalReads"] as? Int)
    app.navigationBars["Hardcover book"].buttons.element(boundBy: 0).tap()
    try await control("accept")
    let providerIDs = detail["providerIds"] as? [String: Any] ?? [:]
    _ = try await http(
      "books/2/metadata", method: "PATCH", token: token,
      body: [
        "authors": (detail["authors"] as? [[String: Any]] ?? []).compactMap {
          $0["name"] as? String
        },
        "hardcoverId": providerIDs["hardcover"] ?? NSNull(),
        "isbn10": detail["isbn10"] ?? NSNull(), "isbn13": detail["isbn13"] ?? NSNull(),
      ])
    let readStatus = detail["readStatus"] as? [String: Any] ?? [:]
    _ = try await http(
      "books/2/status", method: "PATCH", token: token,
      body: [
        "status": readStatus["status"] ?? "unread",
        "startedAt": readStatus["startedAt"] ?? NSNull(),
        "finishedAt": readStatus["finishedAt"] ?? NSNull(),
      ])
    _ = try await http(
      "hardcover/books/2/sync-state", method: "PATCH", token: token,
      body: ["syncEnabled": false])
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
    app.textFields["username"].typeText("ipad-owner")
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

  private func waitState(token: String, bookID: Int = 1, condition: ([String: Any]) -> Bool)
    async throws -> [String:
    Any]
  {
    let deadline = Date().addingTimeInterval(30)
    repeat {
      let state = try await http("hardcover/books/\(bookID)/sync-state", token: token)
      if condition(state) { return state }
      try await Task.sleep(for: .milliseconds(200))
    } while Date() < deadline
    XCTFail("Hardcover book state did not converge")
    return [:]
  }

  private func providerReceipts() async throws -> [String: Any] {
    let (data, response) = try await E04FixtureHTTP.data(
      from: URL(string: "\(receiver)/receipts?provider=hardcover&limit=100")!)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try XCTUnwrap(result["hardcover"] as? [String: Any])
  }

  private func control(_ mode: String, operation: String? = nil) async throws {
    var body: [String: Any] = ["provider": "hardcover", "mode": mode]
    if let operation { body["operation"] = operation }
    try await receiverRequest("control", body: body)
  }

  private func receiverRequest(_ path: String, body: [String: Any]) async throws {
    var request = URLRequest(url: URL(string: "\(receiver)/\(path)")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (_, response) = try await E04FixtureHTTP.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
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
