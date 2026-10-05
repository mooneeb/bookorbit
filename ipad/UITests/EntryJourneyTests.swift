import Foundation
import XCTest

final class EntryJourneyTests: XCTestCase {
  @MainActor
  func testIPADE01A01LocalLoginAndRelaunch() async throws {
    let app = launchAtServerEntry()
    connect(app)
    signIn(app)
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    XCTAssertTrue(app.staticTexts["Library book 00001"].exists)
    capture(app, "IPAD-E01-A01-library-portrait")
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.tap()
    search.typeText("Orbit fixture\n")
    XCTAssertTrue(app.buttons["Orbit fixture"].firstMatch.waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["Library book 00001"].exists)
    app.buttons["Orbit fixture"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts["PDF"].waitForExistence(timeout: 10))
    capture(app, "IPAD-E01-A01-book-detail")
    app.buttons["Done"].tap()
    XCUIDevice.shared.orientation = .landscapeLeft
    XCTAssertTrue(app.buttons["Orbit fixture"].firstMatch.waitForExistence(timeout: 10))
    capture(app, "IPAD-E01-A01-search-landscape")
    XCUIDevice.shared.orientation = .portrait
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    try app.performAccessibilityAudit()
    try await revokeNativeSession()
    app.terminate()
    app.launch()
    XCTAssertTrue(
      app.staticTexts["Your session expired. Sign in again."].waitForExistence(timeout: 20))
    capture(app, "IPAD-E01-A01-expired-session")
    signIn(app)
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    app.buttons["signOut"].tap()
    XCTAssertTrue(app.buttons["connectServer"].waitForExistence(timeout: 10))
  }

  @MainActor
  func testIPADE01A01OIDCLoginAndRelaunch() throws {
    let app = launchAtServerEntry()
    connect(app)
    let provider = app.buttons["oidc-ipad-fixture"]
    XCTAssertTrue(provider.waitForExistence(timeout: 10))
    provider.tap()
    let consent = app.buttons["Continue"]
    if consent.waitForExistence(timeout: 5) { consent.tap() }
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 30))
    capture(app, "IPAD-E01-A01-oidc-library")
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    app.buttons["signOut"].tap()
    XCTAssertTrue(app.buttons["connectServer"].waitForExistence(timeout: 10))
  }

  @MainActor
  private func launchAtServerEntry() -> XCUIApplication {
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    let server = app.textFields["serverURL"]
    if !server.waitForExistence(timeout: 5) {
      if app.buttons["signOut"].exists { app.buttons["signOut"].tap() }
      if app.buttons["Change server"].exists { app.buttons["Change server"].tap() }
    }
    XCTAssertTrue(server.waitForExistence(timeout: 10))
    return app
  }

  @MainActor
  private func connect(_ app: XCUIApplication) {
    let server = app.textFields["serverURL"]
    XCTAssertTrue(server.waitForExistence(timeout: 10))
    server.tap()
    let existing = server.value as? String ?? ""
    if existing != "http://localhost:16482" {
      server.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
      server.typeText("http://localhost:16482")
    }
    app.buttons["connectServer"].tap()
  }

  @MainActor
  private func signIn(_ app: XCUIApplication) {
    let username = app.textFields["username"]
    XCTAssertTrue(username.waitForExistence(timeout: 10))
    username.tap()
    username.typeText("ipad-owner")
    app.secureTextFields["password"].tap()
    app.secureTextFields["password"].typeText("IpadFixture123")
    app.buttons["signIn"].tap()
  }

  @MainActor
  private func revokeNativeSession() async throws {
    func request(
      _ path: String, method: String = "GET", token: String? = nil, body: [String: String]? = nil
    ) async throws -> Data {
      var request = URLRequest(url: URL(string: "http://localhost:16482/api/v1/\(path)")!)
      request.httpMethod = method
      request.timeoutInterval = 10
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
      if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
      let (data, response) = try await URLSession.shared.data(for: request)
      XCTAssertTrue((200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0))
      return data
    }
    let data = try await request(
      "auth/login", method: "POST",
      body: [
        "username": "ipad-owner", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "XCUITest control session",
      ])
    let credentials = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let token = try XCTUnwrap(credentials["accessToken"] as? String)
    let sessionsData = try await request("auth/sessions", token: token)
    let sessions = try XCTUnwrap(
      JSONSerialization.jsonObject(with: sessionsData) as? [[String: Any]])
    let native = sessions.filter { ($0["deviceLabel"] as? String) == "BookOrbit private iPad" }
    XCTAssertEqual(native.count, 1)
    let id = try XCTUnwrap(native.first?["id"] as? Int)
    _ = try await request("auth/sessions/\(id)", method: "DELETE", token: token)
    _ = try await request(
      "auth/logout", method: "POST",
      body: ["refreshToken": try XCTUnwrap(credentials["refreshToken"] as? String)])
  }

  @MainActor
  private func capture(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
