import Foundation
import PDFKit
import XCTest

final class RequestLifecycleJourneyTests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  @MainActor
  func testIPADE03A02RequestCreateAndCancel() throws {
    let app = login("ipad-owner")
    tap("openRequests", app)
    XCTAssertTrue(app.descendants(matching: .any)["requestsScreen"].waitForExistence(timeout: 10))
    tap("requestNew", app)
    let title = "Native request cancellation fixture \(UUID().uuidString)"
    set("requestTitle", value: title, app)
    try chooseDestination(app)
    tap("requestCreate", app)
    XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 15))
    capture("IPAD-E03-A02-request-created")
    tap("requestCancel", app)
    app.alerts.buttons["Cancel request"].tap()
    XCTAssertTrue(
      app.staticTexts["requestStatus"].wait(for: \.label, toEqual: "Cancelled", timeout: 15))
    capture("IPAD-E03-A02-request-cancelled")
  }

  @MainActor
  func testIPADE03A02SelfFulfilReleaseAndReadPDF() async throws {
    try await control("reset=true")
    let token = try await loginToken("ipad-owner")
    let title = "Native discovered fixture \(UUID().uuidString)"
    let app = login("ipad-owner")
    tap("openRequests", app)
    tap("requestNew", app)
    discover(title, app)
    try chooseDestination(app)
    tap("requestSelfServe", app, type: .switch)
    tap("requestCreate", app)
    XCTAssertTrue(app.buttons["requestReleaseSearch"].waitForExistence(timeout: 15))
    let created = try await requestByTitle(title, token: token)
    let id = try XCTUnwrap(created["id"] as? Int)
    XCTAssertEqual(created["providerKey"] as? String, "openLibrary")
    XCTAssertEqual(created["providerId"] as? String, providerID(title))
    XCTAssertEqual(created["authors"] as? [String], ["Native discovery author"])
    XCTAssertEqual(created["status"] as? String, "approved")
    capture("IPAD-E03-A02-metadata-discovered-self-fulfil-approved")

    try await control("failSearch=true")
    tap("requestReleaseSearch", app)
    XCTAssertTrue(
      app.staticTexts["No matching releases. Retry or refine the request."].waitForExistence(
        timeout: 20))
    capture("IPAD-E03-A02-source-failure")
    try await control("reset=true&held=true")
    tap("requestReleaseSearch", app)
    tap("requestGrab0", app)
    XCTAssertTrue(app.buttons["requestCancelDownload"].waitForExistence(timeout: 30))
    let active = try await waitForRequest(id, token: token, statuses: ["downloading"])
    let download = try XCTUnwrap(active["download"] as? [String: Any])
    let attemptID = try XCTUnwrap(download["id"] as? Int)
    XCTAssertEqual(download["status"] as? String, "downloading")
    let progress = try XCTUnwrap(download["progressPercent"] as? Double)
    XCTAssertGreaterThan(progress, 0)
    XCTAssertLessThan(progress, 100)
    capture("IPAD-E03-A02-active-transfer")
    tap("requestCancelDownload", app)
    XCTAssertTrue(
      app.staticTexts["requestStatus"].wait(for: \.label, toEqual: "Approved", timeout: 20))
    let stopped = try await fixtureCall("book-requests/\(id)", token: token)
    XCTAssertEqual(stopped["status"] as? String, "approved")
    let stoppedAttempt = try XCTUnwrap(stopped["download"] as? [String: Any])
    XCTAssertEqual(stoppedAttempt["id"] as? Int, attemptID)
    XCTAssertEqual(stoppedAttempt["status"] as? String, "cancelled")
    XCTAssertFalse(app.buttons["requestCancelDownload"].exists)
    capture("IPAD-E03-A02-active-transfer-cancelled-approved")

    try await control("reset=true")
    tap("requestReleaseSearch", app)
    XCTAssertTrue(app.buttons["requestGrab0"].waitForExistence(timeout: 20))
    capture("IPAD-E03-A02-release-retry")
    tap("requestGrab0", app)
    let received = try await waitForRequest(
      id, token: token, statuses: ["needs_review", "available"])
    let retried = try XCTUnwrap(received["download"] as? [String: Any])
    XCTAssertNotEqual(retried["id"] as? Int, attemptID)
    if received["status"] as? String == "needs_review" {
      tap("Refresh", app)
      tap("Inspect received files", app)
      XCTAssertTrue(app.buttons["File this book"].waitForExistence(timeout: 10))
      capture("IPAD-E03-A02-import-review")
      tap("File this book", app)
      app.alerts.buttons["File book"].tap()
    }
    let settled = try await waitForRequest(id, token: token, statuses: ["available"])
    let bookID = try XCTUnwrap(settled["matchedBookId"] as? Int)
    let book = try await fixtureCall("books/\(bookID)", token: token)
    let files = try XCTUnwrap(book["files"] as? [[String: Any]])
    let file = try XCTUnwrap(
      files.first(where: { ($0["format"] as? String)?.lowercased() == "pdf" }))
    let fileID = try XCTUnwrap(file["id"] as? Int)
    let delivered = try await request("books/files/\(fileID)/serve", token: token)
    let pdf = try XCTUnwrap(PDFDocument(data: delivered))
    XCTAssertGreaterThan(pdf.pageCount, 0)
    XCTAssertTrue(pdf.page(at: 0)?.string?.contains("Readable request fixture") == true)
    tap("Refresh", app)
    tap("requestRead", app)
    capture("IPAD-E03-A02-received-book")
    tap("readFile\(fileID)", app)
    XCTAssertTrue(app.buttons["pdfContents"].waitForExistence(timeout: 30))
    XCTAssertTrue(app.buttons["pdfContents"].wait(for: \.isEnabled, toEqual: true, timeout: 30))
    XCTAssertTrue(app.buttons["pdfCloseReader"].exists)
    capture("IPAD-E03-A02-readable-PDF")
  }

  @MainActor
  func testIPADE03A02RestrictedUserCannotReachRequests() throws {
    let app = login("ipad-restricted")
    XCTAssertTrue(app.buttons["signOut"].waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["openRequests"].exists)
    capture("IPAD-E03-A02-request-permission-hidden")
  }

  @MainActor
  func testIPADE03A02JoinAndUnsubscribe() async throws {
    let title = "Native discovered fixture \(UUID().uuidString)"
    let token = try await loginToken("ipad-owner")
    let libraryData = try await request("libraries", token: token)
    let libraries = try XCTUnwrap(
      JSONSerialization.jsonObject(with: libraryData) as? [[String: Any]])
    let library = try XCTUnwrap(
      libraries.first(where: { ($0["name"] as? String) == "Fixture library" }))
    let libraryID = try XCTUnwrap(library["id"] as? Int)
    let submission = try await fixtureCall(
      "book-requests", token: token,
      body: [
        "title": title, "authors": ["Native discovery author"], "mediaKind": "ebook",
        "providerKey": "openLibrary", "providerId": providerID(title),
        "targetLibraryId": libraryID,
      ])
    let created = try XCTUnwrap(submission["request"] as? [String: Any])
    let id = try XCTUnwrap(created["id"] as? Int)
    let readerToken = try await loginToken("ipad-reader")
    let app = login("ipad-reader")
    tap("openRequests", app)
    tap("requestNew", app)
    discover(title, app)
    tap("requestAvailability", app)
    XCTAssertTrue(
      app.staticTexts["Submitting will join request \(id)."].waitForExistence(timeout: 15))
    capture("IPAD-E03-A02-existing-request-discovery")
    tap("requestCreate", app)
    XCTAssertTrue(app.buttons["requestUnsubscribe"].waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["requestCancel"].exists)
    let followed = try await fixtureCall("book-requests/\(id)", token: readerToken)
    XCTAssertEqual(followed["id"] as? Int, id)
    let followers = try XCTUnwrap(followed["subscribers"] as? [[String: Any]])
    XCTAssertEqual(followers.count, 1)
    capture("IPAD-E03-A02-subscribed")
    tap("requestUnsubscribe", app)
    XCTAssertTrue(app.buttons["requestNew"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.buttons["requestRow\(id)"].wait(for: \.exists, toEqual: false, timeout: 15))
    _ = try await request("book-requests/\(id)", token: readerToken, expectedStatus: 403)
    let left = try await fixtureCall("book-requests/\(id)", token: token)
    XCTAssertEqual((left["subscribers"] as? [[String: Any]])?.count, 0)
    capture("IPAD-E03-A02-unsubscribed")
    _ = try await fixtureCall("book-requests/\(id)/cancel", token: token, body: [:])
  }

  @MainActor
  private func discover(_ title: String, _ app: XCUIApplication) {
    set("requestTitle", value: title, app)
    tap("requestDiscover", app)
    let match = app.buttons["requestMetadata\(providerID(title))"]
    XCTAssertTrue(match.waitForExistence(timeout: 30))
    reveal(match, app)
    capture("IPAD-E03-A02-positive-metadata-discovery")
    match.tap()
    XCTAssertEqual(app.textFields["requestAuthor"].value as? String, "Native discovery author")
  }

  private func providerID(_ title: String) -> String {
    "E03"
      + title.replacingOccurrences(of: "Native discovered fixture ", with: "")
      .replacingOccurrences(of: "-", with: "").uppercased() + "W"
  }

  @MainActor
  private func requestByTitle(_ title: String, token: String) async throws -> [String: Any] {
    let page = try await fixtureCall("book-requests?page=1&limit=20", token: token)
    let items = try XCTUnwrap(page["items"] as? [[String: Any]])
    return try XCTUnwrap(items.first(where: { ($0["title"] as? String) == title }))
  }

  @MainActor
  private func waitForRequest(_ id: Int, token: String, statuses: Set<String>) async throws
    -> [String: Any]
  {
    for _ in 0..<180 {
      let value = try await fixtureCall("book-requests/\(id)", token: token)
      let status = try XCTUnwrap(value["status"] as? String)
      if statuses.contains(status) { return value }
      XCTAssertNotEqual(status, "failed", value["statusReason"] as? String ?? "Request failed")
      try await Task.sleep(for: .milliseconds(500))
    }
    XCTFail("Request \(id) did not reach \(statuses.sorted().joined(separator: ", "))")
    throw NSError(domain: "RequestLifecycleAcceptance", code: 1)
  }

  @MainActor
  private func loginToken(_ username: String) async throws -> String {
    let result = try await fixtureCall(
      "auth/login",
      body: [
        "username": username, "password": password, "clientKind": "native",
        "deviceLabel": "Request lifecycle acceptance",
      ])
    return try XCTUnwrap(result["accessToken"] as? String)
  }

  @MainActor
  private func fixtureCall(_ path: String, token: String? = nil, body: [String: Any]? = nil)
    async throws
    -> [String: Any]
  {
    let data = try await request(path, token: token, body: body)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @MainActor
  private func request(
    _ path: String, token: String? = nil, body: [String: Any]? = nil, expectedStatus: Int? = nil
  ) async throws -> Data {
    var request = URLRequest(url: try XCTUnwrap(URL(string: "\(serverURL)/api/v1/\(path)")))
    request.httpMethod = body == nil ? "GET" : "POST"
    request.timeoutInterval = 45
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = try XCTUnwrap(response as? HTTPURLResponse).statusCode
    if let expectedStatus {
      XCTAssertEqual(status, expectedStatus, path)
    } else {
      XCTAssertTrue((200..<300).contains(status), "\(path): \(status)")
    }
    return data
  }

  @MainActor
  private func control(_ query: String) async throws {
    let base = environment("IPAD_E03_PROTOCOL_URL") ?? "http://127.0.0.1:16502"
    let url = try XCTUnwrap(URL(string: "\(base)/control?\(query)"))
    let (_, response) = try await URLSession.shared.data(from: url)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
  }

  private var serverURL: String {
    environment("IPAD_E03_SERVER_URL") ?? "http://localhost:16482"
  }
  private var password: String { environment("IPAD_FIXTURE_PASSWORD") ?? "IpadFixture123" }
  private func environment(_ name: String) -> String? {
    ProcessInfo.processInfo.environment[name]
      ?? ProcessInfo.processInfo.environment["TEST_RUNNER_\(name)"]
  }

  @MainActor
  private func login(_ account: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    if app.buttons["signOut"].waitForExistence(timeout: 3) { app.buttons["signOut"].tap() }
    if app.buttons["Change server"].exists { app.buttons["Change server"].tap() }
    set("serverURL", value: serverURL, app)
    tap("connectServer", app)
    set("username", value: account, app)
    set("password", value: password, app, secure: true)
    tap("signIn", app)
    XCTAssertTrue(app.buttons["signOut"].waitForExistence(timeout: 20))
    return app
  }

  @MainActor
  private func set(_ id: String, value: String, _ app: XCUIApplication, secure: Bool = false) {
    let field = secure ? app.secureTextFields[id] : app.textFields[id]
    XCTAssertTrue(field.waitForExistence(timeout: 15))
    reveal(field, app)
    field.tap()
    let current = field.value as? String ?? ""
    if !current.isEmpty && current != field.placeholderValue {
      field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
    }
    field.typeText(value)
  }

  @MainActor
  private func tap(_ id: String, _ app: XCUIApplication, type: XCUIElement.ElementType = .button) {
    dismissKeyboard(app)
    let element = app.descendants(matching: type)[id]
    reveal(element, app)
    XCTAssertTrue(element.waitForExistence(timeout: 20), id)
    XCTAssertTrue(element.wait(for: \.isEnabled, toEqual: true, timeout: 15), id)
    XCTAssertTrue(element.isHittable, id)
    element.tap()
  }

  @MainActor
  private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
    if element.isHittable { return }
    let container =
      app.collectionViews.allElementsBoundByIndex.last(where: { $0.isHittable }) ?? app
    for _ in 0..<6 {
      container.swipeUp()
      if element.isHittable { return }
    }
    for _ in 0..<6 {
      container.swipeDown()
      if element.isHittable { return }
    }
  }

  @MainActor
  private func dismissKeyboard(_ app: XCUIApplication) {
    let hide = app.buttons["Hide keyboard"].firstMatch
    if hide.exists && hide.isHittable { hide.tap() }
  }

  @MainActor
  private func chooseDestination(_ app: XCUIApplication) throws {
    tap("requestDestination", app)
    let choices = app.buttons.matching(NSPredicate(format: "label == %@", "Fixture library"))
    let option = try XCTUnwrap(
      choices.allElementsBoundByIndex.first(where: { $0.isHittable }),
      "The visible destination menu must contain Fixture library")
    option.tap()
    XCTAssertTrue(
      app.buttons["requestDestination"].wait(
        for: \.label, toEqual: "Destination library, Fixture library", timeout: 10))
  }

  @MainActor
  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
