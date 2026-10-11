import Foundation
import XCTest

final class EntityManagementJourneyTests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  @MainActor
  func testIPADE03A05EntityRenamePreviewCancelApplyPreservesBook() async throws {
    let credentials = try await record(
      "auth/login", method: "POST",
      body: [
        "username": "ipad-editor", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "Entity UI control",
      ])
    let token = try XCTUnwrap(credentials["accessToken"] as? String)
    let refresh = try XCTUnwrap(credentials["refreshToken"] as? String)
    let before = try await record("books/1", token: token)
    let authors = (before["authors"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    addTeardownBlock {
      var request = URLRequest(url: URL(string: "http://localhost:16482/api/v1/books/1/metadata")!)
      request.httpMethod = "PATCH"
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: ["authors": authors])
      let (_, response) = try await URLSession.shared.data(for: request)
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
      request.url = URL(string: "http://localhost:16482/api/v1/auth/logout")!
      request.httpMethod = "POST"
      request.httpBody = try JSONSerialization.data(withJSONObject: ["refreshToken": refresh])
      _ = try await URLSession.shared.data(for: request)
    }
    _ = try await record(
      "books/1", method: "PATCH", token: token, body: ["authors": ["Entity fixture author"]])
    let app = launch(username: "ipad-editor")
    app.buttons["entityManagementEntry"].tap()
    let search = app.searchFields["Search entities"]
    XCTAssertTrue(search.waitForExistence(timeout: 15))
    search.tap()
    search.typeText("Entity fixture author\n")
    let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "entityRow"))
      .firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 15))
    try E03ProfileSupport.audit(app)
    capture("IPAD-E03-A05-entities-directory")
    row.tap()
    XCTAssertTrue(app.staticTexts["entityAffectedCount"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.staticTexts["entityAffectedCount"].label, "1 books")
    let field = app.textFields["entityName"]
    field.tap()
    field.typeText(
      String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Entity fixture author".count))
    field.typeText("Entity fixture corrected")
    app.buttons["entityPreviewRename"].tap()
    XCTAssertTrue(app.alerts["Review entity change"].waitForExistence(timeout: 10))
    try E03ProfileSupport.audit(app)
    capture("IPAD-E03-A05-entities-rename-preview")
    app.alerts.buttons["Cancel"].tap()
    XCTAssertTrue(app.buttons["entityPreviewRename"].exists)
    app.buttons["entityPreviewRename"].tap()
    XCTAssertTrue(app.alerts["Review entity change"].waitForExistence(timeout: 10))
    app.alerts.buttons["Apply"].tap()
    XCTAssertTrue(app.staticTexts["entityOutcome"].waitForExistence(timeout: 15))
    XCTAssertEqual(app.staticTexts["entityOutcome"].label, "Updated 1 books.")
    capture("IPAD-E03-A05-entities-rename-result")
    let after = try await record("books/1", token: token)
    XCTAssertEqual(
      (after["authors"] as? [[String: Any]])?.first?["name"] as? String, "Entity fixture corrected")
    XCTAssertEqual(after["id"] as? Int, before["id"] as? Int)
    XCTAssertEqual(
      try JSONSerialization.data(withJSONObject: after["files"] ?? [], options: .sortedKeys),
      try JSONSerialization.data(withJSONObject: before["files"] ?? [], options: .sortedKeys))
    app.buttons["Done"].firstMatch.tap()
    app.buttons["Done"].firstMatch.tap()
    app.buttons["signOut"].tap()
  }

  @MainActor
  func testIPADE03A05EntityManagementHiddenForRestrictedRole() {
    let app = launch(username: "ipad-restricted")
    XCTAssertFalse(app.buttons["entityManagementEntry"].exists)
    capture("IPAD-E03-A05-entities-permission-denied")
    app.buttons["signOut"].tap()
  }

  @MainActor
  func testIPADE03A05DuplicateComponentPagesWithoutAccumulation() async throws {
    let credentials = try await record(
      "auth/login", method: "POST",
      body: [
        "username": "ipad-editor", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "Entity component UI control",
      ])
    let token = try XCTUnwrap(credentials["accessToken"] as? String)
    let refresh = try XCTUnwrap(credentials["refreshToken"] as? String)
    let before = try await record("books/1", token: token)
    let tags = try XCTUnwrap(before["tags"] as? [String])
    addTeardownBlock {
      var request = URLRequest(url: URL(string: "http://localhost:16482/api/v1/books/1/metadata")!)
      request.httpMethod = "PATCH"
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: ["tags": tags])
      _ = try await URLSession.shared.data(for: request)
      request.url = URL(string: "http://localhost:16482/api/v1/auth/logout")!
      request.httpMethod = "POST"
      request.httpBody = try JSONSerialization.data(withJSONObject: ["refreshToken": refresh])
      _ = try await URLSession.shared.data(for: request)
    }
    let names = (0..<12).map { String(format: "Native duplicate fixture %02d", $0) }
    _ = try await record("books/1/metadata", method: "PATCH", token: token, body: ["tags": names])
    _ = try await record(
      "entity-manager/tag/duplicates/refresh", method: "POST", token: token,
      body: ["minSimilarity": 0.7])
    let deadline = Date().addingTimeInterval(60)
    var component: [String: Any]?
    while Date() < deadline {
      let scan = try await record(
        "entity-manager/tag/duplicates/scan?minSimilarity=0.7&page=1&pageSize=20", token: token)
      component = (scan["clusters"] as? [[String: Any]])?.first { cluster in
        (cluster["entities"] as? [[String: Any]] ?? []).contains {
          $0["name"] as? String == names[0]
        }
      }
      if component != nil { break }
      try await Task.sleep(for: .milliseconds(250))
    }
    let clusterID = try XCTUnwrap(component?["clusterId"] as? String)
    let firstMemberID = try XCTUnwrap(
      (component?["entities"] as? [[String: Any]])?.first?["id"] as? Int)
    let app = launch(username: "ipad-editor")
    app.buttons["entityManagementEntry"].tap()
    XCTAssertTrue(app.buttons["entityKind"].waitForExistence(timeout: 15))
    app.buttons["entityKind"].tap()
    app.buttons["Tags"].tap()
    app.buttons["entityReviewDuplicates"].tap()
    let componentButton = app.buttons["entityClusterPages\(clusterID)"]
    XCTAssertTrue(componentButton.waitForExistence(timeout: 15))
    componentButton.tap()
    XCTAssertTrue(app.staticTexts["entityClusterTotals"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.staticTexts["entityClusterTotals"].label, "12 entities, 66 matching pairs")
    XCTAssertEqual(app.staticTexts["entityClusterPage"].label, "Page 1")
    XCTAssertLessThanOrEqual(
      app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "entityClusterMember"))
        .count, 10)
    try E03ProfileSupport.audit(app)
    capture("IPAD-E03-A05-entities-component-page-1")
    app.buttons["entityClusterNext"].tap()
    XCTAssertTrue(
      app.staticTexts["entityClusterPage"].wait(for: \.label, toEqual: "Page 2", timeout: 15))
    XCTAssertLessThanOrEqual(
      app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "entityClusterMember"))
        .count, 2)
    XCTAssertFalse(app.buttons["entityClusterMember\(firstMemberID)"].exists)
    capture("IPAD-E03-A05-entities-component-page-2")
    app.buttons["entityClusterPrevious"].tap()
    XCTAssertTrue(
      app.staticTexts["entityClusterPage"].wait(for: \.label, toEqual: "Page 1", timeout: 15))
    XCTAssertTrue(app.staticTexts[names[0]].exists)
    app.buttons["Done"].firstMatch.tap()
    app.buttons["Done"].firstMatch.tap()
    app.buttons["Done"].firstMatch.tap()
    app.buttons["signOut"].tap()
  }

  @MainActor
  private func launch(username: String) -> XCUIApplication {
    let app = XCUIApplication()
    E03ProfileSupport.configure(app)
    app.launch()
    if app.buttons["signOut"].waitForExistence(timeout: 3) { app.buttons["signOut"].tap() }
    if app.buttons["Change server"].waitForExistence(timeout: 3) {
      app.buttons["Change server"].tap()
    }
    let server = app.textFields["serverURL"]
    XCTAssertTrue(server.waitForExistence(timeout: 10))
    server.tap()
    let existing = server.value as? String ?? ""
    server.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.utf16.count))
    server.typeText("http://localhost:16482")
    app.buttons["connectServer"].tap()
    XCTAssertTrue(app.textFields["username"].waitForExistence(timeout: 10))
    app.textFields["username"].tap()
    app.textFields["username"].typeText(username)
    app.secureTextFields["password"].tap()
    app.secureTextFields["password"].typeText("IpadFixture123")
    app.buttons["signIn"].tap()
    XCTAssertTrue(app.buttons["signOut"].waitForExistence(timeout: 20))
    return app
  }

  @MainActor
  private func record(
    _ path: String, method: String = "GET", token: String? = nil, body: [String: Any]? = nil
  ) async throws -> [String: Any] {
    var request = URLRequest(url: URL(string: "http://localhost:16482/api/v1/\(path)")!)
    request.httpMethod = method
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    XCTAssertTrue(
      (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
      "\(path): \(String(decoding: data, as: UTF8.self))")
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @MainActor
  private func capture(_ name: String) {
    E03ProfileSupport.capture(name, test: self)
  }
}
