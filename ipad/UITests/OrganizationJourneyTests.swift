import Foundation
import XCTest

final class OrganizationJourneyTests: XCTestCase {
  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
  }

  override func tearDownWithError() throws {
    if let testRun, testRun.failureCount > 0 {
      capture("organization-failure-\(name)")
    }
    try super.tearDownWithError()
  }

  @MainActor
  func testIPADE01A01AuthorDirectoryPagingAndFilters() throws {
    let app = launchAndSignIn()
    app.buttons["browseAuthors"].tap()
    XCTAssertTrue(app.staticTexts["Page 1, 55 results"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.buttons.matching(identifierPrefix: "author").firstMatch.exists)
    XCTAssertLessThanOrEqual(app.buttons.matching(identifierPrefix: "author").count, 40)
    XCTAssertTrue(app.staticTexts["Orbit author 000"].exists)
    capture("IPAD-E01-A01-authors-first-page")
    try audit(app, state: "authors-first-page")
    app.buttons["Next"].tap()
    XCTAssertTrue(app.staticTexts["Page 2, 55 results"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Orbit author 040"].exists)
    XCTAssertFalse(app.staticTexts["Orbit author 000"].exists)
    XCTAssertLessThanOrEqual(app.buttons.matching(identifierPrefix: "author").count, 15)
    capture("IPAD-E01-A01-authors-second-page")
    app.buttons["Previous"].tap()
    XCTAssertTrue(app.staticTexts["Orbit author 000"].waitForExistence(timeout: 10))
    app.buttons["organizationSort"].tap()
    app.buttons["Descending"].tap()
    XCTAssertTrue(app.staticTexts["Orbit author 054"].waitForExistence(timeout: 10))
    capture("IPAD-E01-A01-authors-descending")
    app.buttons["organizationFilters"].tap()
    choosePicker("Sort name", option: "Has sort name", app: app)
    app.switches["At least two books"].tap()
    capture("IPAD-E01-A01-author-filter-draft")
    try audit(app, state: "author-filter-draft")
    app.buttons["Cancel"].tap()
    XCTAssertTrue(app.staticTexts["Page 1, 55 results"].waitForExistence(timeout: 5))
    app.buttons["organizationFilters"].tap()
    choosePicker("Sort name", option: "Has sort name", app: app)
    app.switches["At least two books"].tap()
    choosePicker("Library", option: "Large library", app: app)
    app.buttons["Apply"].tap()
    XCTAssertTrue(app.staticTexts["Page 1, 1 results"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Orbit author 000"].exists)
    XCTAssertTrue(app.staticTexts["45 books"].exists)
    XCTAssertFalse(app.buttons["Next"].exists)
    capture("IPAD-E01-A01-authors-applied-filters")
    try audit(app, state: "authors-applied-filters")
    app.buttons["organizationFilters"].tap()
    app.switches["Books added in the last 30 days"].tap()
    app.buttons["Apply"].tap()
    XCTAssertTrue(app.staticTexts["Page 1, 0 results"].waitForExistence(timeout: 10))
    capture("IPAD-E01-A01-authors-no-recent-books")
    app.buttons["organizationFilters"].tap()
    app.buttons["Reset filters"].tap()
    app.buttons["Apply"].tap()
    XCTAssertTrue(app.staticTexts["Page 1, 55 results"].waitForExistence(timeout: 10))
    app.searchFields["Search authors"].tap()
    app.searchFields["Search authors"].typeText("Orbit author 054\n")
    XCTAssertTrue(app.staticTexts["Page 1, 1 results"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Orbit author 054"].exists)
    XCTAssertFalse(app.staticTexts["Orbit author 000"].exists)
    capture("IPAD-E01-A01-authors-search")
    XCUIDevice.shared.orientation = .landscapeLeft
    XCTAssertTrue(
      app.staticTexts["Orbit author 054"].wait(for: \.isHittable, toEqual: true, timeout: 10))
    capture("IPAD-E01-A01-authors-search-landscape")
    try audit(app, state: "authors-search-landscape")
    XCUIDevice.shared.orientation = .portrait
    app.buttons["Done"].tap()
    app.buttons["signOut"].tap()
  }

  @MainActor
  func testIPADE01A01AuthorProfileBookPagingAndPDF() async throws {
    let token = try await loginAPI()
    _ = try await api("books/files/1/progress", method: "DELETE", token: token)
    let app = launchAndSignIn()
    app.buttons["browseAuthors"].tap()
    XCTAssertTrue(app.staticTexts["Page 1, 55 results"].waitForExistence(timeout: 15))
    app.searchFields["Search authors"].tap()
    app.searchFields["Search authors"].typeText("Orbit author 000\n")
    XCTAssertTrue(app.staticTexts["Page 1, 1 results"].waitForExistence(timeout: 10))
    app.buttons.matching(identifierPrefix: "author").firstMatch.tap()
    XCTAssertTrue(app.staticTexts["Page 1, 45 results"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["An author profile for the native organization journey."].exists)
    XCTAssertTrue(app.staticTexts["Born: 1975"].exists)
    XCTAssertTrue(app.staticTexts["Genres: Science fiction"].exists)
    XCTAssertTrue(app.staticTexts["Influences: Orbit predecessor"].exists)
    XCTAssertLessThanOrEqual(app.buttons.matching(identifierPrefix: "organizationBook").count, 40)
    capture("IPAD-E01-A01-author-profile-and-book-page")
    try audit(app, state: "author-profile")
    app.buttons["Next"].tap()
    XCTAssertTrue(app.staticTexts["Page 2, 45 results"].waitForExistence(timeout: 10))
    XCTAssertLessThanOrEqual(app.buttons.matching(identifierPrefix: "organizationBook").count, 5)
    let book = app.buttons["organizationBook1"]
    XCTAssertTrue(book.wait(for: \.isHittable, toEqual: true, timeout: 10))
    capture("IPAD-E01-A01-author-book-second-page")
    book.tap()
    XCTAssertTrue(app.buttons["readFile1"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["editMetadata"].exists)
    capture("IPAD-E01-A01-author-authorized-pdf-detail")
    app.buttons["readFile1"].tap()
    XCTAssertTrue(app.staticTexts["Page 1 of 3"].waitForExistence(timeout: 15))
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Orbit fixture: passage 1"))
        .firstMatch.isHittable)
    app.otherElements["pdfReader"].swipeLeft()
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Position saved"].waitForExistence(timeout: 10))
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Orbit fixture: passage 2"))
        .firstMatch.isHittable)
    capture("IPAD-E01-A01-author-opened-pdf-second-page")
    try audit(app, state: "author-pdf")
    let data = try await api("books/files/1/progress", token: token)
    attach(data, name: "IPAD-E01-A01-author-reader-public-progress")
    let progress = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(progress["pageNumber"] as? Double, 2)
    app.buttons["Close reader"].tap()
    app.buttons["Done"].tap()
    XCTAssertTrue(app.staticTexts["Page 1, 45 results"].waitForExistence(timeout: 10))
    app.navigationBars.buttons["Authors"].tap()
    app.buttons["Done"].tap()
    app.buttons["signOut"].tap()
  }

  @MainActor
  func testIPADE01A01SeriesDirectoryFiltersAndBookPaging() throws {
    let app = launchAndSignIn()
    app.buttons["browseSeries"].tap()
    XCTAssertTrue(app.staticTexts["Page 1, 55 results"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["Orbit series 000"].exists)
    XCTAssertTrue(app.staticTexts["2 missing volumes"].exists)
    XCTAssertLessThanOrEqual(app.buttons.matching(identifierPrefix: "series").count, 40)
    capture("IPAD-E01-A01-series-first-page")
    try audit(app, state: "series-first-page")
    app.buttons["Next"].tap()
    XCTAssertTrue(app.staticTexts["Page 2, 55 results"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Orbit series 040"].exists)
    capture("IPAD-E01-A01-series-second-page")
    app.buttons["organizationFilters"].tap()
    choosePicker("Reading status", option: "Missing volumes", app: app)
    app.textFields["Author name"].tap()
    app.textFields["Author name"].typeText("Orbit author 000")
    capture("IPAD-E01-A01-series-filter-draft")
    app.buttons["Apply"].tap()
    XCTAssertTrue(app.staticTexts["Page 1, 1 results"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Orbit series 000"].exists)
    XCTAssertFalse(app.staticTexts["Orbit series 040"].exists)
    capture("IPAD-E01-A01-series-applied-filters")
    app.buttons.matching(identifierPrefix: "series").firstMatch.tap()
    XCTAssertTrue(app.staticTexts["Page 1, 45 results"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["47 expected volumes"].exists)
    XCTAssertTrue(app.staticTexts["Possible missing volumes: 2, 47"].exists)
    XCTAssertTrue(app.buttons["organizationBook1"].exists)
    capture("IPAD-E01-A01-series-profile-and-volume-order")
    try audit(app, state: "series-profile")
    app.buttons["Next"].tap()
    XCTAssertTrue(app.staticTexts["Page 2, 45 results"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["organizationBook240"].exists)
    XCTAssertFalse(app.buttons["organizationBook1"].exists)
    capture("IPAD-E01-A01-series-book-second-page")
    app.buttons["Previous"].tap()
    XCTAssertTrue(app.buttons["organizationBook1"].waitForExistence(timeout: 10))
    app.buttons["organizationBook1"].tap()
    XCTAssertTrue(app.buttons["readFile1"].waitForExistence(timeout: 10))
    capture("IPAD-E01-A01-series-authorized-pdf-detail")
    app.buttons["Done"].tap()
    app.navigationBars.buttons["Series"].tap()
    app.buttons["Done"].tap()
    app.buttons["signOut"].tap()
  }

  @MainActor
  func testIPADE01A05OrganizationRestrictedAndRetry() async throws {
    let restricted = launchAndSignIn(username: "ipad-restricted", expectedCount: "0 books")
    for sidebar in ["browseAuthors", "browseSeries"] {
      restricted.buttons[sidebar].tap()
      XCTAssertTrue(restricted.staticTexts["Page 1, 0 results"].waitForExistence(timeout: 10))
      XCTAssertEqual(restricted.buttons.matching(identifierPrefix: "organizationBook").count, 0)
      XCTAssertFalse(restricted.staticTexts["Orbit author 000"].exists)
      XCTAssertFalse(restricted.staticTexts["Orbit series 000"].exists)
      capture("IPAD-E01-A05-\(sidebar)-restricted")
      try audit(restricted, state: "\(sidebar)-restricted")
      restricted.buttons["Done"].tap()
    }
    restricted.buttons["signOut"].tap()
    try await fault("recover")
    let app = launchAndSignIn(serverURL: "http://localhost:16485")
    try await fault("fail")
    app.buttons["browseAuthors"].tap()
    XCTAssertTrue(app.staticTexts["Could not load authors"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.buttons["Try again"].exists)
    capture("IPAD-E01-A05-authors-server-unavailable")
    try audit(app, state: "authors-server-unavailable")
    try await fault("recover")
    app.buttons["Try again"].tap()
    XCTAssertTrue(app.staticTexts["Page 1, 55 results"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Orbit author 000"].exists)
    capture("IPAD-E01-A05-authors-recovered")
    app.buttons["Done"].tap()
    app.buttons["signOut"].tap()
  }

  @MainActor
  private func launchAndSignIn(
    username: String = "ipad-reader", serverURL: String = "http://localhost:16482",
    expectedCount: String = "50,000 books"
  ) -> XCUIApplication {
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    if !app.textFields["serverURL"].waitForExistence(timeout: 5) {
      if app.buttons["signOut"].exists { app.buttons["signOut"].tap() }
      if app.buttons["Change server"].exists { app.buttons["Change server"].tap() }
    }
    let server = app.textFields["serverURL"]
    XCTAssertTrue(server.waitForExistence(timeout: 10))
    server.tap()
    let existing = server.value as? String ?? ""
    server.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.utf16.count))
    server.typeText(serverURL)
    app.buttons["connectServer"].tap()
    XCTAssertTrue(app.textFields["username"].wait(for: \.isHittable, toEqual: true, timeout: 10))
    app.textFields["username"].tap()
    app.textFields["username"].typeText(username)
    app.secureTextFields["password"].tap()
    app.secureTextFields["password"].typeText("IpadFixture123")
    app.buttons["signIn"].tap()
    XCTAssertTrue(app.staticTexts[expectedCount].waitForExistence(timeout: 20))
    XCTAssertTrue(app.buttons["browseAuthors"].wait(for: \.isHittable, toEqual: true, timeout: 10))
    return app
  }

  @MainActor
  private func choosePicker(_ name: String, option: String, app: XCUIApplication) {
    let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    XCTAssertTrue(picker.wait(for: \.isHittable, toEqual: true, timeout: 5))
    picker.tap()
    app.buttons[option].tap()
  }

  @MainActor
  private func audit(_ app: XCUIApplication, state: String) throws {
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = "IPAD-E01-organization-\(state)-hierarchy"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
    try app.performAccessibilityAudit { issue in
      let attachment = XCTAttachment(
        string:
          "\(issue.detailedDescription)\n\(issue.element?.debugDescription ?? "No associated element")"
      )
      attachment.name = "IPAD-E01-organization-\(state)-accessibility-issue"
      attachment.lifetime = .keepAlways
      self.add(attachment)
      return false
    }
  }

  @MainActor
  private func loginAPI() async throws -> String {
    let data = try await api(
      "auth/login", method: "POST",
      body: [
        "username": "ipad-reader", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "Organization UI control",
      ])
    let credentials = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let refresh = try XCTUnwrap(credentials["refreshToken"] as? String)
    addTeardownBlock { [refresh] in
      var request = URLRequest(url: URL(string: "http://localhost:16482/api/v1/auth/logout")!)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: ["refreshToken": refresh])
      let (_, response) = try await URLSession.shared.data(for: request)
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }
    return try XCTUnwrap(credentials["accessToken"] as? String)
  }

  @MainActor
  private func api(
    _ path: String, method: String = "GET", token: String? = nil, body: [String: String]? = nil
  ) async throws -> Data {
    var request = URLRequest(url: URL(string: "http://localhost:16482/api/v1/\(path)")!)
    request.httpMethod = method
    request.timeoutInterval = 15
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    XCTAssertTrue((200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0), path)
    return data
  }

  @MainActor
  private func fault(_ action: String) async throws {
    var request = URLRequest(
      url: URL(string: "http://localhost:16485/__faults/organization/\(action)")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 10
    let (_, response) = try await URLSession.shared.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
  }

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func attach(_ data: Data, name: String) {
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}

extension XCUIElementQuery {
  fileprivate func matching(identifierPrefix: String) -> XCUIElementQuery {
    matching(NSPredicate(format: "identifier BEGINSWITH %@", identifierPrefix))
  }
}
