import Foundation
import XCTest

final class ReadingRecordJourneyTests: XCTestCase {
  private let accessibilityAudit = E04AccessibilityAudit()
  private var apiURL: String {
    ProcessInfo.processInfo.environment["IPAD_E04_API_URL"] ?? "http://localhost:16502/api/v1"
  }
  private var serverURL: String { apiURL.replacingOccurrences(of: "/api/v1", with: "") }
  private var username: String { "ipad-e04-record" }

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
  }

  override func tearDownWithError() throws {
    accessibilityAudit.reportFailures(testCase: self)
    if let run = testRun, run.failureCount > 0 {
      let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
      attachment.name = "IPAD-E04-A01-failure"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    try super.tearDownWithError()
  }

  @MainActor
  func testIPADE04A01NativeReadingRecordAndHistory() async throws {
    let credentials = try await request(
      "auth/login", method: "POST",
      body: [
        "username": username, "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "E04 reading record fixture",
      ])
    let token = try XCTUnwrap(credentials["accessToken"] as? String)
    let previous = try await request("books/1/sessions?pageSize=100", token: token)
    for session in previous["items"] as? [[String: Any]] ?? [] {
      let id = try XCTUnwrap(session["id"] as? Int)
      _ = try await request("books/1/sessions/\(id)", method: "DELETE", token: token)
    }
    _ = try await request(
      "books/1/status", method: "PATCH", token: token, body: ["status": "unread"])
    _ = try await request(
      "books/1/personal-note", method: "PATCH", token: token, body: ["note": NSNull()])
    _ = try await request(
      "books/1/rating", method: "PATCH", token: token, body: ["rating": NSNull()])
    let detail = try await request("books/1", token: token)
    let title = try XCTUnwrap(detail["title"] as? String)

    let app = launchRecordActor()
    openBookDetails(app, title: title)
    try await runPersonalRecordDraftAndSave(app, title: title, token: token)
    try await runManualNativeSessionsAndHistory(app, title: title, token: token)
  }

  @MainActor
  func testIPADE04A01RetainedEditorNavigationCheckpoint() async throws {
    let context = try await retainedRecordContext()
    XCTAssertTrue(context.sessions.isEmpty)
    let app = launchRecordActor()
    openBookDetails(app, title: context.title)
    let edit = app.buttons["editBookReading"]
    revealBookDetails(edit, in: app)
    XCTAssertTrue(edit.waitForExistence(timeout: 10))
    edit.tap()
    XCTAssertTrue(app.buttons["bookReadingRating"].waitForExistence(timeout: 10))
    capture("IPAD-E04-A01-retained-editor-navigation-checkpoint")
    app.buttons["bookReadingCancel"].tap()
  }

  @MainActor
  func testIPADE04A01RetainedPersonalRecordDraftAndSave() async throws {
    let context = try await retainedRecordContext()
    XCTAssertTrue(context.sessions.isEmpty)
    XCTAssertTrue(context.book["personalNote"] is NSNull)
    XCTAssertTrue(context.book["rating"] is NSNull)
    XCTAssertEqual(
      (context.book["readStatus"] as? [String: Any])?["status"] as? String, "unread")
    let app = launchRecordActor()
    openBookDetails(app, title: context.title)
    try await runPersonalRecordDraftAndSave(app, title: context.title, token: context.token)
    capture("IPAD-E04-A01-retained-personal-record-saved-checkpoint")
  }

  @MainActor
  func testIPADE04A01RetainedStatusSelectionCheckpoint() async throws {
    let context = try await retainedRecordContext()
    assertUnsavedRecordBaseline(book: context.book, sessions: context.sessions)
    let app = launchRecordActor()
    openBookDetails(app, title: context.title)
    openPersonalRecordEditor(app)
    assertDraftRating(app)
    let status = readingStatusWheel(app)
    XCTAssertEqual(status.value as? String, "Unread")
    status.adjust(toPickerWheelValue: "Reading")
    XCTAssertEqual(status.value as? String, "Reading")
    capture("IPAD-E04-A01-retained-status-selection-checkpoint")
  }

  @MainActor
  func testIPADE04A01RetainedRemainingNoteDraftAndSave() async throws {
    let context = try await retainedRecordContext()
    assertUnsavedRecordBaseline(book: context.book, sessions: context.sessions)
    let app = launchRecordActor()
    openBookDetails(app, title: context.title)
    openPersonalRecordEditor(app)
    assertDraftRating(app)
    XCTAssertEqual(readingStatusWheel(app).value as? String, "Reading")
    let note = app.textViews["bookReadingNote"]
    XCTAssertTrue(note.waitForExistence(timeout: 10))
    XCTAssertEqual(note.value as? String, "")
    try await runRemainingNoteDraftAndSave(app, title: context.title, token: context.token)
    let sessions = try await request("books/1/sessions?pageSize=100", token: context.token)
    XCTAssertTrue((try XCTUnwrap(sessions["items"] as? [[String: Any]])).isEmpty)
    capture("IPAD-E04-A01-retained-remaining-record-saved-checkpoint")
  }

  @MainActor
  func testIPADE04A01RetainedManualNativeSessionsAndHistory() async throws {
    let context = try await retainedRecordContext()
    XCTAssertTrue(context.sessions.isEmpty)
    XCTAssertEqual(context.book["personalNote"] as? String, "E04 native personal note")
    XCTAssertEqual(context.book["rating"] as? Int, 4)
    XCTAssertEqual(
      (context.book["readStatus"] as? [String: Any])?["status"] as? String, "reading")
    let app = launchRecordActor()
    openBookDetails(app, title: context.title)
    try await runManualNativeSessionsAndHistory(app, title: context.title, token: context.token)
  }

  @MainActor
  func testIPADE04A01RetainedHistoryPersistenceAndHandoff() async throws {
    let context = try await retainedRecordContext()
    assertRetainedSavedRecord(context.book)
    try assertRetainedCompletedHistory(context.history)
    let app = launchRecordActor()
    openBookDetails(app, title: context.title)
    let history = app.buttons["openBookReadingHistory"]
    revealBookDetails(history, in: app)
    history.tap()
    let count = app.descendants(matching: .any)["readingHistorySessionCount"]
    XCTAssertTrue(count.waitForExistence(timeout: 15))
    capture("IPAD-E04-A01-retained-history-before-relaunch")
    accessibilityAudit.collect(
      app, screen: "IPAD-E04-A01-retained-history-before-relaunch", testCase: self)
    app.buttons["readingHistoryClose"].tap()
    app.terminate()
    app.launch()
    openBookDetails(app, title: context.title)
    let afterRelaunch = try await request("books/1", token: context.token)
    assertRetainedSavedRecord(afterRelaunch)
    let sessions = try await request("books/1/sessions?pageSize=100", token: context.token)
    try assertRetainedCompletedHistory(sessions)
    revealBookDetails(history, in: app)
    history.tap()
    XCTAssertTrue(count.waitForExistence(timeout: 15))
    capture("IPAD-E04-A01-retained-history-persisted-after-relaunch")
    let evidence = try JSONSerialization.data(
      withJSONObject: ["book": afterRelaunch, "history": sessions],
      options: [.prettyPrinted, .sortedKeys])
    let attachment = XCTAttachment(data: evidence, uniformTypeIdentifier: "public.json")
    attachment.name = "IPAD-E04-A01-retained-history-persistence-public-proof"
    attachment.lifetime = .keepAlways
    add(attachment)
    app.buttons["readingHistoryClose"].tap()
    try await handoff()
  }

  @MainActor
  func testIPADE04A01RetainedHistoryAccessibilityCheckpoint() async throws {
    let context = try await retainedRecordContext()
    assertRetainedSavedRecord(context.book)
    try assertRetainedCompletedHistory(context.history)
    let app = launchRecordActor()
    openBookDetails(app, title: context.title)
    let history = app.buttons["openBookReadingHistory"]
    revealBookDetails(history, in: app)
    history.tap()
    let count = app.descendants(matching: .any)["readingHistorySessionCount"]
    XCTAssertTrue(count.waitForExistence(timeout: 15))
    let historyList = app.collectionViews.containing(
      .button, identifier: "readingHistoryAddManual"
    ).firstMatch
    XCTAssertTrue(historyList.waitForExistence(timeout: 10))
    let targets: [(element: XCUIElement, label: String, before: String)] = [
      (count, "Sessions, 2", "Dynamic Type font sizes are partially unsupported"),
      (
        app.staticTexts["Average session, 0h 2m"], "Average session, 0h 2m",
        "Dynamic Type font sizes are partially unsupported"
      ),
      (
        app.buttons["readingHistoryClose"], "Done",
        "Dynamic Type font sizes are partially unsupported"
      ),
      (
        app.descendants(matching: .any)["readingHistoryTotalTime"], "Reading time, 0h 5m",
        "Dynamic Type font sizes are partially unsupported"
      ),
      (app.staticTexts["Reading record"], "Reading record", "Contrast nearly passed"),
      (
        app.buttons["readingHistoryAddManual"], "Add manual session", "Contrast nearly passed"
      ),
      (
        app.buttons["readingHistoryAddAttempt"], "Add past reading attempt",
        "Contrast nearly passed"
      ),
      (app.buttons["readingHistoryReread"], "Start reread", "Contrast nearly passed"),
      (
        app.buttons["readingHistoryRetryPending"], "Retry pending reading records",
        "Contrast nearly passed"
      ),
      (
        app.buttons["readingHistoryRecovery"], "Review local reading recovery",
        "Contrast nearly passed"
      ),
      (app.staticTexts["Session totals"], "Session totals", "Contrast nearly passed"),
    ]
    let beforeAuditLabels = [
      "Sessions, 2": "Sessions", "Average session, 0h 2m": "Average session",
      "Reading time, 0h 5m": "Reading time",
    ]
    var identifiedTargets: [[String: Any]] = []
    for target in targets {
      XCTAssertTrue(target.element.wait(for: \.isHittable, toEqual: true, timeout: 10))
      XCTAssertEqual(target.element.label, target.label)
      XCTAssertTrue(historyList.frame.contains(target.element.frame))
      identifiedTargets.append([
        "beforeFinding": target.before,
        "beforeLabel": beforeAuditLabels[target.label] ?? target.label,
        "expectedLabel": target.label,
        "afterLabel": target.element.label, "afterIdentifier": target.element.identifier,
        "afterFrame": String(describing: target.element.frame),
      ])
    }
    let targetEvidence = try JSONSerialization.data(
      withJSONObject: [
        "baselineRun": "run-10682-1791721014425", "identifiedTargets": identifiedTargets,
        "auditComparison": "Compare all findings with E04-native-accessibility-results.",
      ], options: [.prettyPrinted, .sortedKeys])
    let targetAttachment = XCTAttachment(data: targetEvidence, uniformTypeIdentifier: "public.json")
    targetAttachment.name = "IPAD-E04-A01-retained-history-identified-accessibility-targets"
    targetAttachment.lifetime = .keepAlways
    add(targetAttachment)
    accessibilityAudit.collect(
      app, screen: "IPAD-E04-A01-retained-history-accessibility-checkpoint", testCase: self)
    app.buttons["readingHistoryClose"].tap()
    XCTAssertTrue(
      app.buttons["readingHistoryClose"].wait(for: \.exists, toEqual: false, timeout: 10))
    let afterBook = try await request("books/1", token: context.token)
    let afterHistory = try await request("books/1/sessions?pageSize=100", token: context.token)
    assertRetainedSavedRecord(afterBook)
    try assertRetainedCompletedHistory(afterHistory)
    let publicEvidence = try JSONSerialization.data(
      withJSONObject: ["book": afterBook, "history": afterHistory],
      options: [.prettyPrinted, .sortedKeys])
    let publicAttachment = XCTAttachment(data: publicEvidence, uniformTypeIdentifier: "public.json")
    publicAttachment.name = "IPAD-E04-A01-retained-history-accessibility-unchanged-public-proof"
    publicAttachment.lifetime = .keepAlways
    add(publicAttachment)
  }

  @MainActor
  private func assertRetainedSavedRecord(_ book: [String: Any]) {
    XCTAssertEqual(book["personalNote"] as? String, "E04 native personal note")
    XCTAssertEqual(book["rating"] as? Int, 4)
    XCTAssertEqual((book["readStatus"] as? [String: Any])?["status"] as? String, "reading")
  }

  @MainActor
  private func assertRetainedCompletedHistory(_ history: [String: Any]) throws {
    let sessions = try XCTUnwrap(history["items"] as? [[String: Any]])
    XCTAssertEqual(sessions.count, 2)
    XCTAssertEqual(Set(sessions.compactMap { $0["id"] as? Int }), Set([27, 28]))
    XCTAssertEqual(history["total"] as? Int, 2)
    let stats = try XCTUnwrap(history["stats"] as? [String: Any])
    XCTAssertEqual(stats["totalSessions"] as? Int, 2)
    XCTAssertEqual(stats["totalSeconds"] as? Int, 316)
    for (id, source, duration) in [(27, "manual", 300), (28, "ios", 16)] {
      let session = try XCTUnwrap(sessions.first { $0["id"] as? Int == id })
      XCTAssertEqual(session["source"] as? String, source)
      XCTAssertEqual(session["durationSeconds"] as? Int, duration)
      XCTAssertEqual(session["attemptId"] as? Int, 130)
      XCTAssertEqual(session["bookFileId"] as? Int, 1)
      XCTAssertEqual(session["sessionType"] as? String, "read")
      XCTAssertEqual(session["format"] as? String, "pdf")
    }
  }

  @MainActor
  private func retainedRecordContext() async throws -> (
    token: String, title: String, book: [String: Any], sessions: [[String: Any]],
    history: [String: Any]
  ) {
    let credentials = try await request(
      "auth/login", method: "POST",
      body: [
        "username": username, "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "E04 retained reading record checkpoint",
      ])
    let actor = try XCTUnwrap(credentials["user"] as? [String: Any])
    XCTAssertEqual(actor["id"] as? Int, 6)
    XCTAssertEqual(actor["username"] as? String, username)
    let token = try XCTUnwrap(credentials["accessToken"] as? String)
    let book = try await request("books/1", token: token)
    XCTAssertEqual(book["id"] as? Int, 1)
    let files = try XCTUnwrap(book["files"] as? [[String: Any]])
    XCTAssertTrue(files.contains { $0["id"] as? Int == 1 })
    let title = try XCTUnwrap(book["title"] as? String)
    let history = try await request("books/1/sessions?pageSize=100", token: token)
    let sessions = try XCTUnwrap(history["items"] as? [[String: Any]])
    let evidence = try JSONSerialization.data(
      withJSONObject: [
        "username": username, "userId": 6, "bookId": 1, "fileId": 1,
        "book": book, "sessions": sessions,
      ], options: [.prettyPrinted, .sortedKeys])
    let attachment = XCTAttachment(data: evidence, uniformTypeIdentifier: "public.json")
    attachment.name = "IPAD-E04-A01-retained-actor-resource-precondition"
    attachment.lifetime = .keepAlways
    add(attachment)
    return (token, title, book, sessions, history)
  }

  @MainActor
  private func launchRecordActor() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    if !app.textFields["serverURL"].waitForExistence(timeout: 3) {
      if app.buttons["signOut"].exists { app.buttons["signOut"].tap() }
      if app.buttons["Change server"].exists { app.buttons["Change server"].tap() }
    }
    let server = app.textFields["serverURL"]
    XCTAssertTrue(server.waitForExistence(timeout: 10))
    replace(server, value: serverURL)
    app.buttons["connectServer"].tap()
    let user = app.textFields["username"]
    XCTAssertTrue(user.waitForExistence(timeout: 10))
    replace(user, value: username)
    replace(app.secureTextFields["password"], value: "IpadFixture123")
    app.buttons["signIn"].tap()
    return app
  }

  @MainActor
  private func runPersonalRecordDraftAndSave(
    _ app: XCUIApplication, title: String, token: String
  ) async throws {
    openPersonalRecordEditor(app)
    let rating = app.buttons["bookReadingRating"]
    XCTAssertTrue(rating.waitForExistence(timeout: 10))
    rating.tap()
    app.buttons["4 stars"].tap()
    let status = readingStatusWheel(app)
    status.adjust(toPickerWheelValue: "Reading")
    XCTAssertEqual(status.value as? String, "Reading")
    try await runRemainingNoteDraftAndSave(app, title: title, token: token)
  }

  @MainActor
  private func runRemainingNoteDraftAndSave(
    _ app: XCUIApplication, title: String, token: String
  ) async throws {
    let edit = app.buttons["editBookReading"]
    let note = app.textViews["bookReadingNote"]
    reveal(note, in: app)
    replace(note, value: "E04 native personal note")
    capture("IPAD-E04-A01-personal-record-draft")
    app.terminate()
    app.launch()
    openBookDetails(app, title: title)
    revealBookDetails(edit, in: app)
    edit.tap()
    assertDraftRating(app)
    XCTAssertEqual(readingStatusWheel(app).value as? String, "Reading")
    XCTAssertTrue(note.waitForExistence(timeout: 10))
    reveal(note, in: app)
    XCTAssertEqual(note.value as? String, "E04 native personal note")
    capture("IPAD-E04-A01-personal-record-draft-after-relaunch")
    let save = app.buttons["bookReadingSave"]
    XCTAssertTrue(save.wait(for: \.isEnabled, toEqual: true, timeout: 10))
    save.tap()
    revealBookDetails(edit, in: app)
    XCTAssertTrue(edit.waitForExistence(timeout: 20))
    let recorded = try await request("books/1", token: token)
    XCTAssertEqual(recorded["personalNote"] as? String, "E04 native personal note")
    XCTAssertEqual(recorded["rating"] as? Int, 4)
    XCTAssertEqual((recorded["readStatus"] as? [String: Any])?["status"] as? String, "reading")
  }

  @MainActor
  private func assertUnsavedRecordBaseline(book: [String: Any], sessions: [[String: Any]]) {
    XCTAssertTrue(sessions.isEmpty)
    XCTAssertTrue(book["personalNote"] is NSNull)
    XCTAssertTrue(book["rating"] is NSNull)
    XCTAssertEqual((book["readStatus"] as? [String: Any])?["status"] as? String, "unread")
  }

  @MainActor
  private func openPersonalRecordEditor(_ app: XCUIApplication) {
    let edit = app.buttons["editBookReading"]
    revealBookDetails(edit, in: app)
    XCTAssertTrue(edit.waitForExistence(timeout: 10))
    edit.tap()
    XCTAssertTrue(app.buttons["bookReadingRating"].waitForExistence(timeout: 10))
  }

  @MainActor
  private func assertDraftRating(_ app: XCUIApplication) {
    let rating = app.buttons["bookReadingRating"]
    XCTAssertTrue(rating.wait(for: \.isHittable, toEqual: true, timeout: 10))
    XCTAssertTrue(
      rating.label.contains("4 stars") || (rating.value as? String ?? "").contains("4 stars"))
  }

  @MainActor
  private func readingStatusWheel(_ app: XCUIApplication) -> XCUIElement {
    let status = app.pickers["bookReadingStatus"].pickerWheels.firstMatch
    XCTAssertTrue(status.wait(for: \.isHittable, toEqual: true, timeout: 10))
    return status
  }

  @MainActor
  private func runManualNativeSessionsAndHistory(
    _ app: XCUIApplication, title: String, token: String
  ) async throws {
    let history = app.buttons["openBookReadingHistory"]
    revealBookDetails(history, in: app)
    history.tap()
    let manual = app.buttons["readingHistoryAddManual"]
    XCTAssertTrue(manual.waitForExistence(timeout: 10))
    capture("IPAD-E04-A01-session-history-empty")
    manual.tap()
    XCTAssertTrue(app.buttons["readingManualSave"].waitForExistence(timeout: 10))
    capture("IPAD-E04-A01-manual-session-form")
    app.buttons["readingManualSave"].tap()
    XCTAssertTrue(app.staticTexts["Manual session synchronized."].waitForExistence(timeout: 20))
    capture("IPAD-E04-A01-manual-session-synchronized")
    app.buttons["readingHistoryClose"].tap()
    let read = app.buttons["readFile1"]
    revealBookDetails(read, in: app)
    read.tap()
    XCTAssertTrue(app.staticTexts["Page 1 of 3"].waitForExistence(timeout: 20))
    capture("IPAD-E04-A01-actual-native-reading")
    let deadline = Date().addingTimeInterval(45)
    var native: [String: Any]?
    while Date() < deadline {
      let sessions = try await request("books/1/sessions", token: token)
      native = (sessions["items"] as? [[String: Any]])?.first {
        ($0["source"] as? String) == "ios" && ($0["durationSeconds"] as? Int ?? 0) >= 10
      }
      if native != nil { break }
      try await Task.sleep(for: .seconds(1))
    }
    XCTAssertNotNil(native, "Visible native reading must create a real elapsed-time session")
    app.buttons["pdfCloseReader"].tap()
    revealBookDetails(read, in: app)
    XCTAssertTrue(read.waitForExistence(timeout: 20))
    revealBookDetails(history, in: app)
    history.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["readingHistorySessionCount"].waitForExistence(timeout: 15))
    capture("IPAD-E04-A01-real-native-and-manual-history")
    accessibilityAudit.collect(
      app, screen: "IPAD-E04-A01-real-native-and-manual-history", testCase: self)
    let sessions = try await request("books/1/sessions", token: token)
    let items = try XCTUnwrap(sessions["items"] as? [[String: Any]])
    XCTAssertEqual(items.count, 2)
    XCTAssertEqual(items.filter { $0["source"] as? String == "ios" }.count, 1)
    XCTAssertEqual(
      items.first { $0["source"] as? String == "manual" }?["durationSeconds"] as? Int, 300)
    app.buttons["readingHistoryClose"].tap()
    app.terminate()
    app.launch()
    openBookDetails(app, title: title)
    let afterRelaunch = try await request("books/1/sessions", token: token)
    XCTAssertEqual((afterRelaunch["items"] as? [[String: Any]])?.count, 2)
    try await handoff()
  }

  @MainActor
  private func revealBookDetails(_ element: XCUIElement, in app: XCUIApplication) {
    let form = app.collectionViews["bookDetailContent"]
    XCTAssertTrue(form.wait(for: \.isHittable, toEqual: true, timeout: 10))
    for _ in 0..<12 {
      if element.exists && element.isHittable && form.frame.contains(element.frame) { break }
      if element.exists && element.frame.minY < form.frame.minY {
        form.swipeDown()
      } else {
        form.swipeUp()
      }
    }
    XCTAssertTrue(element.waitForExistence(timeout: 5))
    XCTAssertTrue(element.wait(for: \.isHittable, toEqual: true, timeout: 5))
    XCTAssertTrue(form.frame.contains(element.frame))
  }

  @MainActor private func openBookDetails(_ app: XCUIApplication, title: String) {
    XCTAssertTrue(app.buttons["readingStatistics"].waitForExistence(timeout: 20))
    if app.buttons["All books"].exists { app.buttons["All books"].tap() }
    XCTAssertTrue(app.buttons["Table"].waitForExistence(timeout: 10))
    app.buttons["Table"].tap()
    let search = app.textViews["librarySearch"]
    XCTAssertTrue(search.waitForExistence(timeout: 10))
    replace(search, value: "\(title)\n")
    let book = app.buttons["tableOpen1_title"]
    XCTAssertTrue(book.wait(for: \.isHittable, toEqual: true, timeout: 20))
    book.tap()
    XCTAssertTrue(app.buttons["Book details"].waitForExistence(timeout: 10))
    app.buttons["Book details"].tap()
    XCTAssertTrue(app.navigationBars["Book details"].waitForExistence(timeout: 10))
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

  @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
    for _ in 0..<10 {
      if element.exists && element.isHittable { return }
      if app.scrollViews.firstMatch.exists {
        app.scrollViews.firstMatch.swipeUp()
      } else {
        app.swipeUp()
      }
    }
    XCTAssertTrue(element.isHittable)
  }

  @MainActor
  private func request(
    _ path: String, method: String = "GET", token: String? = nil, body: [String: Any]? = nil
  ) async throws -> [String: Any] {
    var request = URLRequest(url: URL(string: "\(apiURL)/\(path)")!)
    request.httpMethod = method
    request.timeoutInterval = 15
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await E04FixtureHTTP.data(for: request)
    let http = try XCTUnwrap(response as? HTTPURLResponse)
    XCTAssertTrue((200...299).contains(http.statusCode), "\(method) \(path): \(http.statusCode)")
    return data.isEmpty
      ? [:] : try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @MainActor
  private func handoff() async throws {
    let receiver = try XCTUnwrap(ProcessInfo.processInfo.environment["IPAD_E04_RECEIVER_URL"])
    var request = URLRequest(url: URL(string: "\(receiver)/native-handoff")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "testId": "IPAD-E04-A01", "case": "A01", "username": username,
      "record": [
        "username": username, "bookId": 1, "fileId": 1, "readStatus": "reading", "rating": 4,
        "personalNote": "E04 native personal note",
        "nativeSession": ["source": "ios", "sessionType": "read", "minimumSeconds": 10],
        "manualSession": ["source": "manual", "durationSeconds": 300],
      ],
    ])
    let (_, response) = try await E04FixtureHTTP.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
  }

  @MainActor private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
