import Foundation
import XCTest

final class ReadingAttemptOutboxJourneyTests: XCTestCase {
  private let accessibilityAudit = E04AccessibilityAudit()
  private let username = "ipad-e04-attempts"

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
  }

  override func tearDownWithError() throws {
    if let run = testRun, run.failureCount > 0 {
      capture("IPAD-E04-A01-attempt-outbox-failure")
      let hierarchy = XCTAttachment(string: XCUIApplication().debugDescription)
      hierarchy.name = "IPAD-E04-A01-attempt-outbox-failure-hierarchy"
      hierarchy.lifetime = .keepAlways
      add(hierarchy)
    }
    accessibilityAudit.reportFailures(testCase: self)
    try super.tearDownWithError()
  }

  @MainActor
  func testIPADE04A01HistoryCreateOfflineRestartAndReconnectOnce() async throws {
    try await fault("online")
    let token = try await login()
    let bookID = 1
    let before = try await attempts(bookID, token: token)
    let app = launchAndSignIn()
    try await openHistory(bookID, token: token, app: app)
    app.buttons["readingHistoryClose"].tap()
    downloadPDF(app)
    reveal(app.buttons["openBookReadingHistory"], app: app)
    app.buttons["openBookReadingHistory"].tap()
    XCTAssertTrue(app.buttons["readingHistoryAddAttempt"].waitForExistence(timeout: 20))
    app.buttons["readingHistoryAddAttempt"].tap()
    replace(app.textFields["readingAttemptStarted"], value: "2024-01-01")
    replace(app.textFields["readingAttemptFinished"], value: "2024-01-05")
    capture("IPAD-E04-A01-history-local-create-draft")
    try await fault("offline")
    app.buttons["readingAttemptSave"].tap()
    XCTAssertTrue(app.staticTexts["readingAttemptSyncState"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["readingAttemptSyncState"].label.contains("saved on this iPad"))
    XCTAssertTrue(app.staticTexts["readingAttemptError"].waitForExistence(timeout: 25))
    capture("IPAD-E04-A01-history-create-accepted-offline")
    app.terminate()
    let whileOffline = try await attempts(bookID, token: token)
    XCTAssertEqual(whileOffline.count, before.count)
    app.launch()
    XCTAssertTrue(app.buttons["offlineLibrary"].waitForExistence(timeout: 25))
    app.buttons["offlineLibrary"].tap()
    XCTAssertTrue(app.buttons["offlineBook1"].waitForExistence(timeout: 15))
    app.buttons["offlineBook1"].tap()
    reveal(app.buttons["openBookReadingHistory"], app: app)
    app.buttons["openBookReadingHistory"].tap()
    XCTAssertTrue(app.buttons["readingHistoryAddAttempt"].waitForExistence(timeout: 20))
    app.buttons["readingHistoryAddAttempt"].tap()
    XCTAssertEqual(app.textFields["readingAttemptStarted"].value as? String, "2024-01-01")
    XCTAssertEqual(app.textFields["readingAttemptFinished"].value as? String, "2024-01-05")
    XCTAssertFalse(app.buttons["readingAttemptSave"].isEnabled)
    capture("IPAD-E04-A01-history-create-draft-restored-still-offline")
    app.terminate()
    try await fault("online")
    app.launch()
    XCTAssertTrue(app.buttons["readingStatistics"].waitForExistence(timeout: 25))
    let synced = try await waitForAttempts(bookID, token: token) { $0.count == before.count + 1 }
    let ids = Set(before.compactMap { $0["id"] as? Int })
    let created = try XCTUnwrap(synced.first { !ids.contains($0["id"] as? Int ?? -1) })
    let id = try XCTUnwrap(created["id"] as? Int)
    XCTAssertEqual(created["startedOn"] as? String, "2024-01-01")
    XCTAssertEqual(created["endedOn"] as? String, "2024-01-05")
    XCTAssertEqual(created["outcome"] as? String, "completed")
    XCTAssertEqual(created["origin"] as? String, "manual")
    try await openHistory(bookID, token: token, app: app)
    reveal(app.descendants(matching: .any)["readingHistoryAttempt\(id)"], app: app)
    capture("IPAD-E04-A01-history-create-after-restart-synchronized")
    accessibilityAudit.collect(
      app, screen: "IPAD-E04-A01-history-create-after-restart-synchronized", testCase: self)
    app.buttons["readingHistoryRetryPending"].tap()
    XCTAssertTrue(
      app.staticTexts["Pending reading records synchronized."].waitForExistence(timeout: 20))
    let afterRetry = try await attempts(bookID, token: token)
    XCTAssertEqual(
      Set(afterRetry.compactMap { $0["id"] as? Int }), Set(synced.compactMap { $0["id"] as? Int }))
    app.terminate()
    app.launch()
    XCTAssertTrue(app.buttons["readingStatistics"].waitForExistence(timeout: 25))
    let afterRelaunch = try await attempts(bookID, token: token)
    XCTAssertEqual(afterRelaunch.count, synced.count)
    try await openHistory(bookID, token: token, app: app)
    capture("IPAD-E04-A01-history-create-retry-no-duplicate")
    finish(app)
  }

  @MainActor
  func testIPADE04A01HistoryEditRestartsAndPreservesConcurrentWebChange() async throws {
    try await fault("online")
    let token = try await login()
    let bookID = 2
    let created = try await request(
      "books/\(bookID)/reading-attempts", method: "POST", token: token,
      body: [
        "clientId": UUID().uuidString, "startedOn": "2024-02-01", "endedOn": "2024-02-03",
        "outcome": "completed",
      ])
    let id = try XCTUnwrap(created["id"] as? Int)
    let app = launchAndSignIn()
    try await openHistory(bookID, token: token, app: app)
    reveal(app.buttons["readingHistoryEditAttempt\(id)"], app: app)
    app.buttons["readingHistoryEditAttempt\(id)"].tap()
    replace(app.textFields["readingAttemptFinished"], value: "2024-02-04")
    try await fault("offline")
    app.buttons["readingAttemptSave"].tap()
    XCTAssertTrue(app.staticTexts["readingAttemptSyncState"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["readingAttemptError"].waitForExistence(timeout: 25))
    capture("IPAD-E04-A01-history-edit-accepted-offline")
    app.terminate()
    _ = try await request(
      "books/\(bookID)/reading-attempts/\(id)", method: "PATCH", token: token,
      body: [
        "endedOn": "2024-02-06", "baseUpdatedAt": try XCTUnwrap(created["updatedAt"] as? String),
      ])
    try await fault("online")
    app.launch()
    XCTAssertTrue(app.buttons["readingStatistics"].waitForExistence(timeout: 25))
    try await openHistory(bookID, token: token, app: app)
    app.buttons["readingHistoryRetryPending"].tap()
    XCTAssertTrue(app.staticTexts["readingHistorySyncState"].waitForExistence(timeout: 20))
    app.buttons["readingHistoryAddAttempt"].tap()
    XCTAssertEqual(app.textFields["readingAttemptFinished"].value as? String, "2024-02-04")
    XCTAssertFalse(app.buttons["readingAttemptSave"].isEnabled)
    capture("IPAD-E04-A01-history-edit-local-version-restored")
    app.buttons["Cancel"].tap()
    app.buttons["readingHistoryRecovery"].tap()
    let recovery = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "readingRecoveryItem")
    ).firstMatch
    XCTAssertTrue(recovery.waitForExistence(timeout: 20))
    XCTAssertTrue(app.buttons["readingRecoveryExport"].isEnabled)
    capture("IPAD-E04-A01-history-conflict-recovery-available")
    accessibilityAudit.collect(
      app, screen: "IPAD-E04-A01-history-conflict-recovery-available", testCase: self)
    let current = try await request("books/\(bookID)/reading-attempts/\(id)", token: token)
    XCTAssertEqual(current["endedOn"] as? String, "2024-02-06")
    app.buttons["Done"].firstMatch.tap()
    app.buttons["readingHistoryRetryPending"].tap()
    let retried = try await request("books/\(bookID)/reading-attempts/\(id)", token: token)
    XCTAssertEqual(retried["updatedAt"] as? String, current["updatedAt"] as? String)
    XCTAssertEqual(retried["endedOn"] as? String, "2024-02-06")
    finish(app)
  }

  @MainActor
  func testIPADE04A01HistoryDeletedTargetRemainsRecoveryAfterRestart() async throws {
    try await fault("online")
    let token = try await login()
    let bookID = 3
    let created = try await request(
      "books/\(bookID)/reading-attempts", method: "POST", token: token,
      body: [
        "clientId": UUID().uuidString, "startedOn": "2024-03-01", "endedOn": "2024-03-03",
        "outcome": "completed",
      ])
    let id = try XCTUnwrap(created["id"] as? Int)
    let app = launchAndSignIn()
    try await openHistory(bookID, token: token, app: app)
    reveal(app.buttons["readingHistoryEditAttempt\(id)"], app: app)
    app.buttons["readingHistoryEditAttempt\(id)"].tap()
    replace(app.textFields["readingAttemptFinished"], value: "2024-03-04")
    try await fault("offline")
    app.buttons["readingAttemptSave"].tap()
    XCTAssertTrue(app.staticTexts["readingAttemptError"].waitForExistence(timeout: 25))
    app.terminate()
    _ = try await request("books/\(bookID)/reading-attempts/\(id)", method: "DELETE", token: token)
    let deletedIDs = Set(try await attempts(bookID, token: token).compactMap { $0["id"] as? Int })
    XCTAssertFalse(deletedIDs.contains(id))
    try await fault("online")
    app.launch()
    XCTAssertTrue(app.buttons["readingStatistics"].waitForExistence(timeout: 25))
    try await openHistory(bookID, token: token, app: app)
    app.buttons["readingHistoryRetryPending"].tap()
    app.buttons["readingHistoryRecovery"].tap()
    let recovery = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "readingRecoveryItem")
    ).firstMatch
    XCTAssertTrue(recovery.waitForExistence(timeout: 20))
    capture("IPAD-E04-A01-history-deleted-target-local-recovery")
    let afterRecovery = try await attempts(bookID, token: token)
    XCTAssertEqual(Set(afterRecovery.compactMap { $0["id"] as? Int }), deletedIDs)
    app.terminate()
    app.launch()
    XCTAssertTrue(app.buttons["readingStatistics"].waitForExistence(timeout: 25))
    try await openHistory(bookID, token: token, app: app)
    app.buttons["readingHistoryRetryPending"].tap()
    let afterRetry = try await attempts(bookID, token: token)
    XCTAssertEqual(Set(afterRetry.compactMap { $0["id"] as? Int }), deletedIDs)
    capture("IPAD-E04-A01-history-repeated-reconnect-does-not-resurrect")
    finish(app)
  }

  @MainActor private func environment(_ key: String, fallback: String) -> String {
    ProcessInfo.processInfo.environment[key] ?? ProcessInfo.processInfo.environment[
      "TEST_RUNNER_\(key)"] ?? fallback
  }

  @MainActor
  func testIPADE04A01HistoryCommittedCreateAndEditLostReceiptsRetryOnce() async throws {
    try await fault("online")
    _ = try await receiptControl("reset", method: "POST")
    let token = try await login()
    let bookID = 4
    let before = try await attempts(bookID, token: token)
    let app = launchAndSignIn()
    try await openHistory(bookID, token: token, app: app)
    app.buttons["readingHistoryAddAttempt"].tap()
    replace(app.textFields["readingAttemptStarted"], value: "2024-04-01")
    replace(app.textFields["readingAttemptFinished"], value: "2024-04-05")
    _ = try await receiptControl("drop-next-receipt", method: "POST")
    app.buttons["readingAttemptSave"].tap()
    let committed = try await waitForAttempts(bookID, token: token) { $0.count == before.count + 1 }
    let dropped = try await waitForDroppedReceipt()
    XCTAssertEqual(dropped["dropped"] as? Int, 1)
    XCTAssertEqual(dropped["upstreamStatus"] as? Int, 201)
    XCTAssertTrue(app.staticTexts["readingAttemptError"].waitForExistence(timeout: 25))
    capture("IPAD-E04-A01-history-committed-create-receipt-lost")
    let beforeIDs = Set(before.compactMap { $0["id"] as? Int })
    let created = try XCTUnwrap(committed.first { !beforeIDs.contains($0["id"] as? Int ?? -1) })
    let id = try XCTUnwrap(created["id"] as? Int)
    app.terminate()
    app.launch()
    XCTAssertTrue(app.buttons["readingStatistics"].waitForExistence(timeout: 25))
    try await openHistory(bookID, token: token, app: app)
    app.buttons["readingHistoryRetryPending"].tap()
    XCTAssertTrue(
      app.staticTexts["Pending reading records synchronized."].waitForExistence(timeout: 20))
    let retried = try await attempts(bookID, token: token)
    XCTAssertEqual(
      Set(retried.compactMap { $0["id"] as? Int }), Set(committed.compactMap { $0["id"] as? Int }))
    let current = try await request("books/\(bookID)/reading-attempts/\(id)", token: token)
    XCTAssertEqual(current["updatedAt"] as? String, created["updatedAt"] as? String)
    reveal(app.descendants(matching: .any)["readingHistoryAttempt\(id)"], app: app)
    capture("IPAD-E04-A01-history-lost-receipt-retried-without-duplicate")
    accessibilityAudit.collect(
      app, screen: "IPAD-E04-A01-history-lost-receipt-retried-without-duplicate", testCase: self)
    _ = try await receiptControl("reset", method: "POST")

    reveal(app.buttons["readingHistoryEditAttempt\(id)"], app: app)
    app.buttons["readingHistoryEditAttempt\(id)"].tap()
    replace(app.textFields["readingAttemptFinished"], value: "2024-04-06")
    _ = try await receiptControl("drop-next-receipt", method: "POST", dropMethod: "PATCH")
    app.buttons["readingAttemptSave"].tap()
    let committedEdit = try await waitForAttempts(bookID, token: token) {
      $0.contains { $0["id"] as? Int == id && $0["endedOn"] as? String == "2024-04-06" }
    }
    let edited = try XCTUnwrap(committedEdit.first { $0["id"] as? Int == id })
    let editReceipt = try await waitForDroppedReceipt()
    XCTAssertEqual(editReceipt["upstreamStatus"] as? Int, 200)
    XCTAssertTrue(app.staticTexts["readingAttemptError"].waitForExistence(timeout: 25))
    capture("IPAD-E04-A01-history-committed-edit-receipt-lost")
    let projection = try await request("books/\(bookID)", token: token)
    let projectionRevision = (projection["readStatus"] as? [String: Any])?["updatedAt"] as? String
    app.terminate()
    app.launch()
    XCTAssertTrue(app.buttons["readingStatistics"].waitForExistence(timeout: 25))
    try await openHistory(bookID, token: token, app: app)
    app.buttons["readingHistoryRetryPending"].tap()
    XCTAssertTrue(
      app.staticTexts["Pending reading records synchronized."].waitForExistence(timeout: 20))
    XCTAssertEqual(
      app.buttons["readingHistoryAddAttempt"].label, "Add past reading attempt",
      "Matching committed edit must clear the local draft instead of creating recovery")
    let afterEditRetry = try await attempts(bookID, token: token)
    XCTAssertEqual(
      Set(afterEditRetry.compactMap { $0["id"] as? Int }),
      Set(committed.compactMap { $0["id"] as? Int }))
    let confirmedEdit = try await request("books/\(bookID)/reading-attempts/\(id)", token: token)
    XCTAssertEqual(confirmedEdit["updatedAt"] as? String, edited["updatedAt"] as? String)
    XCTAssertEqual(confirmedEdit["endedOn"] as? String, "2024-04-06")
    let unchangedProjection = try await request("books/\(bookID)", token: token)
    XCTAssertEqual(
      (unchangedProjection["readStatus"] as? [String: Any])?["updatedAt"] as? String,
      projectionRevision)
    capture("IPAD-E04-A01-history-lost-edit-receipt-acknowledged-without-conflict")
    accessibilityAudit.collect(
      app, screen: "IPAD-E04-A01-history-lost-edit-receipt-acknowledged-without-conflict",
      testCase: self)
    _ = try await receiptControl("reset", method: "POST")
    finish(app)
  }

  @MainActor private func receiptControl(
    _ action: String, method: String = "GET", dropMethod: String? = nil
  ) async throws
    -> [String: Any]
  {
    let base = environment("IPAD_E04_FAULT_URL", fallback: "http://127.0.0.1:16505")
    var request = URLRequest(
      url: try XCTUnwrap(URL(string: "\(base)/__faults/reading-attempt/\(action)")))
    request.httpMethod = method
    if let dropMethod {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: ["method": dropMethod])
    }
    let (data, response) = try await E04FixtureHTTP.data(for: request)
    XCTAssertTrue((200..<300).contains(try XCTUnwrap(response as? HTTPURLResponse).statusCode))
    return data.isEmpty
      ? [:] : try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @MainActor private func waitForDroppedReceipt() async throws -> [String: Any] {
    let deadline = Date().addingTimeInterval(20)
    var receipt = try await receiptControl("receipt")
    while receipt["dropped"] as? Int != 1, Date() < deadline {
      try await Task.sleep(for: .seconds(1))
      receipt = try await receiptControl("receipt")
    }
    XCTAssertEqual(receipt["dropped"] as? Int, 1)
    return receipt
  }

  @MainActor private func request(
    _ path: String, method: String = "GET", token: String? = nil, body: [String: Any]? = nil
  ) async throws -> [String: Any] {
    let base = environment("IPAD_E04_API_URL", fallback: "http://127.0.0.1:16502/api/v1")
    var request = URLRequest(url: try XCTUnwrap(URL(string: "\(base)/\(path)")))
    request.httpMethod = method
    request.timeoutInterval = 15
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await E04FixtureHTTP.data(for: request)
    XCTAssertTrue(
      (200..<300).contains(try XCTUnwrap(response as? HTTPURLResponse).statusCode),
      "\(method) \(path)")
    XCTAssertLessThanOrEqual(data.count, 512 * 1024)
    return data.isEmpty
      ? [:] : try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @MainActor private func login() async throws -> String {
    let response = try await request(
      "auth/login", method: "POST",
      body: [
        "username": username, "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "History outbox assertions",
      ])
    return try XCTUnwrap(response["accessToken"] as? String)
  }

  @MainActor private func attempts(_ bookID: Int, token: String) async throws -> [[String: Any]] {
    let value = try await request(
      "books/\(bookID)/reading-attempts?page=1&pageSize=100", token: token)
    let rows = try XCTUnwrap(value["items"] as? [[String: Any]])
    XCTAssertLessThanOrEqual(rows.count, 100)
    XCTAssertEqual(
      rows.count, value["total"] as? Int, "Dedicated bounded fixture must fit one page")
    return rows
  }

  @MainActor private func waitForAttempts(
    _ bookID: Int, token: String, matches: ([[String: Any]]) -> Bool
  ) async throws -> [[String: Any]] {
    let deadline = Date().addingTimeInterval(40)
    var rows = try await attempts(bookID, token: token)
    while !matches(rows), Date() < deadline {
      try await Task.sleep(for: .seconds(1))
      rows = try await attempts(bookID, token: token)
    }
    XCTAssertTrue(matches(rows), "Native accepted history did not reconcile through public API")
    return rows
  }

  @MainActor private func fault(_ state: String) async throws {
    let base = environment("IPAD_E04_FAULT_URL", fallback: "http://127.0.0.1:16505")
    var request = URLRequest(
      url: try XCTUnwrap(URL(string: "\(base)/__faults/annotations/\(state)")))
    request.httpMethod = "POST"
    let (_, response) = try await E04FixtureHTTP.data(for: request)
    XCTAssertTrue((200..<300).contains(try XCTUnwrap(response as? HTTPURLResponse).statusCode))
  }

  @MainActor private func launchAndSignIn() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    for _ in 0..<8
    where !app.buttons["signOut"].exists && !app.textFields["username"].exists
      && !app.textFields["serverURL"].exists
    {
      guard
        let close = ["Cancel", "readingHistoryClose", "Done"].first(where: {
          app.buttons[$0].exists
        })
      else { break }
      app.buttons[close].firstMatch.tap()
    }
    if app.buttons["signOut"].exists { app.buttons["signOut"].tap() }
    if app.buttons["Change server"].exists { app.buttons["Change server"].tap() }
    let server = app.textFields["serverURL"]
    XCTAssertTrue(server.waitForExistence(timeout: 15))
    replace(server, value: environment("IPAD_E04_FAULT_URL", fallback: "http://127.0.0.1:16505"))
    app.buttons["connectServer"].tap()
    XCTAssertTrue(app.textFields["username"].waitForExistence(timeout: 15))
    replace(app.textFields["username"], value: username)
    replace(app.secureTextFields["password"], value: "IpadFixture123")
    app.buttons["signIn"].tap()
    XCTAssertTrue(app.buttons["readingStatistics"].waitForExistence(timeout: 25))
    return app
  }

  @MainActor private func openHistory(_ bookID: Int, token: String, app: XCUIApplication)
    async throws
  {
    let detail = try await request("books/\(bookID)", token: token)
    let title = try XCTUnwrap(detail["title"] as? String)
    if app.buttons["All books"].exists { app.buttons["All books"].tap() }
    XCTAssertTrue(app.buttons["Table"].waitForExistence(timeout: 10))
    app.buttons["Table"].tap()
    replace(app.textViews["librarySearch"], value: "\(title)\n")
    let row = app.buttons["tableOpen\(bookID)_title"]
    XCTAssertTrue(row.wait(for: \.isHittable, toEqual: true, timeout: 20))
    row.tap()
    app.buttons["Book details"].tap()
    let history = app.buttons["openBookReadingHistory"]
    reveal(history, app: app)
    history.tap()
    XCTAssertTrue(app.buttons["readingHistoryAddAttempt"].waitForExistence(timeout: 20))
  }

  @MainActor private func replace(_ element: XCUIElement, value: String) {
    XCTAssertTrue(element.wait(for: \.isHittable, toEqual: true, timeout: 10))
    element.tap()
    let previous = element.value as? String ?? ""
    if previous != element.placeholderValue {
      element.typeText(
        String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.utf16.count))
    }
    element.typeText(value)
  }

  @MainActor private func reveal(_ target: XCUIElement, app: XCUIApplication) {
    for _ in 0..<12 {
      if target.exists && target.isHittable { return }
      if target.exists && target.frame.minY < app.frame.minY + 60 {
        app.swipeDown()
      } else {
        app.swipeUp()
      }
    }
    XCTAssertTrue(target.isHittable)
  }

  @MainActor private func downloadPDF(_ app: XCUIApplication) {
    reveal(app.buttons["offlineResources"], app: app)
    app.buttons["offlineResources"].tap()
    let selected = app.buttons["offlineSelectFile1"]
    XCTAssertTrue(selected.waitForExistence(timeout: 15))
    if selected.value as? String != "Selected" { selected.tap() }
    let download = app.buttons["offlineDownload"]
    XCTAssertTrue(download.wait(for: \.isEnabled, toEqual: true, timeout: 10))
    download.tap()
    XCTAssertTrue(
      app.staticTexts["Verified ready for offline reading"].waitForExistence(timeout: 45))
    app.buttons["Done"].firstMatch.tap()
  }

  @MainActor private func finish(_ app: XCUIApplication) {
    app.buttons["readingHistoryClose"].tap()
    app.navigationBars["Book details"].buttons.firstMatch.tap()
    if app.buttons["signOut"].exists { app.buttons["signOut"].tap() }
  }

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
