import XCTest

class ReaderProofTestCase: XCTestCase {
  static var fixtureURL: String {
    ProcessInfo.processInfo.environment["IPAD_PROOF_SERVER_URL"] ?? "http://localhost:16482"
  }

  override func setUpWithError() throws { continueAfterFailure = false }

  @MainActor
  func connectAndSignIn(serverURL requestedURL: String? = nil) -> XCUIApplication {
    let serverURL = requestedURL ?? Self.fixtureURL
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
    server.tap()
    let existing = server.value as? String ?? ""
    if existing != serverURL {
      server.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
      server.typeText(serverURL)
    }
    let connect = app.buttons["connectServer"]
    XCTAssertTrue(connect.wait(for: \.isEnabled, toEqual: true, timeout: 10))
    XCTAssertTrue(connect.wait(for: \.isHittable, toEqual: true, timeout: 10))
    connect.tap()
    let username = app.textFields["username"]
    XCTAssertTrue(username.waitForExistence(timeout: 10))
    XCTAssertTrue(username.wait(for: \.isEnabled, toEqual: true, timeout: 10))
    username.tap()
    username.typeText("ipad-reader")
    app.secureTextFields["password"].tap()
    app.secureTextFields["password"].typeText("IpadFixture123")
    app.buttons["signIn"].tap()
    return app
  }

  static func fault(_ operation: String, method: String = "GET") async throws {
    _ = try await request("http://localhost:16485/__faults/progress/\(operation)", method: method)
  }

  static func resetProgress(fileID: Int = 1) async throws {
    let data = try await request(
      "http://localhost:16482/api/v1/auth/login", method: "POST",
      body: [
        "username": "ipad-reader", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "Reader progress fixture setup",
      ])
    let credentials = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let token = try XCTUnwrap(credentials["accessToken"] as? String)
    _ = try await request(
      "http://localhost:16482/api/v1/books/files/\(fileID)/progress", method: "DELETE", token: token
    )
    _ = try await request(
      "http://localhost:16482/api/v1/auth/logout", method: "POST",
      body: ["refreshToken": try XCTUnwrap(credentials["refreshToken"] as? String)])
  }

  static func request(
    _ url: String, method: String = "GET", token: String? = nil, body: [String: String]? = nil,
    encodedBody: Data? = nil
  ) async throws -> Data {
    let localhost = "http://localhost:16482"
    let address =
      url.hasPrefix(localhost + "/") ? Self.fixtureURL + url.dropFirst(localhost.count) : url
    var request = URLRequest(url: try XCTUnwrap(URL(string: address)))
    request.httpMethod = method
    request.timeoutInterval = 15
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let encodedBody {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = encodedBody
    } else if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    XCTAssertTrue((200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0))
    return data
  }

  @MainActor
  func openPDF(_ app: XCUIApplication) {
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    let search = app.searchFields.firstMatch
    search.tap()
    search.typeText("Orbit\n")
    let book = app.buttons["Orbit fixture"]
    XCTAssertTrue(book.waitForExistence(timeout: 10))
    book.tap()
    capture("IPAD-E01-A03-proof-book-before-reader")
    let read = app.buttons["readFile1"]
    XCTAssertTrue(read.waitForExistence(timeout: 5))
    read.tap()
  }

  @MainActor
  func assertPassage(_ page: Int, in app: XCUIApplication) {
    let text = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@", "Orbit fixture: passage \(page)")
    ).firstMatch
    XCTAssertTrue(text.wait(for: \.isHittable, toEqual: true, timeout: 10))
  }

  @MainActor
  func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
