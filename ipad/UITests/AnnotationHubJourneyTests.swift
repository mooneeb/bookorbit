import Foundation
import XCTest

final class AnnotationHubJourneyTests: XCTestCase {
  private let httpSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 20
    configuration.waitsForConnectivity = false
    return URLSession(configuration: configuration)
  }()

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
  }

  override func tearDown() async throws {
    if let testRun, testRun.failureCount > 0 {
      let screenshot = await MainActor.run { XCUIScreen.main.screenshot().pngRepresentation }
      let attachment = XCTAttachment(data: screenshot, uniformTypeIdentifier: "public.png")
      attachment.name = "IPAD-E02-A07-hub-failure-\(name)"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    try await super.tearDown()
  }

  @MainActor
  func testIPADE02A07HubEntryAndBoundedSearch() async throws {
    let app = XCUIApplication()
    let profile = ProcessInfo.processInfo.environment["IPAD_E02_PROFILE"] ?? "pro13-portrait-light"
    app.launchArguments = [
      "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
      "-AppleInterfaceStyle", profile.contains("dark") ? "Dark" : "Light",
      "-UIPreferredContentSizeCategoryName",
      profile.contains("large") ? "UICTContentSizeCategoryXXXL" : "UICTContentSizeCategoryL",
    ]
    XCUIDevice.shared.orientation = profile.contains("landscape") ? .landscapeLeft : .portrait
    E02ProfileSupport.configure(app)
    app.launch()
    if app.buttons["signOut"].waitForExistence(timeout: 3) { app.buttons["signOut"].tap() }
    if app.buttons["Change server"].exists { app.buttons["Change server"].tap() }
    let server = app.textFields["serverURL"]
    XCTAssertTrue(server.waitForExistence(timeout: 10))
    server.tap()
    let existing = server.value as? String ?? ""
    if existing != "http://localhost:16482" {
      server.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
      server.typeText("http://localhost:16482")
    }
    app.buttons["connectServer"].tap()
    guard E02ProfileSupport.ensureSignInForm(app: app, serverURL: "http://localhost:16482") else {
      return
    }
    let username = app.textFields["username"]
    XCTAssertTrue(username.waitForExistence(timeout: 10))
    username.tap()
    username.typeText("ipad-owner")
    app.secureTextFields["password"].tap()
    app.secureTextFields["password"].typeText("IpadFixture123")
    app.buttons["signIn"].tap()
    XCTAssertTrue(app.buttons["openAnnotationHub"].waitForExistence(timeout: 20))
    app.buttons["openAnnotationHub"].tap()
    let searchFields = app.textFields.matching(identifier: "annotationHubSearch")
    let search = searchFields.element
    XCTAssertTrue(search.waitForExistence(timeout: 15))
    XCTAssertEqual(searchFields.count, 1)
    XCTAssertTrue(search.wait(for: \.isHittable, toEqual: true, timeout: 5))
    XCTAssertTrue(app.buttons["annotationHubFilters"].exists)
    XCTAssertTrue(app.buttons["annotationHubDevices"].exists)
    XCTAssertLessThanOrEqual(
      app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "annotationHubItem"))
        .count, 40)
    capture("IPAD-E02-A07-hub-entry")
    try app.performAccessibilityAudit()
    XCTAssertEqual(searchFields.count, 1)
    XCTAssertTrue(search.wait(for: \.isHittable, toEqual: true, timeout: 5))
    search.tap()
    search.typeText("NoSuchConvertedPassageFixture\n")
    XCTAssertTrue(app.staticTexts["annotationHubEmpty"].waitForExistence(timeout: 15))
    XCTAssertEqual(
      app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "annotationHubItem"))
        .count, 0)
    capture("IPAD-E02-A07-hub-text-only-search-empty")
    try app.performAccessibilityAudit()
    app.buttons["annotationHubFilters"].tap()
    XCTAssertTrue(app.buttons["annotationHubApplyFilters"].waitForExistence(timeout: 5))
    capture("IPAD-E02-A07-hub-filters")
    try app.performAccessibilityAudit()
    let kind = app.buttons["annotationHubKind"]
    XCTAssertTrue(kind.wait(for: \.isHittable, toEqual: true, timeout: 5))
    kind.tap()
    app.buttons["Text notes"].tap()
    app.buttons["annotationHubApplyFilters"].tap()
    XCTAssertTrue(app.staticTexts["annotationHubEmpty"].waitForExistence(timeout: 15))
    XCTAssertEqual(search.value as? String, "NoSuchConvertedPassageFixture")
    let expectedDevice = try await knownNativeDevice()
    let devices = app.buttons.matching(identifier: "annotationHubDevices")
    XCTAssertEqual(devices.count, 1)
    XCTAssertTrue(devices.element.wait(for: \.isHittable, toEqual: true, timeout: 5))
    devices.element.tap()
    let headings = app.navigationBars.matching(identifier: "Annotation devices")
    XCTAssertTrue(headings.element.waitForExistence(timeout: 10))
    XCTAssertEqual(headings.count, 1)
    let device = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", expectedDevice, expectedDevice)
    ).firstMatch
    XCTAssertTrue(device.waitForExistence(timeout: 15), "The acknowledged native device must load")
    XCTAssertFalse(app.staticTexts["annotationHubDevicesError"].exists)
    XCTAssertFalse(app.staticTexts["No device acknowledgements are available."].exists)
    XCTAssertTrue(
      app.staticTexts["Loading devices…"].wait(for: \.exists, toEqual: false, timeout: 5))
    let doneButtons = app.buttons.matching(
      NSPredicate(format: "label == %@ AND identifier != %@", "Done", "annotationHubDone"))
    XCTAssertEqual(
      doneButtons.count, 1, "Only the active Devices sheet may provide this Done action")
    let done = doneButtons.element
    XCTAssertTrue(done.wait(for: \.isHittable, toEqual: true, timeout: 5))
    XCTAssertGreaterThanOrEqual(done.frame.width, 44)
    XCTAssertGreaterThanOrEqual(done.frame.height, 44)
    let description =
      "Each entry shows the last annotation revision a device acknowledged for one book."
    let lists = (app.collectionViews.allElementsBoundByIndex + app.tables.allElementsBoundByIndex)
      .filter { $0.staticTexts[description].exists }
    XCTAssertEqual(lists.count, 1, "The Devices acknowledgement list must be uniquely identifiable")
    let list = try XCTUnwrap(lists.first)
    XCTAssertTrue(list.wait(for: \.isHittable, toEqual: true, timeout: 5))
    let visibleList = list.frame.intersection(app.frame)
    let visibleTop = max(visibleList.minY, headings.element.frame.maxY, done.frame.maxY)
    let viewport = CGRect(
      x: visibleList.minX, y: visibleTop, width: visibleList.width,
      height: visibleList.maxY - visibleTop)
    XCTAssertGreaterThan(viewport.width, 0)
    XCTAssertGreaterThan(viewport.height, 0)
    let row = list.cells.containing(
      NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", expectedDevice, expectedDevice)
    ).firstMatch
    for _ in 0..<4 where !row.isHittable || !viewport.contains(row.frame) {
      if row.exists && row.frame.minY < viewport.minY { list.swipeDown() } else { list.swipeUp() }
    }
    XCTAssertTrue(row.wait(for: \.isHittable, toEqual: true, timeout: 5))
    XCTAssertTrue(viewport.contains(row.frame), "The expected device row must be fully visible")
    XCTAssertTrue(device.isHittable, "The expected UUID must be visible before capture and audit")
    XCTAssertTrue(viewport.contains(device.frame))
    capture("IPAD-E02-A07-hub-devices-loaded-current-account-native-acknowledgement")
    try app.performAccessibilityAudit()
    done.tap()
    XCTAssertTrue(headings.element.wait(for: \.exists, toEqual: false, timeout: 10))
    XCTAssertEqual(searchFields.count, 1)
    XCTAssertTrue(search.wait(for: \.isHittable, toEqual: true, timeout: 5))
    XCTAssertEqual(search.value as? String, "NoSuchConvertedPassageFixture")
    XCTAssertTrue(app.staticTexts["annotationHubEmpty"].exists)
    XCTAssertEqual(
      app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "annotationHubItem"))
        .count, 0)
    app.buttons["annotationHubFilters"].tap()
    XCTAssertTrue(kind.wait(for: \.isHittable, toEqual: true, timeout: 5))
    XCTAssertTrue(
      [kind.label, kind.value as? String ?? ""].contains { $0.contains("Text notes") },
      "Dismissing Devices must preserve the applied annotation type filter")
    capture("IPAD-E02-A07-hub-devices-dismissed-search-and-filter-preserved")
    app.buttons["Cancel"].tap()
    app.buttons["annotationHubDone"].tap()
  }

  @MainActor
  private func knownNativeDevice() async throws -> String {
    let credentials = try await api(
      "auth/login", method: "POST",
      body: [
        "username": "ipad-owner", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "Hub Devices public acceptance",
      ])
    let token = try XCTUnwrap(credentials["accessToken"] as? String)
    let refresh = try XCTUnwrap(credentials["refreshToken"] as? String)
    addTeardownBlock { [httpSession, refresh] in
      var request = URLRequest(url: URL(string: "http://127.0.0.1:16482/api/v1/auth/logout")!)
      request.httpMethod = "POST"
      request.timeoutInterval = 15
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: ["refreshToken": refresh])
      let (_, response) = try await httpSession.data(for: request)
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }
    let response = try await api("annotations/native/hub/devices?limit=40", token: token)
    let items = try XCTUnwrap(response["items"] as? [[String: Any]])
    XCTAssertLessThanOrEqual(items.count, 40)
    let device = try XCTUnwrap(
      items.compactMap { $0["deviceId"] as? String }.first { UUID(uuidString: $0) != nil },
      "The current account fixture must include an acknowledged native iPad device")
    let attachment = XCTAttachment(
      data: try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]),
      uniformTypeIdentifier: "public.json")
    attachment.name = "IPAD-E02-A07-bounded-public-device-acknowledgements"
    attachment.lifetime = .keepAlways
    add(attachment)
    return device
  }

  @MainActor
  private func api(
    _ path: String, method: String = "GET", token: String? = nil, body: [String: Any]? = nil
  ) async throws -> [String: Any] {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:16482/api/v1/\(path)")!)
    request.httpMethod = method
    request.timeoutInterval = 15
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await httpSession.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, path)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @MainActor
  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    let profile = ProcessInfo.processInfo.environment["IPAD_E02_PROFILE"] ?? "pro13-portrait-light"
    attachment.name = "\(name)-\(profile)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
