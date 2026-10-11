import Foundation
import XCTest

@MainActor
final class ReadwiseJourneyTests: XCTestCase {
  private let accessibilityAudit = E04AccessibilityAudit()
  private var server: String {
    ProcessInfo.processInfo.environment["IPAD_E04_BASE_URL"] ?? "http://127.0.0.1:16502"
  }
  private var receiver: String {
    ProcessInfo.processInfo.environment["IPAD_E04_RECEIVER_URL"] ?? "http://127.0.0.1:17489"
  }

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
  }

  override func tearDownWithError() throws {
    if let testRun, testRun.failureCount > 0 { capture("IPAD-E04-QA5-Readwise-failure") }
    accessibilityAudit.reportFailures(testCase: self)
    try super.tearDownWithError()
  }

  func testIPADE04QA5ReadwiseNativeExportAuthRecoveryAndReceivedHighlights() async throws {
    let login = try await http(
      "auth/login", method: "POST",
      body: [
        "username": "ipad-owner", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "Readwise native acceptance control",
      ])
    let token = try XCTUnwrap(login["accessToken"] as? String)
    let refreshToken = try XCTUnwrap(login["refreshToken"] as? String)
    let otherLogin = try await http(
      "auth/login", method: "POST",
      body: [
        "username": "ipad-reader", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "Readwise user scope control",
      ])
    let otherToken = try XCTUnwrap(otherLogin["accessToken"] as? String)
    let otherRefresh = try XCTUnwrap(otherLogin["refreshToken"] as? String)
    let marker = "readwise-native-\(UUID().uuidString)"
    var annotationIDs: [Int] = []
    defer {
      Task {
        try? await control("accept")
        _ = try? await http("auth/logout", method: "POST", body: ["refreshToken": refreshToken])
        _ = try? await http("auth/logout", method: "POST", body: ["refreshToken": otherRefresh])
      }
    }
    try await control("accept")
    _ = try await createHighlight("\(marker)-other-user", token: otherToken)
    _ = try await http(
      "readwise/settings", method: "PATCH", token: token,
      body: ["apiToken": "fixture-native-readwise", "enabled": false])
    let initial = try await createHighlight("\(marker)-first", token: token)
    annotationIDs.append(initial)
    let app = launchAndSignIn()
    openReadwise(app)
    XCTAssertTrue(app.secureTextFields["readwiseToken"].waitForExistence(timeout: 10))
    capture("IPAD-E04-A05-RW-native-settings")
    accessibilityAudit.collect(app, screen: "IPAD-E04-A05-RW-native-settings", testCase: self)
    let tokenField = app.secureTextFields["readwiseToken"]
    tokenField.tap()
    tokenField.typeText("invalid-fixture-readwise")
    tap("readwiseValidateToken", app: app)
    XCTAssertTrue(
      app.staticTexts["Token validation failed. Check the token and connection, then try again."]
        .waitForExistence(timeout: 10))
    capture("IPAD-E04-A05-RW-native-invalid-token")
    tokenField.tap()
    tokenField.typeText(
      String(repeating: XCUIKeyboardKey.delete.rawValue, count: "invalid-fixture-readwise".count))
    tokenField.typeText("fixture-native-readwise")
    let enabled = app.switches["readwiseEnabled"]
    if enabled.value as? String == "0" { enabled.tap() }
    app.switches["readwiseIncludeExisting"].tap()
    tap("readwiseSaveSettings", app: app)
    XCTAssertTrue(app.staticTexts["Readwise settings saved."].waitForExistence(timeout: 10))
    tap("readwiseSyncNow", app: app)
    XCTAssertTrue(app.staticTexts["Delivery confirmed"].waitForExistence(timeout: 20))
    XCTAssertTrue(app.staticTexts["readwiseReceivedBookIds"].exists)
    let firstReceived = try await receivedHighlight("\(marker)-first")
    XCTAssertEqual(firstReceived["note"] as? String, "Native text note")
    XCTAssertTrue(
      (firstReceived["highlight_url"] as? String)?.hasSuffix("annotationId=\(initial)") == true)
    XCTAssertNil(firstReceived["drawing"])
    capture("IPAD-E04-A05-RW-native-delivery-confirmed")
    accessibilityAudit.collect(
      app, screen: "IPAD-E04-A05-RW-native-delivery-confirmed", testCase: self)
    try await control("auth")
    let recovery = try await createHighlight("\(marker)-reconnect", token: token)
    annotationIDs.append(recovery)
    tap("readwiseSyncNow", app: app)
    XCTAssertTrue(app.staticTexts["Delivery failed"].waitForExistence(timeout: 20))
    XCTAssertTrue(app.staticTexts["readwiseReconnectMessage"].waitForExistence(timeout: 10))
    capture("IPAD-E04-A05-RW-native-auth-rejection")
    app.terminate()
    app.launch()
    openReadwise(app)
    XCTAssertTrue(app.staticTexts["Delivery failed"].waitForExistence(timeout: 15))
    capture("IPAD-E04-A05-RW-native-restarted-durable-failure")
    try await control("accept")
    let reconnectToken = app.secureTextFields["readwiseToken"]
    reconnectToken.tap()
    reconnectToken.typeText("fixture-native-readwise-reconnected")
    if app.switches["readwiseEnabled"].value as? String == "0" {
      app.switches["readwiseEnabled"].tap()
    }
    tap("readwiseSaveSettings", app: app)
    XCTAssertTrue(app.staticTexts["Readwise settings saved."].waitForExistence(timeout: 10))
    tap("readwiseSyncNow", app: app)
    XCTAssertTrue(app.staticTexts["Delivery confirmed"].waitForExistence(timeout: 20))
    _ = try await receivedHighlight("\(marker)-reconnect")
    let afterReconnect = try await allReceipts()
    XCTAssertEqual(afterReconnect.filter { ($0["text"] as? String) == "\(marker)-first" }.count, 1)
    capture("IPAD-E04-A05-RW-native-reconnected")
    XCUIDevice.shared.orientation = .landscapeLeft
    XCTAssertTrue(
      app.buttons["readwiseRefreshStatus"].wait(for: \.isHittable, toEqual: true, timeout: 5))
    capture("IPAD-E04-A05-RW-native-reconnected-landscape")
    XCUIDevice.shared.orientation = .portrait
    let finalStatus = try await http("readwise/sync/status", token: token)
    try await publishHandoff([
      "case": "A05",
      "testId": "testIPADE04QA5ReadwiseNativeExportAuthRecoveryAndReceivedHighlights",
      "username": "ipad-owner",
      "excludedTexts": ["\(marker)-other-user"],
      "readwise": [
        "bookId": 1, "annotationIds": annotationIDs,
        "enabled": true, "expectedHighlightTexts": ["\(marker)-first", "\(marker)-reconnect"],
        "state": finalStatus["state"] ?? "unknown",
        "receivedBookIds": finalStatus["receivedBookIds"] ?? [],
      ],
    ])
  }

  private func publishHandoff(_ body: [String: Any]) async throws {
    var request = URLRequest(url: URL(string: "\(receiver)/native-handoff")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (_, response) = try await E04FixtureHTTP.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
  }

  private func launchAndSignIn() -> XCUIApplication {
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
    app.textFields["username"].typeText("ipad-owner")
    app.secureTextFields["password"].tap()
    app.secureTextFields["password"].typeText("IpadFixture123")
    app.buttons["signIn"].tap()
    return app
  }

  private func tap(_ identifier: String, app: XCUIApplication) {
    let button = app.buttons[identifier]
    for _ in 0..<8 {
      if button.exists && button.isHittable { break }
      app.swipeUp()
    }
    XCTAssertTrue(button.wait(for: \.isEnabled, toEqual: true, timeout: 10))
    XCTAssertTrue(button.isHittable)
    button.tap()
  }

  private func openReadwise(_ app: XCUIApplication) {
    let link = app.buttons["readwiseSettingsLink"]
    XCTAssertTrue(app.collectionViews["librarySidebar"].waitForExistence(timeout: 20))
    XCTAssertTrue(
      E02ProfileSupport.reveal(link, in: app.collectionViews["librarySidebar"], app: app))
    link.tap()
    XCTAssertTrue(app.buttons["readwiseSaveSettings"].waitForExistence(timeout: 10))
  }

  private func createHighlight(_ text: String, token: String) async throws -> Int {
    let result = try await http(
      "books/1/annotations", method: "POST", token: token,
      body: [
        "cfi": "epubcfi(/6/2!/4/2:0)", "text": text, "note": "Native text note",
        "color": "yellow", "style": "highlight",
      ])
    return try XCTUnwrap(result["id"] as? Int)
  }

  private func control(_ mode: String) async throws {
    var request = URLRequest(url: URL(string: "\(receiver)/control")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "provider": "readwise", "mode": mode,
    ])
    let (_, response) = try await E04FixtureHTTP.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
  }

  private func allReceipts() async throws -> [[String: Any]] {
    var accepted: [[String: Any]] = []
    var offset = 0
    while offset < 10_000 {
      let (data, response) = try await E04FixtureHTTP.data(
        from: URL(string: "\(receiver)/receipts?limit=100&offset=\(offset)")!)
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
      let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
      let provider = try XCTUnwrap(result["readwise"] as? [String: Any])
      let rows = try XCTUnwrap(provider["highlights"] as? [[String: Any]])
      accepted.append(contentsOf: rows)
      offset += rows.count
      if rows.count < 100 { return accepted }
    }
    XCTFail("Controlled Readwise receipt limit exceeded")
    return accepted
  }

  private func receivedHighlight(_ text: String) async throws -> [String: Any] {
    let matches = try await allReceipts().filter { ($0["text"] as? String) == text }
    XCTAssertEqual(matches.count, 1)
    return try XCTUnwrap(matches.first)
  }

  @discardableResult
  private func http(
    _ path: String, method: String = "GET", token: String? = nil, body: [String: Any]? = nil
  ) async throws -> [String: Any] {
    var request = URLRequest(url: URL(string: "\(server)/api/v1/\(path)")!)
    request.httpMethod = method
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
