import Foundation
import XCTest

final class ReadingPrivacyJourneyTests: XCTestCase {
  private var accessibilityFindings: [[String: Any]] = []
  private var auditedScreens: [String] = []
  private var functionalAssertionsCompleted = false

  private var base: String {
    environment("IPAD_E04_API_URL", fallback: "http://127.0.0.1:16502/api/v1")
  }
  private var server: String {
    environment("IPAD_E04_NATIVE_SERVER_URL", fallback: "http://127.0.0.1:16502")
  }
  private var faultServer: String {
    environment("IPAD_E04_FAULT_URL", fallback: "http://127.0.0.1:16505")
  }

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    accessibilityFindings = []
    auditedScreens = []
    functionalAssertionsCompleted = false
  }

  @MainActor
  func testIPADE04A02PrivacyRestrictionsAndSharedInsightHandoff() async throws {
    try await runHandoffJourney(includePrivateSave: true)
  }

  @MainActor
  func testIPADE04A02FirstTimePreviewRestrictionsAndSharedInsightHandoff() async throws {
    try await runHandoffJourney(includePrivateSave: false)
  }

  @MainActor
  func testIPADE04A02FirstTimeSharedInsightRemainderAndHandoff() async throws {
    try await runHandoffJourney(includePrivateSave: false, resumeAfterPrivatePreview: true)
  }

  @MainActor
  func testIPADE04A02RetainedSummaryPreviewAndRemainingHandoff() async throws {
    try await runHandoffJourney(includePrivateSave: false, resumeAfterSummarySave: true)
  }

  @MainActor
  func testIPADE04A02RetainedSummarySessionsDiagnostic() async throws {
    defer { reportAccessibilityResult() }
    let owner = try await login("ipad-owner")
    let token = try XCTUnwrap(owner["accessToken"] as? String)
    let refreshToken = try XCTUnwrap(owner["refreshToken"] as? String)
    XCTAssertEqual((owner["user"] as? [String: Any])?["id"] as? Int, 1)
    try registerLogout(refreshToken)
    let settings = try await object(
      "reading-insights-sharing/me", token: token, expectedStatus: 200)
    XCTAssertEqual(settings["sharingLevel"] as? String, "summary")
    XCTAssertEqual(settings["consentedAt"] as? String, "2026-10-11T12:27:30.540Z")
    let book = try await object("books/1", token: token, expectedStatus: 200)
    XCTAssertEqual(
      book["personalNote"] as? String,
      "E04 private personal note 71AE1F30-9479-4530-A69C-8574462DFB75")
    let annotations = try await object(
      "books/1/annotations?page=1&pageSize=1&sortBy=createdAt&sortDir=desc&search=E04%20private%20highlight",
      token: token, expectedStatus: 200)
    let annotation = try XCTUnwrap((annotations["items"] as? [[String: Any]])?.first)
    XCTAssertEqual(annotation["id"] as? Int, 241)
    XCTAssertEqual(
      annotation["text"] as? String,
      "E04 private highlight AC9A337B-29F1-4B1C-B8A9-DE4711DE0C17")
    let preview = try await object(
      "reading-insights-sharing/me/preview?days=30", token: token, expectedStatus: 200)
    XCTAssertEqual(preview["sharingLevel"] as? String, "summary")
    let sessionsCount = try XCTUnwrap(preview["sessionsCount"] as? Double)
    let expectedLabel = "Sessions, \(sessionsCount)"
    attach(
      ["ownerUserId": 1, "settings": settings, "annotationId": 241, "preview": preview],
      name: "P-N01-summary-sessions-diagnostic-public-baseline")

    let app = launchPrivacy(username: "ipad-owner")
    assertSelectedLevel("Summary", app: app)
    app.buttons["readingPrivacyPreview"].tap()
    XCTAssertTrue(
      app.collectionViews["readingPrivacyContent"].descendants(matching: .any)[
        "readingInsightSharingLevel"
      ].waitForExistence(timeout: 10))
    var foundVisibleSessions = false
    for step in 0...1 {
      let form = app.collectionViews["readingPrivacyContent"]
      let matches = form.descendants(matching: .any).matching(
        NSPredicate(
          format: "identifier == %@ OR label BEGINSWITH %@",
          "readingInsightSessionCount", "Sessions")
      ).allElementsBoundByIndex
      let candidates = matches.map { element -> [String: Any] in
        [
          "elementType": element.elementType.rawValue, "identifier": element.identifier,
          "label": element.label, "value": String(describing: element.value ?? NSNull()),
          "frame": String(describing: element.frame), "hittable": element.isHittable,
        ]
      }
      attach(
        ["step": step, "formFrame": String(describing: form.frame), "candidates": candidates],
        name: "P-N01-summary-sessions-diagnostic-candidates-\(step)")
      let hierarchy = XCTAttachment(string: app.debugDescription)
      hierarchy.name = "P-N01-summary-sessions-diagnostic-hierarchy-\(step)"
      hierarchy.lifetime = .keepAlways
      add(hierarchy)
      capture("P-N01-summary-sessions-diagnostic-screen-\(step)", app: app)
      if let row = matches.first(where: {
        ($0.identifier == "readingInsightSessionCount" || $0.label.hasPrefix("Sessions,"))
          && $0.isHittable && form.frame.contains($0.frame)
      }) {
        XCTAssertEqual(row.label, expectedLabel)
        foundVisibleSessions = true
        break
      }
      if step == 0 { form.swipeUp() }
    }
    XCTAssertTrue(foundVisibleSessions, "Sessions must be visible after at most one Form swipe.")
    let unchanged = try await object(
      "reading-insights-sharing/me", token: token, expectedStatus: 200)
    XCTAssertEqual(try json(unchanged), try json(settings))
    attach(unchanged, name: "P-N01-summary-sessions-diagnostic-canonical-unchanged")
    collectAccessibilityAudit(app, screen: "retained-summary-sessions-diagnostic")
    functionalAssertionsCompleted = true
  }

  @MainActor
  func testIPADE04A02RetainedPrivacyToolbarAccessibilityAndDismissal() throws {
    let app = launchPrivacy(username: "ipad-owner")
    E02ProfileSupport.assertSystemProfile(app: app)
    let done = app.buttons["readingPrivacyDone"]
    XCTAssertTrue(done.wait(for: \.isHittable, toEqual: true, timeout: 10))
    XCTAssertTrue(done.isEnabled)
    XCTAssertEqual(done.label, "Done")
    XCTAssertTrue(app.frame.contains(done.frame))
    capture("P-N01-retained-privacy-toolbar-\(E02ProfileSupport.name)", app: app)
    try app.performAccessibilityAudit()
    done.tap()
    XCTAssertTrue(done.wait(for: \.exists, toEqual: false, timeout: 10))
    XCTAssertTrue(app.collectionViews["librarySidebar"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["signOut"].isHittable)
    capture("P-N01-retained-privacy-dismissed-\(E02ProfileSupport.name)", app: app)
  }

  @MainActor
  func testIPADE04A02PrivateSaveVisibleOutcome() async throws {
    defer { reportAccessibilityResult() }
    try await withDisposableSubject { username, token in
      let app = self.launchPrivacy(username: username)
      self.selectLevel("Private", app: app)
      self.tapSaveSharingSetting(app)
      self.assertVisibleSaveOutcome(app, privateSharing: true)
      self.capture("P-N01-private-save-visible-outcome", app: app)
      self.collectAccessibilityAudit(app, screen: "private-save-visible-outcome")
      try await self.assertPrivateSettings(token: token)
    }
    functionalAssertionsCompleted = true
  }

  @MainActor
  func testIPADE04A02PrivateSaveCanonicalState() async throws {
    try await withDisposableSubject { username, token in
      let initial = try await self.object(
        "reading-insights-sharing/me", token: token, method: "PATCH",
        body: ["sharingLevel": "detailed"], expectedStatus: 200)
      XCTAssertEqual(initial["sharingLevel"] as? String, "detailed")
      XCTAssertNotNil(initial["consentedAt"] as? String)
      self.attach(initial, name: "P-N01-canonical-initial-detailed")
      let app = self.launchPrivacy(username: username)
      self.assertSelectedLevel("Detailed", app: app)
      self.selectLevel("Private", app: app)
      self.tapSaveSharingSetting(app)
      self.assertVisibleSaveOutcome(app, privateSharing: true)
      try await self.assertPrivateSettings(token: token)
      app.buttons["readingPrivacyDone"].tap()
      self.openPrivacy(app)
      self.assertSelectedLevel("Private", app: app)
      self.capture("P-N01-private-canonical-after-native-save-and-reopen", app: app)
    }
  }

  @MainActor
  func testIPADE04A02PrivateSaveVisibleFailureRecovery() async throws {
    defer { reportAccessibilityResult() }
    try await withDisposableSubject { username, token in
      let initial = try await self.object(
        "reading-insights-sharing/me", token: token, method: "PATCH",
        body: ["sharingLevel": "detailed"], expectedStatus: 200)
      XCTAssertEqual(initial["sharingLevel"] as? String, "detailed")
      XCTAssertNotNil(initial["consentedAt"] as? String)
      try await self.resetPrivacyFault()
      let app = self.launchPrivacy(username: username, serverURL: self.faultServer)
      self.assertSelectedLevel("Detailed", app: app)
      self.selectLevel("Private", app: app)
      _ = try await self.privacyFault("fail-next-patch", method: "POST", expectedStatus: 204)
      self.tapSaveSharingSetting(app)
      let error = app.staticTexts["readingPrivacyError"]
      XCTAssertTrue(error.wait(for: \.isHittable, toEqual: true, timeout: 15))
      XCTAssertTrue(error.label.contains("Could not confirm your sharing setting."))
      self.assertVisibleBesideSave(error, app: app)
      XCTAssertFalse(app.staticTexts["readingPrivacySaved"].exists)
      self.assertSelectedLevel("Private", app: app)
      let retry = app.buttons["readingPrivacyRetry"]
      XCTAssertTrue(retry.isHittable)
      XCTAssertEqual(retry.label, "Retry saving sharing setting")
      let failed = try await self.privacyFault("state", method: "GET", expectedStatus: 200)
      XCTAssertEqual(failed["armed"] as? Bool, false)
      XCTAssertEqual(failed["failed"] as? Int, 1)
      let stored = try await self.object(
        "reading-insights-sharing/me", token: token, expectedStatus: 200)
      XCTAssertEqual(try self.json(stored), try self.json(initial))
      self.attach(stored, name: "P-N01-canonical-state-unchanged-after-failed-native-save")
      self.capture("P-N01-private-save-visible-failure-preserves-selection", app: app)
      self.collectAccessibilityAudit(app, screen: "private-save-visible-failure")
      retry.tap()
      self.assertVisibleSaveOutcome(app, privateSharing: true)
      self.assertSelectedLevel("Private", app: app)
      try await self.assertPrivateSettings(token: token)
      let recovered = try await self.privacyFault("state", method: "GET", expectedStatus: 200)
      XCTAssertEqual(recovered["armed"] as? Bool, false)
      XCTAssertEqual(recovered["failed"] as? Int, 1)
      self.capture("P-N01-private-save-recovered-with-one-native-retry", app: app)
    }
    functionalAssertionsCompleted = true
  }

  @MainActor
  func testIPADE04A02RetainedSharingFailureRetry() async throws {
    defer { reportAccessibilityResult() }
    let owner = try await login("ipad-owner")
    let token = try XCTUnwrap(owner["accessToken"] as? String)
    let refreshToken = try XCTUnwrap(owner["refreshToken"] as? String)
    let initial = try await object("reading-insights-sharing/me", token: token, expectedStatus: 200)
    XCTAssertEqual(initial["sharingLevel"] as? String, "private")
    XCTAssertTrue(initial["consentedAt"] is NSNull)
    attach(initial, name: "P-N01-retained-retry-initial-canonical-private")
    let original = try json(initial)
    let restore = try cleanupRequest(
      "reading-insights-sharing/me", token: token, method: "PATCH",
      body: ["sharingLevel": "private"])
    let observe = try cleanupRequest("reading-insights-sharing/me", token: token)
    try registerLogout(refreshToken)
    addTeardownBlock {
      let restored = try await ReadingPrivacyJourneyTests.cleanupData(
        restore, name: "P-N01-retained-retry-cleanup-restored")
      guard try ReadingPrivacyJourneyTests.canonicalJSON(restored) == original else {
        throw CleanupError.canonicalStateMismatch
      }
      let observed = try await ReadingPrivacyJourneyTests.cleanupData(
        observe, name: "P-N01-retained-retry-cleanup-restored-original-private")
      guard try ReadingPrivacyJourneyTests.canonicalJSON(observed) == original else {
        throw CleanupError.canonicalStateMismatch
      }
    }
    try await resetPrivacyFault()
    let app = launchPrivacy(username: "ipad-owner", serverURL: faultServer)
    assertSelectedLevel("Private", app: app)
    selectLevel("Summary", app: app)
    _ = try await privacyFault("fail-next-patch", method: "POST", expectedStatus: 204)
    tapSaveSharingSetting(app)
    let error = app.staticTexts["readingPrivacyError"]
    XCTAssertTrue(error.wait(for: \.isHittable, toEqual: true, timeout: 15))
    XCTAssertTrue(error.label.contains("Could not confirm your sharing setting."))
    assertVisibleBesideSave(error, app: app)
    XCTAssertFalse(app.staticTexts["readingPrivacySaved"].exists)
    assertSelectedLevel("Summary", app: app)
    let retry = app.buttons["readingPrivacyRetry"]
    XCTAssertTrue(retry.isHittable)
    XCTAssertEqual(retry.label, "Retry saving sharing setting")
    let failed = try await privacyFault("state", method: "GET", expectedStatus: 200)
    XCTAssertEqual(failed["armed"] as? Bool, false)
    XCTAssertEqual(failed["failed"] as? Int, 1)
    let unchanged = try await object(
      "reading-insights-sharing/me", token: token, expectedStatus: 200)
    XCTAssertEqual(try json(unchanged), try json(initial))
    attach(unchanged, name: "P-N01-retained-retry-canonical-unchanged-after-503")
    capture("P-N01-retained-summary-failure-with-retry", app: app)
    collectAccessibilityAudit(app, screen: "retained-summary-save-failure")
    retry.tap()
    assertVisibleSaveOutcome(app, privateSharing: false)
    assertSelectedLevel("Summary", app: app)
    let saved = try await object("reading-insights-sharing/me", token: token, expectedStatus: 200)
    XCTAssertEqual(saved["sharingLevel"] as? String, "summary")
    XCTAssertNotNil(saved["consentedAt"] as? String)
    attach(saved, name: "P-N01-retained-retry-canonical-summary-after-200")
    let recovered = try await privacyFault("state", method: "GET", expectedStatus: 200)
    XCTAssertEqual(recovered["armed"] as? Bool, false)
    XCTAssertEqual(recovered["failed"] as? Int, 1)
    capture("P-N01-retained-summary-recovered-with-one-native-retry", app: app)
    functionalAssertionsCompleted = true
  }

  @MainActor
  private func runHandoffJourney(
    includePrivateSave: Bool, resumeAfterPrivatePreview: Bool = false,
    resumeAfterSummarySave: Bool = false
  ) async throws {
    defer { reportAccessibilityResult() }
    let subject = try await login("ipad-owner")
    let token = try XCTUnwrap(subject["accessToken"] as? String)
    let subjectID = try XCTUnwrap((subject["user"] as? [String: Any])?["id"] as? Int)
    let users = try await object(
      "users?search=ipad-e04-insights-viewer&page=0&pageSize=20", token: token)
    let viewer = try XCTUnwrap((users["users"] as? [[String: Any]])?.first)
    let viewerID = try XCTUnwrap(viewer["id"] as? Int)
    let personalNote: String
    let highlight: String
    let usesRetainedFixture = resumeAfterPrivatePreview || resumeAfterSummarySave
    if usesRetainedFixture {
      let settings = try await object(
        "reading-insights-sharing/me", token: token, expectedStatus: 200)
      if resumeAfterSummarySave {
        XCTAssertEqual(subjectID, 1)
        XCTAssertEqual(settings["sharingLevel"] as? String, "summary")
        XCTAssertEqual(settings["consentedAt"] as? String, "2026-10-11T12:27:30.540Z")
      } else {
        XCTAssertEqual(settings["sharingLevel"] as? String, "private")
        XCTAssertTrue(settings["consentedAt"] is NSNull)
      }
      let book = try await object("books/1", token: token, expectedStatus: 200)
      personalNote = try XCTUnwrap(book["personalNote"] as? String)
      XCTAssertTrue(personalNote.hasPrefix("E04 private personal note "))
      let annotations = try await object(
        "books/1/annotations?page=1&pageSize=1&sortBy=createdAt&sortDir=desc&search=E04%20private%20highlight",
        token: token, expectedStatus: 200)
      let annotation = try XCTUnwrap((annotations["items"] as? [[String: Any]])?.first)
      highlight = try XCTUnwrap(annotation["text"] as? String)
      XCTAssertTrue(highlight.hasPrefix("E04 private highlight "))
      if resumeAfterSummarySave {
        XCTAssertEqual(annotation["id"] as? Int, 241)
        XCTAssertEqual(
          personalNote, "E04 private personal note 71AE1F30-9479-4530-A69C-8574462DFB75")
        XCTAssertEqual(highlight, "E04 private highlight AC9A337B-29F1-4B1C-B8A9-DE4711DE0C17")
      }
      attach(
        [
          "ownerUserId": subjectID, "settings": settings, "privatePersonalNote": personalNote,
          "privateHighlight": highlight, "annotationId": annotation["id"] ?? NSNull(),
        ], name: "P-N01-retained-remainder-existing-private-fixture")
    } else {
      personalNote = "E04 private personal note \(UUID().uuidString)"
      highlight = "E04 private highlight \(UUID().uuidString)"
      _ = try await object(
        "books/1/personal-note", token: token, method: "PATCH", body: ["note": personalNote])
      _ = try await object(
        "books/1/annotations", token: token, method: "POST",
        body: [
          "bookFileId": 1, "text": highlight, "note": "E04 private passage note", "color": "yellow",
          "style": "highlight",
          "pdf": [
            "page": 0, "rect": ["x": 0.1, "y": 0.1, "width": 0.2, "height": 0.1],
            "rects": [["x": 0.1, "y": 0.1, "width": 0.2, "height": 0.1]],
          ],
        ])
      for (bookID, minutes) in [(1, 10), (2, 20)] {
        _ = try await object(
          "books/\(bookID)/sessions", token: token, method: "POST",
          body: [
            "clientId": UUID().uuidString,
            "startedAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-7200)),
            "durationMinutes": minutes,
          ])
      }
    }

    let app = launchPrivacy(username: "ipad-owner")
    if !usesRetainedFixture {
      if includePrivateSave {
        try await setLevel("Private", raw: "private", app: app, token: token)
      } else {
        try await assertPrivateSettings(token: token)
        assertSelectedLevel("Private", app: app)
      }
      app.buttons["readingPrivacyPreview"].tap()
      XCTAssertTrue(app.staticTexts["readingPrivacyPrivatePreview"].waitForExistence(timeout: 10))
      capture("IPAD-E04-A02-native-private", app: app)
      collectAccessibilityAudit(app, screen: "private-preview")
    }
    if resumeAfterSummarySave {
      assertSelectedLevel("Summary", app: app)
    } else {
      try await setLevel("Summary", raw: "summary", app: app, token: token)
    }
    app.buttons["readingPrivacyPreview"].tap()
    revealPreviewSessions(app)
    capture("IPAD-E04-A02-native-summary", app: app)
    collectAccessibilityAudit(app, screen: "summary-preview")
    try await setLevel("Detailed", raw: "detailed", app: app, token: token)
    app.buttons["readingPrivacyPreview"].tap()
    revealPreviewSessions(app)
    capture("IPAD-E04-A02-native-detailed", app: app)
    collectAccessibilityAudit(app, screen: "detailed-preview")
    let restrictions = app.buttons["readingPrivacyContentRestrictions"]
    reveal(restrictions, in: app)
    XCTAssertTrue(restrictions.isHittable)
    restrictions.tap()
    let search = app.textFields["contentRestrictionUserSearch"]
    XCTAssertTrue(search.waitForExistence(timeout: 10))
    search.tap()
    search.typeText("ipad-e04-insights-viewer")
    app.buttons["contentRestrictionSearchUsers"].tap()
    let viewerRow = app.buttons["contentRestrictionUser\(viewerID)"]
    XCTAssertTrue(viewerRow.waitForExistence(timeout: 10))
    viewerRow.tap()
    let ownRequests = app.switches["contentRestrictionOwnRequests"]
    reveal(ownRequests, in: app)
    XCTAssertTrue(ownRequests.waitForExistence(timeout: 10))
    let ownRequestsValue = try XCTUnwrap(ownRequests.value as? String)
    XCTAssertTrue(["0", "1"].contains(ownRequestsValue))
    if ownRequestsValue == "0" {
      ownRequests.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    }
    let ownRequestsEnabled = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "1"), object: ownRequests)
    XCTAssertEqual(XCTWaiter.wait(for: [ownRequestsEnabled], timeout: 5), .completed)
    let save = app.buttons["contentRestrictionSave"]
    reveal(save, in: app)
    save.tap()
    XCTAssertTrue(app.staticTexts["contentRestrictionSaved"].waitForExistence(timeout: 10))
    let filters = try await object("users/\(viewerID)/content-filters", token: token)
    XCTAssertEqual(filters["seeOwnRequestedBooks"] as? Bool, true)
    XCTAssertEqual(
      (filters["excludeTags"] as? [[String: Any]])?.first?["name"] as? String,
      "E04 restricted insight")
    capture("IPAD-E04-A02-native-content-restrictions", app: app)
    collectAccessibilityAudit(app, screen: "content-restrictions")
    let excludedTags = try XCTUnwrap(filters["excludeTags"] as? [[String: Any]])
    XCTAssertFalse(excludedTags.isEmpty)
    app.terminate()
    app.launch()
    XCTAssertTrue(app.buttons["signOut"].waitForExistence(timeout: 15))
    app.buttons["signOut"].tap()
    if app.buttons["connectServer"].waitForExistence(timeout: 5) {
      app.buttons["connectServer"].tap()
    }
    XCTAssertTrue(app.textFields["username"].waitForExistence(timeout: 15))
    let viewerUsername = app.textFields["username"]
    viewerUsername.tap()
    let previousUsername = viewerUsername.value as? String ?? ""
    if !previousUsername.isEmpty {
      viewerUsername.typeText(
        String(repeating: XCUIKeyboardKey.delete.rawValue, count: previousUsername.count))
    }
    viewerUsername.typeText("ipad-e04-insights-viewer")
    app.secureTextFields["password"].tap()
    app.secureTextFields["password"].typeText("IpadFixture123")
    app.buttons["signIn"].tap()
    XCTAssertTrue(app.buttons["readingPrivacy"].waitForExistence(timeout: 20))
    reveal(app.buttons["readingPrivacy"], in: app)
    app.buttons["readingPrivacy"].tap()
    let sharedInsights = app.buttons["openSharedReadingInsights"]
    reveal(sharedInsights, in: app)
    XCTAssertTrue(sharedInsights.waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["readingPrivacyContentRestrictions"].exists)
    sharedInsights.tap()
    let sharedSearch = app.textFields["sharedReadingSearch"]
    XCTAssertTrue(sharedSearch.waitForExistence(timeout: 15))
    sharedSearch.tap()
    sharedSearch.typeText("ipad-owner")
    app.buttons["sharedReadingSearchAccounts"].tap()
    let subjectRow = app.buttons["sharedReadingAccount\(subjectID)"]
    XCTAssertTrue(subjectRow.waitForExistence(timeout: 15))
    subjectRow.tap()
    let recentBooks = app.buttons["readingInsightRecentBooks"]
    reveal(recentBooks, in: app)
    XCTAssertTrue(recentBooks.waitForExistence(timeout: 15))
    recentBooks.tap()
    let permittedRow = app.descendants(matching: .any)["readingInsightBook1"]
    reveal(permittedRow, in: app)
    XCTAssertTrue(permittedRow.waitForExistence(timeout: 10))
    XCTAssertFalse(app.descendants(matching: .any)["readingInsightBook2"].exists)
    XCTAssertFalse(app.staticTexts["sharedReadingError"].exists)
    capture("IPAD-E04-A02-native-permitted-shared-insights", app: app)
    collectAccessibilityAudit(app, screen: "permitted-shared-insights")
    let viewerSession = try await login("ipad-e04-insights-viewer")
    let viewerToken = try XCTUnwrap(viewerSession["accessToken"] as? String)
    let view = try await object(
      "shared-reading-insights/\(subjectID)/view-sessions", token: viewerToken, method: "POST")
    let viewSessionID = try XCTUnwrap(view["viewSessionId"] as? String)
    let detail = try await object(
      "shared-reading-insights/\(subjectID)/detailed?days=30", token: viewerToken,
      viewSessionID: viewSessionID)
    let topBooks = try XCTUnwrap(detail["topBooks"] as? [[String: Any]])
    XCTAssertTrue(topBooks.contains { $0["bookId"] as? Int == 1 })
    XCTAssertFalse(topBooks.contains { $0["bookId"] as? Int == 2 })
    let serialized = String(
      decoding: try JSONSerialization.data(withJSONObject: detail), as: UTF8.self)
    XCTAssertFalse(serialized.contains(personalNote))
    XCTAssertFalse(serialized.contains(highlight))
    let receiver = try XCTUnwrap(
      ProcessInfo.processInfo.environment["IPAD_E04_RECEIVER_URL"]
        ?? ProcessInfo.processInfo.environment["TEST_RUNNER_IPAD_E04_RECEIVER_URL"])
    var handoff = URLRequest(url: try XCTUnwrap(URL(string: receiver + "/native-handoff")))
    handoff.httpMethod = "POST"
    handoff.setValue("application/json", forHTTPHeaderField: "Content-Type")
    handoff.httpBody = try JSONSerialization.data(withJSONObject: [
      "testId": "IPAD-E04-A02", "case": "A02", "username": "ipad-owner",
      "viewerUsername": "ipad-e04-insights-viewer",
      "userId": subjectID, "sharingLevel": "detailed", "permittedBookIds": [1],
      "excludedBookIds": [2],
      "privatePersonalNote": personalNote, "privateHighlight": highlight,
    ])
    let (_, response) = try await E04FixtureHTTP.data(for: handoff)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201)
    for session in [subject, viewerSession] {
      _ = try await object(
        "auth/logout", method: "POST",
        body: ["refreshToken": try XCTUnwrap(session["refreshToken"] as? String)])
    }
    functionalAssertionsCompleted = true
  }

  @MainActor
  private func collectAccessibilityAudit(_ app: XCUIApplication, screen: String) {
    auditedScreens.append(screen)
    do {
      try app.performAccessibilityAudit(for: .all) { issue in
        var finding: [String: Any] = [
          "screen": screen, "auditType": issue.auditType.rawValue,
          "compactDescription": issue.compactDescription,
          "detailedDescription": issue.detailedDescription,
        ]
        if let element = issue.element, element.exists {
          finding["elementLabel"] = element.label
          finding["elementIdentifier"] = element.identifier
          finding["elementDescription"] = element.debugDescription
          let attachment = XCTAttachment(screenshot: element.screenshot())
          attachment.name = "P-N01-audit-\(screen)-issue-\(self.accessibilityFindings.count + 1)"
          attachment.lifetime = .keepAlways
          self.add(attachment)
        }
        self.accessibilityFindings.append(finding)
        self.attach(
          finding, name: "P-N01-audit-\(screen)-issue-\(self.accessibilityFindings.count)")
        // Every issue is reported as a failure after the domain assertions finish.
        return true
      }
    } catch {
      let finding: [String: Any] = [
        "screen": screen, "compactDescription": "Accessibility audit could not complete",
        "detailedDescription": error.localizedDescription,
      ]
      accessibilityFindings.append(finding)
      attach(finding, name: "P-N01-audit-\(screen)-execution-failure")
    }
  }

  @MainActor
  private func reportAccessibilityResult() {
    attach(
      [
        "functionalAssertions": functionalAssertionsCompleted ? "PASS" : "INCOMPLETE",
        "nativeAccessibilityAudit": accessibilityFindings.isEmpty
          ? (auditedScreens.isEmpty ? "NOT RUN" : "PASS") : "FAIL",
        "auditedScreens": auditedScreens, "issues": accessibilityFindings,
      ], name: "P-N01-functional-and-accessibility-results")
    let previous = continueAfterFailure
    continueAfterFailure = true
    defer { continueAfterFailure = previous }
    for finding in accessibilityFindings {
      XCTFail(
        "Accessibility audit: \(finding["screen"] ?? "unknown"): \(finding["compactDescription"] ?? "unknown issue"). \(finding["detailedDescription"] ?? "")"
      )
    }
  }

  @MainActor
  private func setLevel(_ title: String, raw: String, app: XCUIApplication, token: String)
    async throws
  {
    selectLevel(title, app: app)
    app.buttons["readingPrivacySave"].tap()
    assertVisibleSaveOutcome(app, privateSharing: raw == "private")
    let settings = try await object("reading-insights-sharing/me", token: token)
    XCTAssertEqual(settings["sharingLevel"] as? String, raw)
    XCTAssertFalse(app.staticTexts["readingPrivacyError"].exists)
  }

  @MainActor
  private func revealPreviewSessions(_ app: XCUIApplication) {
    let form = app.collectionViews["readingPrivacyContent"]
    XCTAssertTrue(form.waitForExistence(timeout: 10))
    XCTAssertTrue(
      form.descendants(matching: .any)["readingInsightSharingLevel"].waitForExistence(timeout: 10))
    let sessions = form.staticTexts["readingInsightSessionCount"]
    if !sessions.exists || !sessions.isHittable || !form.frame.contains(sessions.frame) {
      let readingTime = form.descendants(matching: .any)["readingInsightReadingTime"]
      XCTAssertTrue(readingTime.waitForExistence(timeout: 10))
      // The adjacent Reading time row bounds the next lazy Sessions row before it materializes.
      let row =
        sessions.exists
        ? sessions.frame : readingTime.frame.offsetBy(dx: 0, dy: readingTime.frame.height)
      let distance = min(
        form.frame.height * 0.25, max(row.height, row.maxY - form.frame.maxY + row.height))
      let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.65))
      let end = start.withOffset(CGVector(dx: 0, dy: -distance))
      start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
    }
    let revealed = app.collectionViews["readingPrivacyContent"].staticTexts[
      "readingInsightSessionCount"]
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = "P-N01-preview-sessions-bounded-reveal-hierarchy"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
    capture("P-N01-preview-sessions-bounded-reveal", app: app)
    XCTAssertTrue(revealed.waitForExistence(timeout: 10))
    XCTAssertTrue(revealed.isHittable)
    XCTAssertTrue(app.collectionViews["readingPrivacyContent"].frame.contains(revealed.frame))
    attach(
      [
        "identifier": revealed.identifier, "label": revealed.label,
        "frame": String(describing: revealed.frame),
        "formFrame": String(describing: app.collectionViews["readingPrivacyContent"].frame),
      ], name: "P-N01-preview-sessions-visible-node")
  }

  @MainActor
  private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
    for _ in 0..<10 {
      if element.isHittable { return }
      let form = app.collectionViews["readingPrivacyContent"]
      let visible = form.exists ? form.frame : app.frame
      if element.exists && element.frame.minY < visible.minY {
        app.swipeDown()
      } else {
        app.swipeUp()
      }
    }
    XCTAssertTrue(element.isHittable)
  }

  private func environment(_ key: String, fallback: String) -> String {
    ProcessInfo.processInfo.environment[key]
      ?? ProcessInfo.processInfo.environment["TEST_RUNNER_\(key)"] ?? fallback
  }

  @MainActor
  private func launchPrivacy(username: String, serverURL: String? = nil) -> XCUIApplication {
    let app = XCUIApplication()
    let profile = environment("IPAD_E04_PROFILE", fallback: "pro13-portrait-light")
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
    let serverField = app.textFields["serverURL"]
    XCTAssertTrue(serverField.waitForExistence(timeout: 10))
    replace(serverField, value: serverURL ?? server)
    app.buttons["connectServer"].tap()
    XCTAssertTrue(app.textFields["username"].waitForExistence(timeout: 15))
    replace(app.textFields["username"], value: username)
    replace(app.secureTextFields["password"], value: "IpadFixture123")
    app.buttons["signIn"].tap()
    openPrivacy(app)
    return app
  }

  @MainActor
  private func openPrivacy(_ app: XCUIApplication) {
    XCTAssertTrue(app.buttons["readingPrivacy"].waitForExistence(timeout: 20))
    reveal(app.buttons["readingPrivacy"], in: app)
    app.buttons["readingPrivacy"].tap()
    XCTAssertTrue(
      app.buttons["readingPrivacySave"].wait(for: \.isEnabled, toEqual: true, timeout: 15))
    XCTAssertTrue(app.buttons["readingPrivacySharingLevel"].isHittable)
  }

  @MainActor
  private func tapSaveSharingSetting(_ app: XCUIApplication) {
    let save = app.buttons["readingPrivacySave"]
    XCTAssertTrue(save.wait(for: \.isHittable, toEqual: true, timeout: 5))
    XCTAssertTrue(save.isEnabled)
    let form = app.collectionViews["readingPrivacyContent"]
    XCTAssertTrue(form.exists)
    XCTAssertTrue(form.frame.contains(save.frame))
    save.tap()
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

  @MainActor
  private func selectLevel(_ title: String, app: XCUIApplication) {
    reveal(app.buttons["readingPrivacySharingLevel"], in: app)
    app.buttons["readingPrivacySharingLevel"].tap()
    XCTAssertTrue(app.buttons[title].wait(for: \.isHittable, toEqual: true, timeout: 5))
    app.buttons[title].tap()
    assertSelectedLevel(title, app: app)
    XCTAssertFalse(app.staticTexts["readingPrivacySaved"].exists)
  }

  @MainActor
  private func assertSelectedLevel(_ title: String, app: XCUIApplication) {
    let picker = app.buttons["readingPrivacySharingLevel"]
    XCTAssertTrue(picker.isHittable)
    XCTAssertTrue(
      picker.label.contains(title) || (picker.value as? String ?? "").contains(title)
        || picker.staticTexts[title].exists)
  }

  @MainActor
  private func assertVisibleSaveOutcome(_ app: XCUIApplication, privateSharing: Bool) {
    let message = app.staticTexts["readingPrivacySaved"]
    XCTAssertTrue(message.wait(for: \.isHittable, toEqual: true, timeout: 15))
    assertVisibleBesideSave(message, app: app)
    XCTAssertTrue(
      app.buttons["readingPrivacySave"].wait(for: \.isEnabled, toEqual: true, timeout: 5))
    XCTAssertFalse(app.staticTexts["readingPrivacyError"].exists)
    if privateSharing {
      XCTAssertEqual(message.label, "Sharing is off. Existing insight access is revoked.")
    } else {
      XCTAssertEqual(message.label, "Sharing settings saved.")
    }
  }

  @MainActor
  private func assertVisibleBesideSave(_ outcome: XCUIElement, app: XCUIApplication) {
    let form = app.collectionViews["readingPrivacyContent"]
    XCTAssertTrue(form.exists)
    XCTAssertTrue(form.frame.contains(outcome.frame))
    XCTAssertTrue(outcome.isHittable)
    XCTAssertTrue(app.buttons["readingPrivacySave"].isHittable)
  }

  @MainActor
  private func assertPrivateSettings(token: String) async throws {
    let settings = try await object(
      "reading-insights-sharing/me", token: token, expectedStatus: 200)
    XCTAssertEqual(settings["sharingLevel"] as? String, "private")
    XCTAssertTrue(settings["consentedAt"] is NSNull)
    attach(settings, name: "P-N01-actual-canonical-private-after-native-save")
  }

  @MainActor
  private func withDisposableSubject(_ body: @MainActor (String, String) async throws -> Void)
    async throws
  {
    let administrator = try await login("ipad-owner")
    let administratorToken = try XCTUnwrap(administrator["accessToken"] as? String)
    let refreshToken = try XCTUnwrap(administrator["refreshToken"] as? String)
    let book = try await object("books/1", token: administratorToken)
    let libraryID = try XCTUnwrap(book["libraryId"] as? Int)
    let username = "ipad-e04-privacy-\(UUID().uuidString.lowercased())"
    let account = try await object(
      "users", token: administratorToken, method: "POST",
      body: [
        "username": username, "name": "Privacy save feedback",
        "email": "\(username)@example.test", "permissionNames": [], "libraryIds": [libraryID],
      ], expectedStatus: 201)
    let userID = try XCTUnwrap(account["id"] as? Int)
    let endpoint = try XCTUnwrap(URL(string: base + "/users/\(userID)"))
    let logout = try XCTUnwrap(URL(string: base + "/auth/logout"))
    addTeardownBlock {
      var deletion = URLRequest(url: endpoint)
      deletion.httpMethod = "DELETE"
      deletion.timeoutInterval = 10
      deletion.setValue("Bearer \(administratorToken)", forHTTPHeaderField: "Authorization")
      let (_, deleted) = try await E04FixtureHTTP.data(for: deletion)
      XCTAssertEqual((deleted as? HTTPURLResponse)?.statusCode, 204)
      var request = URLRequest(url: logout)
      request.httpMethod = "POST"
      request.timeoutInterval = 10
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: ["refreshToken": refreshToken])
      let (_, loggedOut) = try await E04FixtureHTTP.data(for: request)
      XCTAssertEqual((loggedOut as? HTTPURLResponse)?.statusCode, 200)
    }
    let resetURL = try XCTUnwrap(account["resetUrl"] as? String)
    let resetToken = try XCTUnwrap(
      URLComponents(string: resetURL)?.queryItems?.first { $0.name == "token" }?.value)
    _ = try await object(
      "auth/reset-password", method: "POST",
      body: ["token": resetToken, "newPassword": "IpadFixture123"], expectedStatus: 204)
    let subject = try await login(username)
    let token = try XCTUnwrap(subject["accessToken"] as? String)
    try await body(username, token)
  }

  @MainActor
  private func resetPrivacyFault() async throws {
    _ = try await privacyFault("reset", method: "POST", expectedStatus: 204)
    let endpoint = try XCTUnwrap(URL(string: faultServer + "/__faults/privacy-sharing/reset"))
    addTeardownBlock {
      var request = URLRequest(url: endpoint)
      request.httpMethod = "POST"
      request.timeoutInterval = 10
      let (_, response) = try await E04FixtureHTTP.data(for: request)
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
    }
  }

  @MainActor
  private func privacyFault(_ action: String, method: String, expectedStatus: Int) async throws
    -> [String: Any]
  {
    var request = URLRequest(
      url: try XCTUnwrap(URL(string: faultServer + "/__faults/privacy-sharing/" + action)))
    request.httpMethod = method
    request.timeoutInterval = 10
    let (data, response) = try await E04FixtureHTTP.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, expectedStatus)
    if data.isEmpty { return [:] }
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func json(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  private func attach(_ object: [String: Any], name: String) {
    do {
      let attachment = XCTAttachment(data: try json(object), uniformTypeIdentifier: "public.json")
      attachment.name = name
      attachment.lifetime = .keepAlways
      add(attachment)
    } catch {
      XCTFail("Could not attach observed public privacy state.")
    }
  }

  @MainActor
  private func capture(_ name: String, app: XCUIApplication) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor
  private func login(_ username: String) async throws -> [String: Any] {
    try await object(
      "auth/login", method: "POST",
      body: [
        "username": username, "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "Privacy native journey fixture",
      ])
  }

  @MainActor
  func testIPADE04A02AsyncTeardownAssertionFailureProbe() async throws {
    try XCTSkipUnless(environment("IPAD_E04_TEARDOWN_PROBE", fallback: "") == "assertion")
    addTeardownBlock {
      await Task.yield()
      print("[privacy.teardown_probe] [end] completed=true - nonisolated async teardown completed")
    }
    attach(["intentionalFailure": true], name: "P-N01-teardown-probe-primary")
    await Task.yield()
    XCTFail("Intentional teardown assertion probe")
  }

  @MainActor
  func testIPADE04A02AsyncTeardownHTTPFailureProbe() async throws {
    try XCTSkipUnless(environment("IPAD_E04_TEARDOWN_PROBE", fallback: "") == "http")
    let owner = try await login("ipad-owner")
    let token = try XCTUnwrap(owner["accessToken"] as? String)
    let refreshToken = try XCTUnwrap(owner["refreshToken"] as? String)
    try registerLogout(refreshToken)
    _ = try await object("books/1", token: token, expectedStatus: 201)
  }

  @MainActor
  private func registerLogout(_ refreshToken: String) throws {
    let request = try cleanupRequest(
      "auth/logout", method: "POST", body: ["refreshToken": refreshToken])
    addTeardownBlock {
      _ = try await ReadingPrivacyJourneyTests.cleanupData(
        request, name: "P-N01-verification-session-logout")
    }
  }

  private func cleanupRequest(
    _ path: String, token: String? = nil, method: String = "GET", body: [String: Any]? = nil
  ) throws -> URLRequest {
    var request = URLRequest(url: try XCTUnwrap(URL(string: base + "/" + path)))
    request.httpMethod = method
    request.timeoutInterval = 10
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    return request
  }

  private enum CleanupError: Error {
    case invalidHTTPResponse
    case unexpectedHTTPStatus(Int)
    case canonicalStateMismatch
  }

  private static func cleanupData(_ request: URLRequest, name: String) async throws -> Data {
    let (data, response) = try await E04FixtureHTTP.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw CleanupError.invalidHTTPResponse
    }
    let status = response.statusCode
    let evidence = try JSONSerialization.data(
      withJSONObject: [
        "name": name, "path": request.url?.path ?? "", "status": status,
        "body": String(decoding: data.prefix(2048), as: UTF8.self),
      ], options: [.sortedKeys])
    print(
      "[privacy.cleanup] [\(status == 200 ? "end" : "fail")] receipt=\(String(decoding: evidence, as: UTF8.self)) - HTTP cleanup completed"
    )
    guard status == 200 else { throw CleanupError.unexpectedHTTPStatus(status) }
    return data
  }

  private static func canonicalJSON(_ data: Data) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: JSONSerialization.jsonObject(with: data), options: [.sortedKeys])
  }

  @MainActor
  private func object(
    _ path: String, token: String? = nil, method: String = "GET", body: [String: Any]? = nil,
    viewSessionID: String? = nil, expectedStatus: Int? = nil
  ) async throws -> [String: Any] {
    var request = URLRequest(url: try XCTUnwrap(URL(string: base + "/" + path)))
    request.httpMethod = method
    request.timeoutInterval = 30
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let viewSessionID {
      request.setValue(viewSessionID, forHTTPHeaderField: "x-reading-insights-view-session")
    }
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await E04FixtureHTTP.data(for: request)
    let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
    if !(200..<300).contains(httpResponse.statusCode)
      || (expectedStatus != nil && httpResponse.statusCode != expectedStatus)
    {
      attach(
        [
          "path": path, "status": httpResponse.statusCode,
          "body": String(decoding: data, as: UTF8.self),
        ],
        name: "P-N01-unexpected-public-http-response")
    }
    if let expectedStatus { XCTAssertEqual(httpResponse.statusCode, expectedStatus, path) }
    XCTAssertTrue(
      (200..<300).contains(httpResponse.statusCode),
      "\(path): \(httpResponse.statusCode) \(String(decoding: data, as: UTF8.self))")
    if data.isEmpty { return [:] }
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}
