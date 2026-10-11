import Foundation
import XCTest

final class NativeReadingActivityRecoveryJourneyTests: XCTestCase {
  private let accessibilityAudit = E04AccessibilityAudit()
  private struct Book {
    let id: Int
    let fileID: Int
    let title: String
  }

  private struct Row {
    let id: Int
    let seconds: Int
    let type: String
    let source: String
    let attemptID: Int?
  }

  private struct Sessions {
    let rows: [Row]
    var seconds: Int { rows.reduce(0) { $0 + $1.seconds } }
    func seconds(_ type: String) -> Int {
      rows.filter { $0.type == type }.reduce(0) { $0 + $1.seconds }
    }
  }

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    let values = ProcessInfo.processInfo.environment
    let base =
      values["IPAD_E04_FAULT_URL"] ?? values["TEST_RUNNER_IPAD_E04_FAULT_URL"]
      ?? "http://127.0.0.1:16505"
    let url = try XCTUnwrap(URL(string: "\(base)/__faults/annotations/online"))
    addTeardownBlock {
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.timeoutInterval = 10
      _ = try await E04FixtureHTTP.data(for: request)
    }
  }

  override func tearDownWithError() throws {
    if let testRun, testRun.failureCount > 0 {
      capture("IPAD-E04-A01-activity-recovery-failure")
      let hierarchy = XCTAttachment(string: XCUIApplication().debugDescription)
      hierarchy.name = "IPAD-E04-A01-activity-recovery-failure-hierarchy"
      hierarchy.lifetime = .keepAlways
      add(hierarchy)
    }
    accessibilityAudit.reportFailures(testCase: self)
    try super.tearDownWithError()
  }

  @MainActor
  func testIPADE04A01ListeningPauseAndBackgroundPlaybackAccounting() async throws {
    try await fault("online")
    let username = "ipad-e04-activity-listen"
    let token = try await login(username)
    let book = try await mediaBook(title: "E04 activity audio", format: "m4a", token: token)
    try await requireEmpty(book, token: token)
    let app = launchAndSignIn(username)
    openBook(book, app: app)
    openFile(book, app: app)
    let play = app.buttons["audiobookPlayPause"]
    XCTAssertTrue(play.wait(for: \.isEnabled, toEqual: true, timeout: 25))
    let duration = try playbackSeconds(app, total: true)
    XCTAssertGreaterThanOrEqual(
      duration, 60, "Real media must cover startup and lifecycle observations")
    let started = Date()
    play.tap()
    XCTAssertTrue(play.wait(for: \.label, toEqual: "Pause", timeout: 10))
    _ = try await waitForSessions(book, token: token) { $0.seconds("listen") >= 10 }
    capture("IPAD-E04-A01-actual-audio-playing")
    let beforePosition = try playbackSeconds(app)
    let before = try await sessions(book, token: token)
    XCUIDevice.shared.press(.home)
    try await observe(seconds: 20)
    app.activate()
    XCTAssertTrue(play.wait(for: \.label, toEqual: "Pause", timeout: 10))
    let afterPosition = try playbackSeconds(app)
    XCTAssertGreaterThanOrEqual(
      afterPosition - beforePosition, 17,
      "Active audio must actually continue while backgrounded; a simulator limitation must be reported"
    )
    let continued = try await waitForSessions(book, token: token) {
      $0.seconds("listen") >= before.seconds("listen") + 17
    }
    XCTAssertLessThanOrEqual(
      continued.seconds("listen") - before.seconds("listen"),
      afterPosition - beforePosition + 7, "Checkpoint lag must not count playback twice")
    capture("IPAD-E04-A01-background-audio-position-and-session-continued")
    play.tap()
    XCTAssertTrue(play.wait(for: \.label, toEqual: "Play", timeout: 10))
    try await settle(app)
    let pausedPosition = try playbackSeconds(app)
    let paused = try await sessions(book, token: token)
    try await observe(seconds: 6)
    XCTAssertEqual(try playbackSeconds(app), pausedPosition)
    let pausedForeground = try await sessions(book, token: token)
    XCTAssertEqual(pausedForeground.seconds, paused.seconds)
    XCUIDevice.shared.press(.home)
    try await observe(seconds: 6)
    app.activate()
    XCTAssertTrue(play.wait(for: \.label, toEqual: "Play", timeout: 10))
    XCTAssertEqual(try playbackSeconds(app), pausedPosition)
    let pausedBackground = try await sessions(book, token: token)
    XCTAssertEqual(pausedBackground.seconds, paused.seconds)
    XCTAssertEqual(paused.rows.count, 1)
    XCTAssertEqual(Set(paused.rows.map(\.type)), ["listen"])
    XCTAssertLessThanOrEqual(paused.seconds, Int(Date().timeIntervalSince(started)) + 2)
    try await verifyOverview(paused, token: token)
    capture("IPAD-E04-A01-paused-audio-background-clock-stopped")
    accessibilityAudit.collect(
      app, screen: "IPAD-E04-A01-paused-audio-background-clock-stopped", testCase: self)
    app.buttons["audiobookDone"].tap()
    showHistory(book, app: app)
    capture("IPAD-E04-A01-actual-listening-history")
    finish(app)
  }

  @MainActor
  func testIPADE04A01EPUBSpeechSuppressesOrdinaryReadingTime() async throws {
    try await narrationJourney(type: "tts", username: "ipad-e04-activity-tts")
  }

  @MainActor
  func testIPADE04A01RecordedNarrationSuppressesOrdinaryReadingTime() async throws {
    try await narrationJourney(type: "listen", username: "ipad-e04-activity-recorded")
  }

  @MainActor
  func testIPADE04A01OfflineReadingRetainsHistoricalAttemptAfterRestart() async throws {
    try await fault("online")
    let username = "ipad-e04-activity-offline"
    let token = try await login(username)
    let book = try await bookDetails(id: 1, format: "pdf", token: token)
    try await requireEmpty(book, token: token)
    _ = try await request(
      "books/1/status", method: "PATCH", token: token, body: ["status": "reading"])
    let originalAttempt = try await attempt(book, token: token)
    let app = launchAndSignIn(username)
    openBook(book, app: app)
    download(book, app: app)
    let firstStart = Date()
    openFile(book, app: app)
    XCTAssertTrue(app.staticTexts["Page 1 of 3"].waitForExistence(timeout: 20))
    let first = try await waitForSessions(book, token: token) { $0.seconds("read") >= 10 }
    XCTAssertEqual(first.rows.count, 1)
    XCTAssertEqual(first.rows[0].attemptID, originalAttempt)
    let beforeBackground = Date()
    XCUIDevice.shared.press(.home)
    try await observe(seconds: 8)
    app.activate()
    app.buttons["pdfCloseReader"].tap()
    try await settle(app)
    let background = try await sessions(book, token: token)
    XCTAssertLessThanOrEqual(
      background.seconds, Int(beforeBackground.timeIntervalSince(firstStart)) + 4,
      "Ordinary text reading must exclude the eight seconds spent in the background")
    capture("IPAD-E04-A01-background-text-reading-clock-stopped")
    openFile(book, app: app)
    XCTAssertTrue(app.staticTexts["Page 1 of 3"].waitForExistence(timeout: 20))
    let beforeOffline = try await waitForSessions(book, token: token) {
      $0.rows.count == 2 && $0.rows.allSatisfy { $0.seconds >= 10 }
    }
    XCTAssertEqual(Set(beforeOffline.rows.compactMap(\.attemptID)), [originalAttempt])
    try await fault("offline")
    let offlineStart = Date()
    app.buttons["pdfNextPage"].tap()
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 10))
    try await observe(seconds: 16)
    XCTAssertTrue(app.staticTexts["readingActivitySyncFeedback"].exists)
    capture("IPAD-E04-A01-offline-actual-reading-queued")
    XCUIDevice.shared.press(.home)
    app.terminate()
    let offlineElapsed = Int(Date().timeIntervalSince(offlineStart))
    let newAttempt = try await replaceAttempt(book, token: token)
    XCTAssertNotEqual(newAttempt, originalAttempt)
    app.launch()
    openOfflineBook(book, app: app)
    capture("IPAD-E04-A01-offline-reading-relaunch-before-reconnect")
    try await fault("online")
    try await settle(app)
    let recovered = try await waitForSessions(book, token: token) {
      $0.rows.count == 2 && $0.seconds >= beforeOffline.seconds + 10
    }
    XCTAssertEqual(Set(recovered.rows.compactMap(\.attemptID)), [originalAttempt])
    XCTAssertTrue(recovered.rows.allSatisfy { $0.source == "ios" && $0.type == "read" })
    XCTAssertEqual(Set(recovered.rows.map(\.id)), Set(beforeOffline.rows.map(\.id)))
    XCTAssertGreaterThanOrEqual(recovered.seconds - beforeOffline.seconds, 10)
    XCTAssertLessThanOrEqual(recovered.seconds - beforeOffline.seconds, offlineElapsed + 7)
    let ids = Set(recovered.rows.map(\.id))
    try await settle(app)
    try await observe(seconds: 6)
    let retried = try await sessions(book, token: token)
    XCTAssertEqual(Set(retried.rows.map(\.id)), ids)
    XCTAssertEqual(retried.seconds, recovered.seconds)
    try await verifyOverview(retried, token: token)
    showHistory(book, app: app)
    capture("IPAD-E04-A01-recovered-historical-attempt-session-once")
    accessibilityAudit.collect(
      app, screen: "IPAD-E04-A01-recovered-historical-attempt-session-once", testCase: self)
    finish(app)
  }

  @MainActor
  func testIPADE04A01OfflineUnknownAttemptAndAccountSwitchRemainIsolated() async throws {
    try await fault("online")
    let username = "ipad-e04-activity-unknown"
    let token = try await login(username)
    let book = try await bookDetails(id: 1, format: "pdf", token: token)
    try await requireEmpty(book, token: token)
    _ = try await request(
      "books/1/status", method: "PATCH", token: token, body: ["status": "reading"])
    let oldAttempt = try await attempt(book, token: token)
    let app = launchAndSignIn(username)
    openBook(book, app: app)
    download(book, app: app)
    try await fault("offline")
    let started = Date()
    openFile(book, app: app)
    XCTAssertTrue(app.staticTexts["Page 1 of 3"].waitForExistence(timeout: 20))
    app.buttons["pdfNextPage"].tap()
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 10))
    try await observe(seconds: 16)
    XCTAssertTrue(app.staticTexts["readingActivitySyncFeedback"].exists)
    capture("IPAD-E04-A01-offline-unknown-attempt-actual-reading")
    XCUIDevice.shared.press(.home)
    app.terminate()
    let elapsed = Int(Date().timeIntervalSince(started))
    let latestAttempt = try await replaceAttempt(book, token: token)
    XCTAssertNotEqual(latestAttempt, oldAttempt)
    app.launch()
    XCTAssertTrue(app.buttons["offlineLibrary"].waitForExistence(timeout: 25))
    capture("IPAD-E04-A01-unknown-attempt-outbox-survives-restart")
    app.buttons["signOut"].tap()
    XCTAssertTrue(app.textFields["serverURL"].waitForExistence(timeout: 15))
    try await fault("online")
    let other = "ipad-e04-activity-listen"
    let otherToken = try await login(other)
    signIn(other, app: app)
    let otherSessions = try await sessions(book, token: otherToken)
    XCTAssertTrue(otherSessions.rows.isEmpty)
    openBook(book, app: app)
    showHistory(book, app: app)
    XCTAssertEqual(historyCount(app), "0")
    capture("IPAD-E04-A01-other-account-receives-no-pending-reading")
    accessibilityAudit.collect(
      app, screen: "IPAD-E04-A01-other-account-receives-no-pending-reading", testCase: self)
    finish(app)
    signIn(username, app: app)
    let restored = try await waitForSessions(book, token: token) { $0.rows.count == 1 }
    XCTAssertNil(
      restored.rows[0].attemptID, "Unavailable capture must remain explicitly unassigned")
    XCTAssertEqual(restored.rows[0].type, "read")
    XCTAssertEqual(restored.rows[0].source, "ios")
    XCTAssertGreaterThanOrEqual(restored.seconds, 10)
    XCTAssertLessThanOrEqual(restored.seconds, elapsed + 2)
    try await settle(app)
    app.terminate()
    app.launch()
    XCTAssertTrue(app.buttons["readingStatistics"].waitForExistence(timeout: 20))
    try await settle(app)
    let again = try await sessions(book, token: token)
    XCTAssertEqual(again.rows.map(\.id), restored.rows.map(\.id))
    XCTAssertEqual(again.seconds, restored.seconds)
    let otherAfterRestart = try await sessions(book, token: otherToken)
    XCTAssertTrue(otherAfterRestart.rows.isEmpty)
    try await verifyOverview(again, token: token)
    openBook(book, app: app)
    showHistory(book, app: app)
    capture("IPAD-E04-A01-unassigned-session-reconciled-once-in-original-account")
    finish(app)
  }

  @MainActor
  private func narrationJourney(type: String, username: String) async throws {
    try await fault("online")
    let token = try await login(username)
    let book = try await mediaBook(title: "E04 activity narration", format: "epub", token: token)
    try await requireEmpty(book, token: token)
    let app = launchAndSignIn(username)
    openBook(book, app: app)
    let started = Date()
    openFile(book, app: app)
    XCTAssertTrue(app.buttons["epubReaderTools"].wait(for: \.isEnabled, toEqual: true, timeout: 25))
    _ = try await waitForSessions(book, token: token) { $0.seconds("read") >= 10 }
    if type == "tts" {
      app.buttons["epubTextToSpeech"].tap()
      let toggle = app.buttons["nativeTTSToggle"]
      XCTAssertTrue(toggle.wait(for: \.isEnabled, toEqual: true, timeout: 20))
      toggle.tap()
      XCTAssertTrue(
        app.staticTexts["nativeTTSState"].wait(for: \.label, toEqual: "Speaking", timeout: 20))
      capture("IPAD-E04-A01-real-system-speech-controls")
      app.buttons["nativeTTSCloseControls"].tap()
      XCTAssertTrue(app.buttons["epubSpeechToggle"].waitForExistence(timeout: 10))
    } else {
      app.buttons["epubReaderTools"].tap()
      app.buttons["epubRecordedReadAlong"].tap()
      let start = app.buttons["recordedStartPassage"]
      XCTAssertTrue(start.wait(for: \.isEnabled, toEqual: true, timeout: 25))
      start.tap()
      XCTAssertTrue(
        app.buttons["recordedToggle"].wait(for: \.label, toEqual: "Pause recording", timeout: 20))
      capture("IPAD-E04-A01-real-publisher-narration-controls")
      app.buttons["recordedCloseControls"].tap()
      XCTAssertTrue(app.buttons["epubRecordedToggle"].waitForExistence(timeout: 10))
    }
    let first = try await waitForSessions(book, token: token) { $0.seconds(type) >= 10 }
    capture("IPAD-E04-A01-EPUB-visible-during-\(type)")
    try await observe(seconds: 6)
    let later = try await waitForSessions(book, token: token) {
      $0.seconds(type) >= first.seconds(type) + 3
    }
    XCTAssertEqual(
      later.seconds("read"), first.seconds("read"),
      "Visible EPUB must not also count ordinary reading during narration")
    XCTAssertEqual(Set(later.rows.map(\.type)), ["read", type])
    XCTAssertTrue(later.rows.allSatisfy { $0.source == "ios" })
    if type == "tts" {
      let positionBefore = try await request("tts/position/\(book.fileID)", token: token)
      XCUIDevice.shared.press(.home)
      try await observe(seconds: 6)
      app.activate()
      XCTAssertTrue(
        app.buttons["epubSpeechToggle"].wait(for: \.label, toEqual: "Pause speech", timeout: 10))
      let background = try await waitForSessions(book, token: token) {
        $0.seconds("tts") >= later.seconds("tts") + 4
      }
      XCTAssertEqual(background.seconds("read"), later.seconds("read"))
      app.buttons["epubSpeechControls"].tap()
      XCTAssertTrue(
        app.staticTexts["nativeTTSState"].wait(for: \.label, toEqual: "Speaking", timeout: 10))
      app.buttons["nativeTTSToggle"].tap()
      XCTAssertTrue(
        app.staticTexts["nativeTTSState"].wait(for: \.label, toEqual: "Paused", timeout: 10))
      let positionAfter = try await request("tts/position/\(book.fileID)", token: token)
      let beforeCFI = (positionBefore as? [String: Any])?["cfi"] as? String
      let afterCFI = try XCTUnwrap((positionAfter as? [String: Any])?["cfi"] as? String)
      XCTAssertNotEqual(
        afterCFI, beforeCFI, "Real speech position must advance across active background playback")
      capture("IPAD-E04-A01-background-system-speech-position-continued")
      app.buttons["nativeTTSCloseControls"].tap()
    }
    let toggle = app.buttons[type == "tts" ? "epubSpeechToggle" : "epubRecordedToggle"]
    XCTAssertTrue(toggle.isHittable)
    if type != "tts" { toggle.tap() }
    try await settle(app)
    let paused = try await sessions(book, token: token)
    try await observe(seconds: 6)
    let afterPause = try await sessions(book, token: token)
    XCTAssertEqual(afterPause.seconds, paused.seconds)
    XCTAssertLessThanOrEqual(paused.seconds, Int(Date().timeIntervalSince(started)) + 2)
    try await verifyOverview(paused, token: token)
    capture("IPAD-E04-A01-\(type)-paused-without-double-counted-text")
    accessibilityAudit.collect(
      app, screen: "IPAD-E04-A01-\(type)-paused-without-double-counted-text", testCase: self)
    if type == "tts" {
      app.buttons["epubStopSpeech"].tap()
    } else {
      app.buttons["epubRecordedControls"].tap()
      reveal(app.buttons["recordedStop"], app: app)
      app.buttons["recordedStop"].tap()
      app.buttons["recordedCloseControls"].tap()
    }
    app.buttons["epubCloseReader"].tap()
    showHistory(book, app: app)
    capture("IPAD-E04-A01-\(type)-and-reading-source-history")
    finish(app)
  }

  @MainActor
  private func environment(_ key: String, fallback: String) -> String {
    ProcessInfo.processInfo.environment[key] ?? ProcessInfo.processInfo.environment[
      "TEST_RUNNER_\(key)"] ?? fallback
  }

  @MainActor
  private func request(
    _ path: String, method: String = "GET", token: String? = nil, body: [String: Any]? = nil
  ) async throws -> Any {
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
    let status = try XCTUnwrap(response as? HTTPURLResponse).statusCode
    XCTAssertTrue((200..<300).contains(status), "\(method) \(path): HTTP\(status)")
    XCTAssertLessThanOrEqual(data.count, 512 * 1024)
    return data.isEmpty ? [:] : try JSONSerialization.jsonObject(with: data)
  }

  @MainActor
  private func login(_ username: String) async throws -> String {
    let response = try await request(
      "auth/login", method: "POST",
      body: [
        "username": username, "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "E04 actual activity public assertions",
      ])
    return try XCTUnwrap((response as? [String: Any])?["accessToken"] as? String)
  }

  @MainActor
  private func bookDetails(id: Int, format: String, token: String) async throws -> Book {
    let response = try await request("books/\(id)", token: token)
    let detail = try XCTUnwrap(response as? [String: Any])
    let files = try XCTUnwrap(detail["files"] as? [[String: Any]])
    let file = try XCTUnwrap(files.first { $0["format"] as? String == format })
    return Book(
      id: id, fileID: try XCTUnwrap(file["id"] as? Int),
      title: try XCTUnwrap(detail["title"] as? String))
  }

  @MainActor
  private func mediaBook(title: String, format: String, token: String) async throws -> Book {
    let q = try XCTUnwrap(title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed))
    let response = try await request("books/search?q=\(q)&limit=10", token: token)
    let matches = try XCTUnwrap(response as? [[String: Any]])
    XCTAssertLessThanOrEqual(matches.count, 10)
    let row = try XCTUnwrap(
      matches.first { $0["title"] as? String == title },
      "Required real long-media fixture: \(title)")
    return try await bookDetails(id: try XCTUnwrap(row["id"] as? Int), format: format, token: token)
  }

  @MainActor
  private func sessions(_ book: Book, token: String) async throws -> Sessions {
    let response = try await request("books/\(book.id)/sessions?page=1&pageSize=40", token: token)
    let result = try XCTUnwrap(response as? [String: Any])
    let items = try XCTUnwrap(result["items"] as? [[String: Any]])
    XCTAssertLessThanOrEqual(items.count, 40)
    XCTAssertEqual(items.count, result["total"] as? Int)
    let rows = try items.map { row in
      Row(
        id: try XCTUnwrap(row["id"] as? Int),
        seconds: try XCTUnwrap(row["durationSeconds"] as? Int),
        type: try XCTUnwrap(row["sessionType"] as? String),
        source: try XCTUnwrap(row["source"] as? String),
        attemptID: row["attemptId"] as? Int)
    }
    let value = Sessions(rows: rows)
    let stats = try XCTUnwrap(result["stats"] as? [String: Any])
    XCTAssertEqual(stats["totalSessions"] as? Int, rows.count)
    XCTAssertEqual(stats["totalSeconds"] as? Int, value.seconds)
    XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    return value
  }

  @MainActor
  private func requireEmpty(_ book: Book, token: String) async throws {
    let value = try await sessions(book, token: token)
    XCTAssertTrue(
      value.rows.isEmpty, "Run against fresh dedicated fixture accounts, never shared A01 accounts")
  }

  @MainActor
  private func waitForSessions(_ book: Book, token: String, matching: (Sessions) -> Bool)
    async throws -> Sessions
  {
    let deadline = Date().addingTimeInterval(45)
    var value = try await sessions(book, token: token)
    while !matching(value), Date() < deadline {
      try await observe(seconds: 2)
      value = try await sessions(book, token: token)
    }
    XCTAssertTrue(
      matching(value),
      "Actual native activity did not reach the public session expectation in 45 seconds")
    return value
  }

  @MainActor
  private func verifyOverview(_ sessions: Sessions, token: String) async throws {
    let response = try await request("user-statistics/activity-overview", token: token)
    let overview = try XCTUnwrap(response as? [String: Any])
    let snapshot = try XCTUnwrap(overview["snapshot"] as? [String: Any])
    let seven = try XCTUnwrap(snapshot["lastSevenDays"] as? [String: Any])
    XCTAssertEqual(seven["totalSeconds"] as? Int, sessions.seconds)
    XCTAssertEqual(seven["readingSeconds"] as? Int, sessions.seconds("read"))
    XCTAssertEqual(
      seven["listeningSeconds"] as? Int, sessions.seconds("listen") + sessions.seconds("tts"))
    let daily = try XCTUnwrap(
      (overview["dailyActivity"] as? [String: Any])?["days"] as? [[String: Any]])
    XCTAssertLessThanOrEqual(daily.count, 84)
    XCTAssertEqual(
      daily.reduce(0) { $0 + ($1["sessionsCount"] as? Int ?? 0) }, sessions.rows.count,
      "Cumulative checkpoints and retries must not multiply daily session counts")
    let slices = try XCTUnwrap(
      (overview["sources"] as? [String: Any])?["slices"] as? [[String: Any]])
    XCTAssertEqual(
      slices.first { $0["bucket"] as? String == "ios" }?["totalSeconds"] as? Int, sessions.seconds)
    let attachment = XCTAttachment(
      data: try JSONSerialization.data(
        withJSONObject: overview, options: [.prettyPrinted, .sortedKeys]),
      uniformTypeIdentifier: "public.json")
    attachment.name = "IPAD-E04-A01-real-activity-worked-example"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor
  private func attempt(_ book: Book, token: String) async throws -> Int {
    let response = try await request("books/files/\(book.fileID)/session-context", token: token)
    let context = try XCTUnwrap(response as? [String: Any])
    XCTAssertEqual(context["bookId"] as? Int, book.id)
    return try XCTUnwrap(context["attemptId"] as? Int)
  }

  @MainActor
  private func replaceAttempt(_ book: Book, token: String) async throws -> Int {
    _ = try await request(
      "books/\(book.id)/status", method: "PATCH", token: token, body: ["status": "read"])
    _ = try await request(
      "books/\(book.id)/reading-attempts/start-reread", method: "POST", token: token,
      body: ["resetProgress": false])
    return try await attempt(book, token: token)
  }

  @MainActor
  private func fault(_ state: String) async throws {
    let base = environment("IPAD_E04_FAULT_URL", fallback: "http://127.0.0.1:16505")
    var request = URLRequest(
      url: try XCTUnwrap(URL(string: "\(base)/__faults/annotations/\(state)")))
    request.httpMethod = "POST"
    request.timeoutInterval = 10
    let (_, response) = try await E04FixtureHTTP.data(for: request)
    XCTAssertTrue((200..<300).contains(try XCTUnwrap(response as? HTTPURLResponse).statusCode))
  }

  @MainActor
  private func observe(seconds: Int) async throws {
    XCTAssertTrue((1...20).contains(seconds))
    for _ in 0..<seconds / 2 { try await Task.sleep(for: .seconds(2)) }
    if seconds % 2 != 0 { try await Task.sleep(for: .seconds(1)) }
  }

  @MainActor
  private func settle(_ app: XCUIApplication) async throws {
    XCUIDevice.shared.press(.home)
    app.activate()
    try await observe(seconds: 2)
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
      let close = [
        "nativeTTSCloseControls", "recordedCloseControls", "epubCloseReader", "pdfCloseReader",
        "audiobookDone", "readingHistoryClose", "Done",
      ].first { app.buttons[$0].exists }
      guard let close else { break }
      app.buttons[close].firstMatch.tap()
    }
    if app.buttons["signOut"].exists { app.buttons["signOut"].tap() }
    if app.buttons["Change server"].exists { app.buttons["Change server"].tap() }
    let server = app.textFields["serverURL"]
    XCTAssertTrue(server.waitForExistence(timeout: 15))
    replace(server, value: environment("IPAD_E04_FAULT_URL", fallback: "http://127.0.0.1:16505"))
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
    let user = app.textFields["username"]
    XCTAssertTrue(user.waitForExistence(timeout: 15))
    replace(user, value: username)
    replace(app.secureTextFields["password"], value: "IpadFixture123")
    app.buttons["signIn"].tap()
    XCTAssertTrue(app.buttons["readingStatistics"].waitForExistence(timeout: 25))
  }

  @MainActor
  private func openBook(_ book: Book, app: XCUIApplication) {
    if app.buttons["All books"].exists { app.buttons["All books"].tap() }
    XCTAssertTrue(app.buttons["Table"].waitForExistence(timeout: 10))
    app.buttons["Table"].tap()
    let search = app.textViews["librarySearch"]
    XCTAssertTrue(search.waitForExistence(timeout: 10))
    replace(search, value: "\(book.title)\n")
    let actions = app.buttons["tableOpen\(book.id)_title"]
    XCTAssertTrue(actions.wait(for: \.isHittable, toEqual: true, timeout: 20))
    actions.tap()
    XCTAssertTrue(app.buttons["Book details"].waitForExistence(timeout: 10))
    app.buttons["Book details"].tap()
    XCTAssertTrue(app.navigationBars["Book details"].waitForExistence(timeout: 10))
  }

  @MainActor
  private func openFile(_ book: Book, app: XCUIApplication) {
    let read = app.buttons["readFile\(book.fileID)"]
    reveal(read, app: app)
    XCTAssertTrue(read.wait(for: \.isEnabled, toEqual: true, timeout: 15))
    read.tap()
  }

  @MainActor
  private func download(_ book: Book, app: XCUIApplication) {
    let resources = app.buttons["offlineResources"]
    reveal(resources, app: app)
    resources.tap()
    let selected = app.buttons["offlineSelectFile\(book.fileID)"]
    XCTAssertTrue(selected.waitForExistence(timeout: 10))
    if selected.value as? String != "Selected" { selected.tap() }
    let download = app.buttons["offlineDownload"]
    XCTAssertTrue(download.wait(for: \.isEnabled, toEqual: true, timeout: 10))
    download.tap()
    XCTAssertTrue(
      app.staticTexts["Verified ready for offline reading"].waitForExistence(timeout: 45))
    app.buttons["Done"].firstMatch.tap()
  }

  @MainActor
  private func openOfflineBook(_ book: Book, app: XCUIApplication) {
    let offline = app.buttons["offlineLibrary"]
    XCTAssertTrue(offline.wait(for: \.isHittable, toEqual: true, timeout: 25))
    offline.tap()
    let row = app.buttons["offlineBook\(book.id)"]
    XCTAssertTrue(row.wait(for: \.isHittable, toEqual: true, timeout: 10))
    row.tap()
    XCTAssertTrue(app.navigationBars["Book details"].waitForExistence(timeout: 10))
  }

  @MainActor
  private func showHistory(_ book: Book, app: XCUIApplication) {
    let history = app.buttons["openBookReadingHistory"]
    reveal(history, app: app)
    history.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["readingHistorySessionCount"].waitForExistence(timeout: 20))
  }

  @MainActor
  private func historyCount(_ app: XCUIApplication) -> String? {
    let count = app.descendants(matching: .any)["readingHistorySessionCount"]
    return count.value as? String ?? count.staticTexts.allElementsBoundByIndex.last?.label
  }

  @MainActor
  private func finish(_ app: XCUIApplication) {
    if app.buttons["readingHistoryClose"].exists { app.buttons["readingHistoryClose"].tap() }
    if app.navigationBars["Book details"].buttons["Done"].exists {
      app.navigationBars["Book details"].buttons["Done"].tap()
    }
    XCTAssertTrue(app.buttons["signOut"].waitForExistence(timeout: 10))
    app.buttons["signOut"].tap()
    XCTAssertTrue(app.textFields["serverURL"].waitForExistence(timeout: 15))
  }

  @MainActor
  private func playbackSeconds(_ app: XCUIApplication, total: Bool = false) throws -> Int {
    let text = app.staticTexts["audiobookPlaybackTime"].label
    let sides = text.components(separatedBy: " / ")
    let index = total ? 1 : 0
    XCTAssertGreaterThan(sides.count, index)
    let components = try sides[index].split(separator: ":").map { try XCTUnwrap(Int($0)) }
    return components.reduce(0) { $0 * 60 + $1 }
  }

  @MainActor
  private func replace(_ element: XCUIElement, value: String) {
    XCTAssertTrue(element.wait(for: \.isHittable, toEqual: true, timeout: 10))
    element.tap()
    let previous = element.value as? String ?? ""
    if previous != element.placeholderValue {
      element.typeText(
        String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.utf16.count))
    }
    element.typeText(value)
  }

  @MainActor
  private func reveal(_ element: XCUIElement, app: XCUIApplication) {
    for _ in 0..<12 {
      if element.exists && element.isHittable { return }
      app.swipeUp()
    }
    XCTAssertTrue(element.exists && element.isHittable)
  }

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
