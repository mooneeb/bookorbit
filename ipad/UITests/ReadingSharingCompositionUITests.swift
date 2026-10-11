import Foundation
import XCTest

final class ReadingSharingCompositionUITests: XCTestCase {
  private static var serverURL: String {
    let value = ProcessInfo.processInfo.environment["IPAD_E04_SERVER_URL"] ?? ""
    return value.hasPrefix("http") ? value : "http://127.0.0.1:16502"
  }

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
  }

  @MainActor
  func testIPADE04A02NativeDestinationsHonorPermissions() async throws {
    let restrictedUsername = "ipad-restricted"
    let restricted = try await authenticatedUser(restrictedUsername)
    XCTAssertEqual(restricted["username"] as? String, restrictedUsername)
    XCTAssertEqual(restricted["isSuperuser"] as? Bool, false)
    let permissions = try XCTUnwrap(restricted["permissions"] as? [String])
    let integrations = [
      "kobo_sync", "koreader_sync", "opds_access", "email_send", "hardcover_sync",
      "readwise_sync", "storygraph_sync",
    ]
    XCTAssertFalse(permissions.contains("*"))
    XCTAssertTrue(Set(permissions).isDisjoint(with: integrations))
    let app = launchAndSignIn(restrictedUsername)
    let identifiers = [
      "koboSettings", "catalogSettings", "emailSettings", "hardcoverSettings",
      "readwiseSettingsLink", "storygraphSettings",
    ]
    for identifier in identifiers { XCTAssertFalse(app.buttons[identifier].exists) }
    try openDestination("readingStatistics", title: "Reading activity", app: app)
    try openDestination("readingPrivacy", title: "Privacy and sharing", app: app)
    capture("IPAD-E04-A02-restricted-permitted-native-destinations")
    app.buttons["signOut"].tap()
    XCTAssertTrue(app.buttons["connectServer"].waitForExistence(timeout: 10))
    let owner = try await authenticatedUser("ipad-owner")
    XCTAssertEqual(owner["username"] as? String, "ipad-owner")
    XCTAssertEqual(owner["isSuperuser"] as? Bool, true)
    XCTAssertTrue(try XCTUnwrap(owner["permissions"] as? [String]).contains("*"))
    connectAndSignIn("ipad-owner", app: app)
    for (identifier, title) in [
      ("koboSettings", "Kobo"), ("catalogSettings", "KOReader and OPDS"),
      ("emailSettings", "Email and Kindle"), ("hardcoverSettings", "Hardcover"),
      ("readwiseSettingsLink", "Readwise"), ("storygraphSettings", "StoryGraph"),
    ] {
      try openDestination(identifier, title: title, app: app)
    }
    capture("IPAD-E04-A02-owner-permitted-native-destinations")
    app.buttons["signOut"].tap()
    XCTAssertTrue(app.buttons["connectServer"].waitForExistence(timeout: 10))
  }

  @MainActor
  private func openDestination(_ identifier: String, title: String, app: XCUIApplication) throws {
    let sidebar = app.collectionViews["librarySidebar"]
    XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
    let entry = app.buttons[identifier]
    XCTAssertTrue(E02ProfileSupport.reveal(entry, in: sidebar, app: app))
    XCTAssertGreaterThanOrEqual(entry.frame.height, 44)
    entry.tap()
    let navigation = app.navigationBars[title]
    XCTAssertTrue(navigation.waitForExistence(timeout: 15))
    let done = navigation.buttons.matching(
      NSPredicate(format: "label == %@", "Done")
    ).firstMatch
    XCTAssertTrue(done.wait(for: \.isHittable, toEqual: true, timeout: 15))
    XCTAssertTrue(done.wait(for: \.isEnabled, toEqual: true, timeout: 15))
    capture("IPAD-E04-A02-native-destination-\(identifier)")
    done.tap()
    XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
  }

  @MainActor
  private func launchAndSignIn(_ username: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    E02ProfileSupport.configure(app)
    app.launch()
    if app.buttons["signOut"].waitForExistence(timeout: 3) { app.buttons["signOut"].tap() }
    if app.buttons["Change server"].exists { app.buttons["Change server"].tap() }
    connectAndSignIn(username, app: app)
    return app
  }

  @MainActor
  private func connectAndSignIn(_ username: String, app: XCUIApplication) {
    let server = app.textFields["serverURL"]
    XCTAssertTrue(server.wait(for: \.isHittable, toEqual: true, timeout: 10))
    server.tap()
    let existing = server.value as? String ?? ""
    server.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
    server.typeText(Self.serverURL)
    app.buttons["connectServer"].tap()
    XCTAssertTrue(E02ProfileSupport.ensureSignInForm(app: app, serverURL: Self.serverURL))
    let usernameField = app.textFields["username"]
    usernameField.tap()
    usernameField.typeText(username)
    app.secureTextFields["password"].tap()
    app.secureTextFields["password"].typeText("IpadFixture123")
    app.buttons["signIn"].tap()
    XCTAssertTrue(app.buttons["signOut"].waitForExistence(timeout: 20))
  }

  @MainActor
  private func authenticatedUser(_ username: String) async throws -> [String: Any] {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    var login = URLRequest(url: try XCTUnwrap(URL(string: "\(Self.serverURL)/api/v1/auth/login")))
    login.httpMethod = "POST"
    login.setValue("application/json", forHTTPHeaderField: "Content-Type")
    login.httpBody = try JSONSerialization.data(withJSONObject: [
      "username": username, "password": "IpadFixture123", "clientKind": "native",
      "deviceLabel": "E04 destination permissions assertion",
    ])
    let (bytes, response) = try await session.data(for: login)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    let result = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    var currentUser = URLRequest(
      url: try XCTUnwrap(URL(string: "\(Self.serverURL)/api/v1/auth/me")))
    currentUser.setValue(
      "Bearer \(try XCTUnwrap(result["accessToken"] as? String))",
      forHTTPHeaderField: "Authorization")
    let (userBytes, userResponse) = try await session.data(for: currentUser)
    XCTAssertEqual((userResponse as? HTTPURLResponse)?.statusCode, 200)
    let user = try XCTUnwrap(JSONSerialization.jsonObject(with: userBytes) as? [String: Any])
    var logout = URLRequest(url: try XCTUnwrap(URL(string: "\(Self.serverURL)/api/v1/auth/logout")))
    logout.httpMethod = "POST"
    logout.setValue("application/json", forHTTPHeaderField: "Content-Type")
    logout.httpBody = try JSONSerialization.data(withJSONObject: [
      "refreshToken": try XCTUnwrap(result["refreshToken"] as? String)
    ])
    let (_, logoutResponse) = try await session.data(for: logout)
    XCTAssertEqual((logoutResponse as? HTTPURLResponse)?.statusCode, 200)
    return user
  }

  @MainActor
  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
