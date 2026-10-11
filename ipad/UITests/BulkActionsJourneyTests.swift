import Foundation
import XCTest

final class BulkActionsJourneyTests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  @MainActor
  func testIPADE03A04SelectedPreviewApplyAndContentExport() async throws {
    let token = try await login()
    let before = try await books(token)
    let app = launchAndSignIn()
    defer { app.terminate() }
    app.buttons["selectBooks"].tap()
    XCTAssertTrue(app.buttons["selectBook1"].waitForExistence(timeout: 15))
    app.buttons["selectBook1"].tap()
    app.buttons["selectBook2"].tap()
    XCTAssertEqual(app.staticTexts["bookSelectionCount"].label, "2 of 100 books selected")
    app.buttons["Next"].tap()
    XCTAssertTrue(app.staticTexts["Page 2"].waitForExistence(timeout: 15))
    let additional = app.buttons.matching(
      NSPredicate(format: "identifier MATCHES %@", "selectBook[0-9]+")
    ).firstMatch
    XCTAssertTrue(additional.wait(for: \.isEnabled, toEqual: true, timeout: 15))
    let additionalID = additional.identifier
    XCTAssertFalse(["selectBook1", "selectBook2"].contains(additionalID))
    additional.tap()
    XCTAssertEqual(app.staticTexts["bookSelectionCount"].label, "3 of 100 books selected")
    app.buttons["Previous"].tap()
    XCTAssertTrue(app.buttons["selectBook1"].wait(for: \.isEnabled, toEqual: true, timeout: 15))
    XCTAssertEqual(app.buttons["selectBook1"].value as? String, "Selected")
    XCTAssertEqual(app.buttons["selectBook2"].value as? String, "Selected")
    XCTAssertEqual(app.staticTexts["bookSelectionCount"].label, "3 of 100 books selected")
    capture("IPAD-E03-A04-selection-retained-across-pages")
    app.buttons["Next"].tap()
    XCTAssertTrue(app.buttons[additionalID].wait(for: \.isEnabled, toEqual: true, timeout: 15))
    XCTAssertEqual(app.buttons[additionalID].value as? String, "Selected")
    app.buttons[additionalID].tap()
    XCTAssertEqual(app.staticTexts["bookSelectionCount"].label, "2 of 100 books selected")
    app.buttons["Previous"].tap()
    XCTAssertTrue(app.buttons["selectBook1"].wait(for: \.isEnabled, toEqual: true, timeout: 15))
    app.buttons["openBulkActions"].tap()
    let value = app.descendants(matching: .any).matching(identifier: "bulkValue").firstMatch
    XCTAssertTrue(value.waitForExistence(timeout: 10))
    value.tap()
    value.typeText("Native E03 Selected Press")
    app.buttons["previewBulkActions"].tap()
    XCTAssertTrue(app.staticTexts["bulkPreviewChange"].waitForExistence(timeout: 15))
    capture("IPAD-E03-A04-selected-edit-preview")
    try app.performAccessibilityAudit(for: [
      .hitRegion, .elementDetection, .sufficientElementDescription,
    ])
    app.buttons["Done"].tap()
    let cancelled = try await books(token)
    XCTAssertEqual(
      cancelled.map { $0["publisher"] as? String }, before.map { $0["publisher"] as? String })
    app.buttons["openBulkActions"].tap()
    value.tap()
    value.typeText("Native E03 Selected Press")
    app.buttons["previewBulkActions"].tap()
    XCTAssertTrue(app.buttons["applyBulkActions"].waitForExistence(timeout: 15))
    app.buttons["applyBulkActions"].tap()
    XCTAssertTrue(app.staticTexts["bulkStatus"].waitForExistence(timeout: 15))
    XCTAssertTrue(
      app.staticTexts["bulkStatus"].wait(
        for: \.label,
        toEqual: "Selected batch completed. Reading progress and annotations were preserved.",
        timeout: 20))
    let changed = try await books(token)
    XCTAssertEqual(changed[0]["publisher"] as? String, "Native E03 Selected Press")
    XCTAssertEqual(changed[1]["publisher"] as? String, "Native E03 Selected Press")
    XCTAssertEqual(changed[2]["publisher"] as? String, before[2]["publisher"] as? String)
    capture("IPAD-E03-A04-selected-edit-completed")
    app.buttons["Done"].tap()
    app.buttons["selectBooks"].tap()
    for (index, id) in [1, 2].enumerated() {
      let title = try XCTUnwrap(before[index]["title"] as? String)
      XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 15))
      app.staticTexts[title].firstMatch.tap()
      let read = app.buttons["readFile\(id)"]
      XCTAssertTrue(read.waitForExistence(timeout: 10))
      read.tap()
      if id == 1 {
        let passage = app.staticTexts.matching(
          NSPredicate(format: "label CONTAINS %@", "Orbit fixture: passage")
        ).firstMatch
        XCTAssertTrue(passage.waitForExistence(timeout: 20))
      } else {
        XCTAssertTrue(
          app.buttons["epubContents"].wait(for: \.isEnabled, toEqual: true, timeout: 20))
        XCTAssertTrue(app.webViews.firstMatch.exists)
      }
      capture("IPAD-E03-A04-selected-native-reader-\(id)-reopened")
      XCTAssertTrue(app.buttons["Close reader"].wait(for: \.isEnabled, toEqual: true, timeout: 15))
      app.buttons["Close reader"].tap()
      XCTAssertTrue(read.waitForExistence(timeout: 10))
      app.buttons["Done"].tap()
    }
    app.buttons["selectBooks"].tap()
    app.buttons["selectBook1"].tap()
    app.buttons["selectBook2"].tap()
    app.buttons["openBulkActions"].tap()
    XCTAssertTrue(app.buttons["bulkAction"].waitForExistence(timeout: 10))
    app.buttons["bulkAction"].tap()
    app.buttons["Export books"].tap()
    app.buttons["previewBulkActions"].tap()
    XCTAssertTrue(app.staticTexts["bulkExportPreview"].waitForExistence(timeout: 15))
    capture("IPAD-E03-A04-content-export-preview")
    app.buttons["applyBulkActions"].tap()
    XCTAssertTrue(app.staticTexts["bulkArtifact"].waitForExistence(timeout: 30))
    XCTAssertTrue(app.staticTexts["bulkArtifact"].label.contains(".zip"))
    XCTAssertFalse(app.staticTexts["bulkArtifact"].label.contains(", 0 bytes"))
    capture("IPAD-E03-A04-streamed-export-ready")
    app.buttons["saveBulkExport"].tap()
    let cancel = app.buttons["Cancel"].firstMatch
    XCTAssertTrue(cancel.waitForExistence(timeout: 10))
    capture("IPAD-E03-A04-native-files-delivery")
    cancel.tap()
    XCTAssertTrue(
      app.staticTexts["bulkStatus"].wait(
        for: \.label, toEqual: "Export kept. Save or share when ready.", timeout: 10))
    XCTAssertTrue(app.buttons["saveBulkExport"].exists)
    capture("IPAD-E03-A04-cancelled-delivery-retry")
    for (index, id) in [1, 2].enumerated() {
      _ = try await api(
        "books/\(id)/metadata", token: token,
        body: ["publisher": before[index]["publisher"] ?? NSNull()], method: "PATCH")
    }
  }

  @MainActor
  func testIPADE03A04CancelledCommittedBatchRequiresFreshReviewAfterRelaunch() async throws {
    let token = try await login()
    let before = try await books(token)
    var app = launchAndSignIn(serverURL: "http://localhost:16488")
    defer { app.terminate() }
    do {
      app.buttons["selectBooks"].tap()
      XCTAssertTrue(app.buttons["selectBook1"].waitForExistence(timeout: 15))
      app.buttons["selectBook1"].tap()
      app.buttons["selectBook2"].tap()
      app.buttons["openBulkActions"].tap()
      let value = app.descendants(matching: .any).matching(identifier: "bulkValue").firstMatch
      XCTAssertTrue(value.waitForExistence(timeout: 10))
      value.tap()
      value.typeText("Native E03 Recovered Press")
      app.buttons["previewBulkActions"].tap()
      XCTAssertTrue(app.buttons["applyBulkActions"].waitForExistence(timeout: 15))
      _ = try await fault("arm", method: "POST")
      app.buttons["applyBulkActions"].tap()
      try await waitForHeldResponse()
      let committed = try await books(token)
      XCTAssertEqual(committed[0]["publisher"] as? String, "Native E03 Recovered Press")
      XCTAssertEqual(committed[1]["publisher"] as? String, "Native E03 Recovered Press")
      XCTAssertEqual(committed[2]["publisher"] as? String, before[2]["publisher"] as? String)
      let committedVersions = try await selectedVersions(token)
      let cancel = app.buttons["cancelBulkActions"]
      XCTAssertTrue(cancel.waitForExistence(timeout: 10))
      if !cancel.isHittable { app.swipeUp() }
      cancel.tap()
      XCTAssertTrue(
        waitForLabel(
          app.staticTexts["bulkStatus"], containing: "Batch stopped after 0 confirmed books"))
      XCTAssertFalse(app.buttons["applyBulkActions"].exists)
      capture("IPAD-E03-A04-cancelled-committed-response")
      app.terminate()
      _ = try await fault("release", method: "POST")
      app = launchAndSignIn(serverURL: "http://localhost:16488")
      app.buttons["selectBooks"].tap()
      app.buttons["selectBook1"].tap()
      app.buttons["selectBook2"].tap()
      app.buttons["openBulkActions"].tap()
      XCTAssertTrue(
        waitForLabel(
          app.staticTexts["bulkStatus"], containing: "An interrupted batch confirmed 0 of 2"))
      XCTAssertFalse(app.buttons["applyBulkActions"].exists)
      let reopenedVersions = try await selectedVersions(token)
      XCTAssertEqual(reopenedVersions, committedVersions)
      capture("IPAD-E03-A04-relaunched-batch-needs-review")
      app.buttons["previewBulkActions"].tap()
      XCTAssertTrue(app.buttons["applyBulkActions"].waitForExistence(timeout: 15))
      XCTAssertTrue(
        app.staticTexts.matching(
          NSPredicate(format: "label CONTAINS %@", "Current Publisher: Native E03 Recovered Press")
        ).firstMatch.exists)
      let reviewedVersions = try await selectedVersions(token)
      XCTAssertEqual(reviewedVersions, committedVersions)
      capture("IPAD-E03-A04-recovered-current-value-preview")
      app.buttons["applyBulkActions"].tap()
      XCTAssertTrue(
        app.staticTexts["bulkStatus"].wait(
          for: \.label,
          toEqual: "Selected batch completed. Reading progress and annotations were preserved.",
          timeout: 20))
      try await restorePublishers(before, token: token)
    } catch {
      _ = try? await fault("release", method: "POST")
      try? await restorePublishers(before, token: token)
      throw error
    }
  }

  @MainActor
  func testIPADE03A04InvalidDraftShowsErrorWithoutApplying() async throws {
    let token = try await login()
    let before = try await books(token)
    let app = launchAndSignIn()
    defer { app.terminate() }
    app.buttons["selectBooks"].tap()
    XCTAssertTrue(app.buttons["selectBook1"].waitForExistence(timeout: 15))
    app.buttons["selectBook1"].tap()
    app.buttons["openBulkActions"].tap()
    XCTAssertTrue(app.buttons["bulkField"].waitForExistence(timeout: 10))
    app.buttons["bulkField"].tap()
    app.buttons["Publication year"].tap()
    let value = app.descendants(matching: .any).matching(identifier: "bulkValue").firstMatch
    value.tap()
    value.typeText("Invalid year")
    app.buttons["previewBulkActions"].tap()
    XCTAssertTrue(app.staticTexts["bulkStatus"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["applyBulkActions"].exists)
    capture("IPAD-E03-A04-invalid-draft-error")
    let after = try await books(token)
    XCTAssertEqual(
      after.map { $0["publishedYear"] as? Int }, before.map { $0["publishedYear"] as? Int })
  }

  @MainActor
  func testIPADE03A04RestrictedAccountHidesBulkActions() {
    let app = launchAndSignIn(username: "ipad-restricted", expectedCount: "0 books")
    XCTAssertFalse(app.buttons["selectBooks"].exists)
    capture("IPAD-E03-A04-restricted-actions-hidden")
    app.terminate()
  }

  @MainActor
  private func launchAndSignIn(
    username: String = "ipad-editor", expectedCount: String? = nil,
    serverURL: String = "http://localhost:16482"
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
    server.typeText(
      String(
        repeating: XCUIKeyboardKey.delete.rawValue,
        count: (server.value as? String ?? "").utf16.count))
    server.typeText(serverURL)
    app.buttons["connectServer"].tap()
    XCTAssertTrue(app.textFields["username"].waitForExistence(timeout: 10))
    app.textFields["username"].tap()
    app.textFields["username"].typeText(username)
    app.secureTextFields["password"].tap()
    app.secureTextFields["password"].typeText("IpadFixture123")
    app.buttons["signIn"].tap()
    if let expectedCount {
      XCTAssertTrue(app.staticTexts[expectedCount].waitForExistence(timeout: 20))
    } else {
      XCTAssertTrue(app.buttons["selectBooks"].wait(for: \.isEnabled, toEqual: true, timeout: 20))
    }
    return app
  }

  @MainActor
  private func login() async throws -> String {
    let data = try await api(
      "auth/login",
      body: [
        "username": "ipad-editor", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "Bulk native journey",
      ])
    return try XCTUnwrap(
      (JSONSerialization.jsonObject(with: data) as? [String: Any])?["accessToken"] as? String)
  }

  @MainActor
  private func books(_ token: String) async throws -> [[String: Any]] {
    var result: [[String: Any]] = []
    for id in [1, 2, 3] {
      let data = try await api("books/\(id)", token: token)
      result.append(try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]))
    }
    return result
  }

  @MainActor
  private func api(
    _ path: String, token: String? = nil, body: [String: Any]? = nil, method: String? = nil
  ) async throws -> Data {
    var request = URLRequest(url: URL(string: "http://localhost:16482/api/v1/\(path)")!)
    request.httpMethod = method ?? (body == nil ? "GET" : "POST")
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
  private func selectedVersions(_ token: String) async throws -> [String] {
    let data = try await api(
      "books/bulk-edit-metadata/preview", token: token,
      body: ["bookIds": [1, 2], "fields": ["publisher": ["value": "Native E03 Recovered Press"]]])
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let records = try XCTUnwrap(object["books"] as? [[String: Any]])
    return try records.map { try XCTUnwrap($0["updatedAt"] as? String) }
  }

  @MainActor
  private func restorePublishers(_ before: [[String: Any]], token: String) async throws {
    for (index, id) in [1, 2].enumerated() {
      _ = try await api(
        "books/\(id)/metadata", token: token,
        body: ["publisher": before[index]["publisher"] ?? NSNull()], method: "PATCH")
    }
  }

  @MainActor
  private func fault(_ action: String, method: String = "GET") async throws -> Data {
    var request = URLRequest(url: URL(string: "http://localhost:16488/__faults/bulk/\(action)")!)
    request.httpMethod = method
    let (data, response) = try await URLSession.shared.data(for: request)
    XCTAssertTrue((200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0))
    return data
  }

  @MainActor
  private func waitForHeldResponse() async throws {
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
      let data = try await fault("held")
      if (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["held"] as? Bool == true
      {
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTFail("The proxy did not observe a committed bulk response")
  }

  @MainActor
  private func waitForLabel(_ element: XCUIElement, containing text: String) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label CONTAINS %@", text), object: element)
    return XCTWaiter.wait(for: [expectation], timeout: 15) == .completed
  }

  @MainActor
  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
