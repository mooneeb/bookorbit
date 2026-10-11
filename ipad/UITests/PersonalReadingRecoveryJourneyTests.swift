import Foundation
import XCTest

final class PersonalReadingRecoveryJourneyTests: XCTestCase {
  private let accessibilityAudit = E04AccessibilityAudit()
  private let personalUser = "ipad-e04-personal-recovery"
  private let activityUser = "ipad-e04-recovery-other"
  private let localNote = "E04 retained offline personal note"
  private let webNote = "E04 current authenticated web personal note"

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    let values = ProcessInfo.processInfo.environment
    let base =
      values["IPAD_E04_FAULT_URL"] ?? values["TEST_RUNNER_IPAD_E04_FAULT_URL"]
      ?? "http://127.0.0.1:16505"
    let urls = ["personal-record/reset", "annotations/online"].compactMap {
      URL(string: "\(base)/__faults/\($0)")
    }
    addTeardownBlock {
      for url in urls {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        _ = try await E04FixtureHTTP.data(for: request)
      }
    }
  }

  override func tearDownWithError() throws {
    if let testRun, testRun.failureCount > 0 {
      capture("IPAD-E04-A01-personal-recovery-failure")
      attach(
        Data(XCUIApplication().debugDescription.utf8),
        name: "IPAD-E04-A01-personal-recovery-failure-hierarchy", type: "public.plain-text")
    }
    accessibilityAudit.reportFailures(testCase: self)
    try super.tearDownWithError()
  }

  @MainActor
  func testIPADE04A01PersonalField409RecoveryRetainsDraftUntilExplicitReplacement() async throws {
    _ = try await control("personal-record/reset")
    _ = try await control("annotations/reset")
    let token = try await login(personalUser)
    let webToken = try await login(personalUser, client: "web")
    _ = try await api(
      "books/1/status", method: "PATCH", token: token, body: ["status": "want_to_read"])
    _ = try await api(
      "books/1/personal-note", method: "PATCH", token: token,
      body: ["note": "E04 personal recovery baseline"])
    _ = try await api("books/1/rating", method: "PATCH", token: token, body: ["rating": 1])
    let book = try await api("books/1", token: token)
    let title = try XCTUnwrap(book["title"] as? String)
    let app = launchAndSignIn(personalUser)
    openBook(title: title, app: app)
    downloadPDF(app)
    openPersonalEditor(app)
    _ = try await control("annotations/offline")
    let rating = app.buttons["bookReadingRating"]
    rating.tap()
    app.buttons["4 stars"].tap()
    reveal(app.buttons["Reading"].firstMatch, app: app)
    app.buttons["Reading"].firstMatch.tap()
    let date = utcDate()
    reveal(app.textFields["bookReadingStarted"], app: app)
    replace(app.textFields["bookReadingStarted"], value: date)
    reveal(app.textViews["bookReadingNote"], app: app)
    replace(app.textViews["bookReadingNote"], value: localNote)
    dismissKeyboard(app)
    let save = app.buttons["bookReadingSave"]
    XCTAssertTrue(save.wait(for: \.isEnabled, toEqual: true, timeout: 10))
    save.tap()
    XCTAssertTrue(app.staticTexts["bookReadingError"].waitForExistence(timeout: 35))
    XCTAssertTrue(app.staticTexts["bookReadingError"].label.contains("kept on this iPad"))
    assertLocalDraft(app, date: date)
    capture("IPAD-E04-A01-personal-fields-kept-after-offline-save")
    app.buttons["bookReadingCancel"].tap()
    app.terminate()
    let paths = ["status", "personal-note", "rating"].map { "/api/v1/books/1/\($0)" }
    for path in paths {
      _ = try await control("personal-record/write-arm", body: ["method": "PATCH", "path": path])
    }
    _ = try await control("annotations/online")
    app.launch()
    XCTAssertTrue(app.buttons["readingStatistics"].waitForExistence(timeout: 25))
    for (index, field) in ["status", "personal-note", "rating"].enumerated() {
      try await waitForHeldWrite(paths[index])
      let body: [String: Any]
      switch field {
      case "status": body = ["status": "abandoned"]
      case "personal-note": body = ["note": webNote]
      default: body = ["rating": 2]
      }
      _ = try await api("books/1/\(field)", method: "PATCH", token: webToken, body: body)
      _ = try await control("personal-record/release")
      try await waitForNativeResponse(path: paths[index], status: 409)
    }
    let server = try await api("books/1", token: token)
    XCTAssertEqual(server["personalNote"] as? String, webNote)
    XCTAssertEqual(server["rating"] as? Int, 2)
    XCTAssertEqual((server["readStatus"] as? [String: Any])?["status"] as? String, "abandoned")
    let historyBeforeReview = try await api(
      "books/1/reading-attempts?page=1&pageSize=25", token: token)
    openBook(title: title, app: app)
    openPersonalEditor(app)
    let recovery = app.staticTexts["bookReadingRecovery"]
    XCTAssertTrue(recovery.waitForExistence(timeout: 20))
    XCTAssertTrue(recovery.label.contains("recovery"))
    XCTAssertFalse(save.isEnabled)
    assertLocalDraft(app, date: date)
    capture("IPAD-E04-A01-three-real-server-409s-retain-native-personal-draft")
    app.buttons["bookReadingCancel"].tap()
    app.terminate()
    app.launch()
    XCTAssertTrue(app.buttons["readingStatistics"].waitForExistence(timeout: 25))
    openBook(title: title, app: app)
    openPersonalEditor(app)
    XCTAssertTrue(recovery.waitForExistence(timeout: 15))
    assertLocalDraft(app, date: date)
    reveal(app.buttons["bookReadingReviewRecovery"], app: app)
    app.buttons["bookReadingReviewRecovery"].tap()
    XCTAssertTrue(app.staticTexts["bookReadingSyncState"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["bookReadingSyncState"].label.contains("Save explicitly"))
    XCTAssertFalse(recovery.exists)
    assertLocalDraft(app, date: date)
    let reviewedServer = try await api("books/1", token: token)
    XCTAssertEqual(reviewedServer["personalNote"] as? String, webNote)
    XCTAssertEqual(reviewedServer["rating"] as? Int, 2)
    XCTAssertEqual(try json(reviewedServer["readStatus"]), try json(server["readStatus"]))
    let historyAfterReview = try await api(
      "books/1/reading-attempts?page=1&pageSize=25", token: token)
    XCTAssertEqual(try json(historyAfterReview), try json(historyBeforeReview))
    capture("IPAD-E04-A01-review-preserves-server-and-local-version")
    accessibilityAudit.collect(
      app, screen: "IPAD-E04-A01-review-preserves-server-and-local-version", testCase: self)
    XCTAssertTrue(save.wait(for: \.isEnabled, toEqual: true, timeout: 10))
    save.tap()
    XCTAssertTrue(app.buttons["editBookReading"].waitForExistence(timeout: 25))
    let replaced = try await api("books/1", token: token)
    XCTAssertEqual(replaced["personalNote"] as? String, localNote)
    XCTAssertEqual(replaced["rating"] as? Int, 4)
    let status = try XCTUnwrap(replaced["readStatus"] as? [String: Any])
    XCTAssertEqual(status["status"] as? String, "reading")
    let updatedAt = try XCTUnwrap(status["updatedAt"] as? String)
    let attempts = try await api("books/1/reading-attempts?page=1&pageSize=25", token: token)
    try await foreground(app)
    app.terminate()
    app.launch()
    XCTAssertTrue(app.buttons["readingStatistics"].waitForExistence(timeout: 25))
    try await foreground(app)
    let confirmed = try await api("books/1", token: token)
    XCTAssertEqual(confirmed["personalNote"] as? String, localNote)
    XCTAssertEqual(confirmed["rating"] as? Int, 4)
    XCTAssertEqual((confirmed["readStatus"] as? [String: Any])?["updatedAt"] as? String, updatedAt)
    let retriedAttempts = try await api("books/1/reading-attempts?page=1&pageSize=25", token: token)
    XCTAssertEqual(
      try json(retriedAttempts), try json(attempts),
      "Confirmed replacement must not create or restamp history on retry")
    openBook(title: title, app: app)
    openRecovery(app)
    XCTAssertTrue(
      app.staticTexts["No reading records need recovery."].waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["readingRecoveryExport"].isEnabled)
    capture("IPAD-E04-A01-explicit-personal-replacement-acknowledged-once")
    finish(app)
  }

  @MainActor
  func testIPADE04A01RetainedDeletedAttemptActivityExportsAndStaysAccountScoped() async throws {
    _ = try await control("personal-record/reset")
    _ = try await control("annotations/reset")
    let token = try await login(activityUser)
    let otherToken = try await login(personalUser)
    let original = try await api("books/1/sessions?page=1&pageSize=25", token: token)
    XCTAssertEqual(
      original["total"] as? Int, 0, "Use the dedicated initially empty activity recovery account")
    _ = try await api("books/1/status", method: "PATCH", token: token, body: ["status": "reading"])
    let context = try await api("books/files/1/session-context", token: token)
    let attemptID = try XCTUnwrap(context["attemptId"] as? Int)
    let book = try await api("books/1", token: token)
    let title = try XCTUnwrap(book["title"] as? String)
    let app = launchAndSignIn(activityUser)
    openBook(title: title, app: app)
    downloadPDF(app)
    reveal(app.buttons["readFile1"], app: app)
    let started = Date()
    app.buttons["readFile1"].tap()
    XCTAssertTrue(app.staticTexts["Page 1 of 3"].waitForExistence(timeout: 20))
    let acknowledged = try await waitForActualReading(token: token)
    let sessionID = try XCTUnwrap(acknowledged["id"] as? Int)
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(acknowledged["durationSeconds"] as? Int), 10)
    XCTAssertEqual(acknowledged["attemptId"] as? Int, attemptID)
    _ = try await control("annotations/offline")
    app.buttons["pdfNextPage"].tap()
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 10))
    for _ in 0..<8 { try await Task.sleep(for: .seconds(2)) }
    XCTAssertTrue(app.staticTexts["readingActivitySyncFeedback"].exists)
    capture("IPAD-E04-A01-real-offline-reading-before-captured-attempt-deletion")
    app.buttons["pdfCloseReader"].tap()
    app.terminate()
    let observedSeconds = Int(Date().timeIntervalSince(started))
    let beforeDeletion = try await api("books/1/sessions?page=1&pageSize=25", token: token)
    let committed = try XCTUnwrap(
      (beforeDeletion["items"] as? [[String: Any]])?.first { $0["id"] as? Int == sessionID })
    let serverSeconds = try XCTUnwrap(committed["durationSeconds"] as? Int)
    _ = try await api("books/1/reading-attempts/\(attemptID)", method: "DELETE", token: token)
    let deleted = try await api("books/1/reading-attempts?page=1&pageSize=25", token: token)
    XCTAssertFalse(
      (deleted["items"] as? [[String: Any]] ?? []).contains { $0["id"] as? Int == attemptID })
    app.launch()
    XCTAssertTrue(app.buttons["offlineLibrary"].waitForExistence(timeout: 25))
    _ = try await control("annotations/online")
    try await foreground(app)
    openOfflineBook(app)
    openRecovery(app, retry: true)
    XCTAssertTrue(app.staticTexts["Read session for file 1"].waitForExistence(timeout: 20))
    let identifiers = Set(recoveryRows(app).allElementsBoundByIndex.map(\.identifier))
    XCTAssertEqual(identifiers.count, 1)
    let visibleID = try XCTUnwrap(identifiers.first).replacingOccurrences(
      of: "readingRecoveryItem", with: "")
    XCTAssertNotNil(UUID(uuidString: visibleID))
    capture("IPAD-E04-A01-deleted-attempt-local-activity-retained")
    accessibilityAudit.collect(
      app, screen: "IPAD-E04-A01-deleted-attempt-local-activity-retained", testCase: self)
    let directoryResponse = try await control("annotations/public-files-directory", method: "GET")
    let directory = try XCTUnwrap(directoryResponse["directory"] as? String)
    XCTAssertEqual(URL(fileURLWithPath: directory).lastPathComponent, "Documents")
    let filename = "RecoveryUI-\(UUID().uuidString)-recovery.json"
    let export = app.buttons["readingRecoveryExport"]
    XCTAssertTrue(export.wait(for: \.isEnabled, toEqual: true, timeout: 10))
    export.tap()
    saveToFiles(filename: filename, app: app)
    XCTAssertTrue(app.staticTexts["readingRecoveryExportState"].waitForExistence(timeout: 20))
    XCTAssertTrue(
      app.staticTexts["readingRecoveryExportState"].label.contains("local versions stay"))
    let bytes = try await readExport(
      URL(fileURLWithPath: directory).appendingPathComponent(filename))
    attach(bytes, name: "IPAD-E04-A01-actual-Files-retained-reading-activity", type: "public.json")
    let artifact = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    XCTAssertEqual(artifact["version"] as? Int, 1)
    let records = try XCTUnwrap(artifact["readingSessions"] as? [[String: Any]])
    XCTAssertEqual(records.count, 1)
    let record = try XCTUnwrap(records.first)
    XCTAssertEqual(record["fileId"] as? Int, 1)
    XCTAssertEqual(record["attemptId"] as? Int, attemptID)
    let payload = try XCTUnwrap(record["session"] as? [String: Any])
    XCTAssertEqual(payload["sessionId"] as? String, visibleID)
    XCTAssertEqual(payload["source"] as? String, "ios")
    XCTAssertEqual(payload["sessionType"] as? String, "read")
    let recoveredSeconds = try XCTUnwrap(payload["durationSeconds"] as? Int)
    XCTAssertGreaterThanOrEqual(recoveredSeconds, serverSeconds + 10)
    XCTAssertLessThanOrEqual(recoveredSeconds, observedSeconds + 2)
    let timestamp = ISO8601DateFormatter()
    timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let sessionStart = try XCTUnwrap(
      timestamp.date(from: try XCTUnwrap(payload["startedAt"] as? String)))
    let sessionEnd = try XCTUnwrap(
      timestamp.date(from: try XCTUnwrap(payload["endedAt"] as? String)))
    XCTAssertGreaterThanOrEqual(sessionStart, started.addingTimeInterval(-2))
    XCTAssertGreaterThan(sessionEnd, sessionStart)
    XCTAssertLessThanOrEqual(recoveredSeconds, Int(sessionEnd.timeIntervalSince(sessionStart)) + 2)
    XCTAssertEqual((artifact["personalRecords"] as? [Any])?.count, 0)
    XCTAssertEqual((artifact["readingHistory"] as? [Any])?.count, 0)
    XCTAssertTrue(app.descendants(matching: .any)["readingRecoveryItem\(visibleID)"].exists)
    let serverAfterExport = try await api("books/1/sessions?page=1&pageSize=25", token: token)
    let canonical = try XCTUnwrap(
      (serverAfterExport["items"] as? [[String: Any]])?.first { $0["id"] as? Int == sessionID })
    XCTAssertEqual(canonical["durationSeconds"] as? Int, serverSeconds)
    XCTAssertEqual(serverAfterExport["total"] as? Int, 1)
    capture("IPAD-E04-A01-export-preserves-local-recovery-and-server-deletion")
    finish(app)
    signIn(personalUser, app: app)
    openBook(title: title, app: app)
    openRecovery(app, retry: true)
    XCTAssertFalse(app.descendants(matching: .any)["readingRecoveryItem\(visibleID)"].exists)
    XCTAssertFalse(app.staticTexts["Read session for file 1"].exists)
    let otherSessions = try await api("books/1/sessions?page=1&pageSize=25", token: otherToken)
    XCTAssertEqual(otherSessions["total"] as? Int, 0)
    capture("IPAD-E04-A01-other-account-does-not-reveal-or-flush-retained-activity")
    finish(app)
    signIn(activityUser, app: app)
    app.terminate()
    app.launch()
    XCTAssertTrue(app.buttons["readingStatistics"].waitForExistence(timeout: 25))
    try await foreground(app)
    openOfflineBook(app)
    openRecovery(app, retry: true)
    XCTAssertTrue(
      app.descendants(matching: .any)["readingRecoveryItem\(visibleID)"].waitForExistence(
        timeout: 15))
    let afterRetry = try await api("books/1/sessions?page=1&pageSize=25", token: token)
    XCTAssertEqual(try json(afterRetry), try json(serverAfterExport))
    let attemptsAfterRetry = try await api(
      "books/1/reading-attempts?page=1&pageSize=25", token: token)
    XCTAssertEqual(
      try json(attemptsAfterRetry), try json(deleted),
      "Export and retry must not resurrect the deleted captured attempt")
    capture("IPAD-E04-A01-recovery-identity-survives-account-switch-and-relaunch")
    finish(app)
  }

  @MainActor
  private func environment(_ key: String, fallback: String) -> String {
    ProcessInfo.processInfo.environment[key] ?? ProcessInfo.processInfo.environment[
      "TEST_RUNNER_\(key)"] ?? fallback
  }

  @MainActor
  private func api(
    _ path: String, method: String = "GET", token: String? = nil, body: [String: Any]? = nil
  ) async throws -> [String: Any] {
    try await request(
      environment("IPAD_E04_API_URL", fallback: "http://127.0.0.1:16502/api/v1") + "/" + path,
      method: method, token: token, body: body)
  }

  @MainActor
  private func control(_ path: String, method: String = "POST", body: [String: Any]? = nil)
    async throws -> [String: Any]
  {
    try await request(
      environment("IPAD_E04_FAULT_URL", fallback: "http://127.0.0.1:16505") + "/__faults/" + path,
      method: method, body: body)
  }

  @MainActor
  private func request(
    _ url: String, method: String, token: String? = nil, body: [String: Any]? = nil
  ) async throws -> [String: Any] {
    var request = URLRequest(url: try XCTUnwrap(URL(string: url)))
    request.httpMethod = method
    request.timeoutInterval = 15
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await E04FixtureHTTP.data(for: request)
    let status = try XCTUnwrap(response as? HTTPURLResponse).statusCode
    XCTAssertTrue(
      (200..<300).contains(status), "\(method) \(URL(string: url)?.path ?? url) HTTP\(status)")
    XCTAssertLessThanOrEqual(data.count, 512 * 1024)
    return data.isEmpty
      ? [:] : try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @MainActor
  private func login(_ username: String, client: String = "native") async throws -> String {
    let response = try await api(
      "auth/login", method: "POST",
      body: [
        "username": username, "password": "IpadFixture123", "clientKind": client,
        "deviceLabel": "E04 public recovery acceptance",
      ])
    return try XCTUnwrap(response["accessToken"] as? String)
  }

  @MainActor
  private func waitForHeldWrite(_ path: String) async throws {
    let deadline = Date().addingTimeInterval(25)
    var found = false
    while Date() < deadline {
      let state = try await control("personal-record/state", method: "GET")
      if state["held"] as? Bool == true && state["path"] as? String == path {
        found = true
        break
      }
      try await Task.sleep(for: .milliseconds(250))
    }
    XCTAssertTrue(
      found,
      "Native conditional PATCH must reach the real transport gate after its baseline GET: \(path)")
  }

  @MainActor
  private func waitForNativeResponse(path: String, status: Int) async throws {
    let deadline = Date().addingTimeInterval(15)
    var found = false
    while Date() < deadline {
      let traffic = try await control("annotations/traffic", method: "GET")
      XCTAssertFalse(traffic["truncated"] as? Bool ?? true)
      let items = try XCTUnwrap(traffic["items"] as? [[String: Any]])
      found = items.contains {
        $0["path"] as? String == path && $0["method"] as? String == "PATCH"
          && $0["status"] as? Int == status
      }
      if found {
        attach(
          try json(items.filter { $0["path"] as? String == path }),
          name:
            "IPAD-E04-A01-real-conditional-response-\(path.components(separatedBy: "/").last ?? "field")",
          type: "public.json")
        break
      }
      try await Task.sleep(for: .milliseconds(250))
    }
    XCTAssertTrue(
      found,
      "Observe the real core response rather than preflight-only recovery: \(path) HTTP\(status)")
  }

  @MainActor
  private func waitForActualReading(token: String) async throws -> [String: Any] {
    let deadline = Date().addingTimeInterval(45)
    var found: [String: Any]?
    while Date() < deadline {
      let result = try await api("books/1/sessions?page=1&pageSize=25", token: token)
      let rows = try XCTUnwrap(result["items"] as? [[String: Any]])
      XCTAssertLessThanOrEqual(rows.count, 25)
      found = rows.first {
        $0["source"] as? String == "ios" && $0["sessionType"] as? String == "read"
          && ($0["durationSeconds"] as? Int ?? 0) >= 10
      }
      if found != nil { break }
      try await Task.sleep(for: .seconds(2))
    }
    return try XCTUnwrap(
      found, "Actual loaded native PDF must publish real elapsed reading before transport fails")
  }

  @MainActor
  private func foreground(_ app: XCUIApplication) async throws {
    XCUIDevice.shared.press(.home)
    app.activate()
    try await Task.sleep(for: .seconds(2))
  }

  @MainActor
  private func utcDate() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date())
  }

  @MainActor
  private func launchAndSignIn(_ username: String) -> XCUIApplication {
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    for _ in 0..<8
    where !app.buttons["signOut"].exists && !app.textFields["username"].exists
      && !app.textFields["serverURL"].exists
    {
      let close = ["pdfCloseReader", "readingHistoryClose", "bookReadingCancel", "Done"].first {
        app.buttons[$0].exists
      }
      guard let close else { break }
      app.buttons[close].firstMatch.tap()
    }
    if app.buttons["signOut"].exists { app.buttons["signOut"].tap() }
    if app.buttons["Change server"].exists { app.buttons["Change server"].tap() }
    XCTAssertTrue(app.textFields["serverURL"].waitForExistence(timeout: 15))
    signIn(username, app: app)
    return app
  }

  @MainActor
  private func signIn(_ username: String, app: XCUIApplication) {
    if app.textFields["serverURL"].exists {
      replace(
        app.textFields["serverURL"],
        value: environment("IPAD_E04_FAULT_URL", fallback: "http://127.0.0.1:16505"))
      app.buttons["connectServer"].tap()
    }
    XCTAssertTrue(app.textFields["username"].waitForExistence(timeout: 15))
    replace(app.textFields["username"], value: username)
    replace(app.secureTextFields["password"], value: "IpadFixture123")
    app.buttons["signIn"].tap()
    XCTAssertTrue(app.buttons["readingStatistics"].waitForExistence(timeout: 25))
  }

  @MainActor
  private func openBook(title: String, app: XCUIApplication) {
    if app.buttons["All books"].exists { app.buttons["All books"].tap() }
    XCTAssertTrue(app.buttons["Table"].waitForExistence(timeout: 10))
    app.buttons["Table"].tap()
    XCTAssertTrue(app.textViews["librarySearch"].waitForExistence(timeout: 10))
    replace(app.textViews["librarySearch"], value: "\(title)\n")
    let actions = app.buttons["tableOpen1_title"]
    XCTAssertTrue(actions.wait(for: \.isHittable, toEqual: true, timeout: 20))
    actions.tap()
    XCTAssertTrue(app.buttons["Book details"].waitForExistence(timeout: 10))
    app.buttons["Book details"].tap()
    XCTAssertTrue(app.navigationBars["Book details"].waitForExistence(timeout: 10))
  }

  @MainActor
  private func openPersonalEditor(_ app: XCUIApplication) {
    let edit = app.buttons["editBookReading"]
    reveal(edit, app: app)
    edit.tap()
    XCTAssertTrue(app.buttons["bookReadingRating"].waitForExistence(timeout: 15))
  }

  @MainActor
  private func assertLocalDraft(_ app: XCUIApplication, date: String) {
    let rating = app.buttons["bookReadingRating"]
    reveal(rating, app: app)
    XCTAssertTrue(
      rating.label.contains("4 stars") || (rating.value as? String)?.contains("4 stars") == true)
    let reading = app.buttons["Reading"].firstMatch
    reveal(reading, app: app)
    XCTAssertTrue(
      reading.isSelected || reading.value as? String == "1"
        || app.descendants(matching: .any)["bookReadingStatus"].value as? String == "Reading")
    reveal(app.textFields["bookReadingStarted"], app: app)
    XCTAssertEqual(app.textFields["bookReadingStarted"].value as? String, date)
    reveal(app.textViews["bookReadingNote"], app: app)
    XCTAssertEqual(app.textViews["bookReadingNote"].value as? String, localNote)
    dismissKeyboard(app)
  }

  @MainActor
  private func downloadPDF(_ app: XCUIApplication) {
    reveal(app.buttons["offlineResources"], app: app)
    app.buttons["offlineResources"].tap()
    let selected = app.buttons["offlineSelectFile1"]
    XCTAssertTrue(selected.waitForExistence(timeout: 10))
    if selected.value as? String != "Selected" { selected.tap() }
    XCTAssertTrue(app.buttons["offlineDownload"].wait(for: \.isEnabled, toEqual: true, timeout: 10))
    app.buttons["offlineDownload"].tap()
    XCTAssertTrue(
      app.staticTexts["Verified ready for offline reading"].waitForExistence(timeout: 45))
    app.buttons["Done"].firstMatch.tap()
  }

  @MainActor
  private func openOfflineBook(_ app: XCUIApplication) {
    XCTAssertTrue(app.buttons["offlineLibrary"].wait(for: \.isHittable, toEqual: true, timeout: 25))
    app.buttons["offlineLibrary"].tap()
    XCTAssertTrue(app.buttons["offlineBook1"].wait(for: \.isHittable, toEqual: true, timeout: 15))
    app.buttons["offlineBook1"].tap()
    XCTAssertTrue(app.navigationBars["Book details"].waitForExistence(timeout: 10))
  }

  @MainActor
  private func openRecovery(_ app: XCUIApplication, retry: Bool = false) {
    reveal(app.buttons["openBookReadingHistory"], app: app)
    app.buttons["openBookReadingHistory"].tap()
    XCTAssertTrue(app.buttons["readingHistoryRecovery"].waitForExistence(timeout: 15))
    if retry {
      app.buttons["readingHistoryRetryPending"].tap()
      XCTAssertTrue(app.staticTexts["readingHistorySyncState"].waitForExistence(timeout: 25))
    }
    app.buttons["readingHistoryRecovery"].tap()
    XCTAssertTrue(app.buttons["readingRecoveryExport"].waitForExistence(timeout: 15))
  }

  @MainActor
  private func recoveryRows(_ app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "readingRecoveryItem"))
  }

  @MainActor
  private func finish(_ app: XCUIApplication) {
    if app.navigationBars["Reading record recovery"].buttons["Done"].exists {
      app.navigationBars["Reading record recovery"].buttons["Done"].tap()
    }
    if app.buttons["readingHistoryClose"].exists { app.buttons["readingHistoryClose"].tap() }
    if app.navigationBars["Book details"].buttons["Done"].exists {
      app.navigationBars["Book details"].buttons["Done"].tap()
    }
    XCTAssertTrue(app.buttons["signOut"].waitForExistence(timeout: 10))
    app.buttons["signOut"].tap()
    XCTAssertTrue(app.textFields["serverURL"].waitForExistence(timeout: 15))
  }

  @MainActor
  private func saveToFiles(filename: String, app: XCUIApplication) {
    let save = app.buttons["Save"]
    XCTAssertTrue(
      save.wait(for: \.isHittable, toEqual: true, timeout: 15),
      "Actual native Files Save dialog is required")
    if app.buttons["Browse"].isHittable { app.buttons["Browse"].tap() }
    let local = app.cells.containing(.staticText, identifier: "On My iPad").firstMatch
    if local.isHittable {
      local.tap()
    } else if app.buttons["On My iPad"].isHittable {
      app.buttons["On My iPad"].tap()
    }
    let folder = app.cells.containing(.staticText, identifier: "BookOrbit").firstMatch
    if folder.isHittable {
      folder.tap()
    } else if app.buttons["BookOrbit"].isHittable {
      app.buttons["BookOrbit"].tap()
    }
    let fields = app.textFields.matching(
      NSPredicate(format: "value CONTAINS %@", "BookOrbit reading recovery"))
    XCTAssertEqual(fields.count, 1)
    let exportName = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
    replace(fields.firstMatch, value: exportName)
    capture("IPAD-E04-A01-actual-native-Files-reading-recovery-destination")
    save.tap()
    XCTAssertTrue(save.wait(for: \.exists, toEqual: false, timeout: 15))
  }

  @MainActor
  private func readExport(_ url: URL) async throws -> Data {
    let deadline = Date().addingTimeInterval(15)
    while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
      try await Task.sleep(for: .milliseconds(250))
    }
    let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
    XCTAssertGreaterThan(size, 0)
    XCTAssertLessThanOrEqual(size, 512 * 1024)
    return try Data(contentsOf: url)
  }

  @MainActor
  private func reveal(_ element: XCUIElement, app: XCUIApplication) {
    for _ in 0..<12 {
      if element.exists && element.isHittable { return }
      if element.exists && element.frame.minY < app.frame.minY + 70 {
        app.swipeDown()
      } else {
        app.swipeUp()
      }
    }
    XCTAssertTrue(element.exists && element.isHittable)
  }

  @MainActor
  private func dismissKeyboard(_ app: XCUIApplication) {
    if app.keyboards.buttons["Hide keyboard"].exists {
      app.keyboards.buttons["Hide keyboard"].tap()
    }
  }

  @MainActor
  private func replace(_ element: XCUIElement, value: String) {
    XCTAssertTrue(element.wait(for: \.isHittable, toEqual: true, timeout: 10))
    element.tap()
    let old = element.value as? String ?? ""
    if !old.isEmpty && old != element.placeholderValue {
      element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.utf16.count))
    }
    element.typeText(value)
  }

  private func json(_ object: Any?) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: try XCTUnwrap(object), options: [.sortedKeys, .fragmentsAllowed])
  }

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func attach(_ data: Data, name: String, type: String) {
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: type)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
