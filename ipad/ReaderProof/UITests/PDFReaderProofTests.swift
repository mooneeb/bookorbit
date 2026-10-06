import XCTest

final class PDFReaderProofTests: ReaderProofTestCase {
  @MainActor
  func testIPADE01A03ConcurrentTextSaveDoesNotRollBackNarration() async throws {
    try await Self.resetProgress()
    let login = try await Self.request(
      "http://localhost:16482/api/v1/auth/login", method: "POST",
      body: [
        "username": "ipad-reader", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "Concurrent narration fixture",
      ])
    let credentials = try XCTUnwrap(JSONSerialization.jsonObject(with: login) as? [String: Any])
    let token = try XCTUnwrap(credentials["accessToken"] as? String)
    let refreshToken = try XCTUnwrap(credentials["refreshToken"] as? String)
    addTeardownBlock {
      try await Self.fault("snapshot-reset", method: "POST")
      _ = try await Self.request(
        "http://localhost:16482/api/v1/books/files/1/progress", method: "DELETE", token: token)
      _ = try await Self.request(
        "http://localhost:16482/api/v1/auth/logout", method: "POST",
        body: ["refreshToken": refreshToken])
    }
    _ = try await Self.request(
      "http://localhost:16482/api/v1/books/files/1/progress", method: "POST", token: token,
      encodedBody: JSONSerialization.data(withJSONObject: [
        "source": "narration", "percentage": 10, "positionSeconds": 4,
        "mediaOverlayFragment": "chapter-one.xhtml#first", "mediaOverlaySectionIndex": 0,
      ]))
    let app = connectAndSignIn(serverURL: "http://localhost:16485")
    openPDF(app)
    XCTAssertTrue(app.staticTexts["Page 1 of 3"].waitForExistence(timeout: 15))
    assertPassage(1, in: app)
    try await Self.fault("snapshot-arm", method: "POST")
    app.otherElements["pdfReader"].swipeLeft()
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 10))
    try await Self.fault("held")
    capture("IPAD-E01-A03-proof-older-progress-response-held")
    _ = try await Self.request(
      "http://localhost:16482/api/v1/books/files/1/progress", method: "POST", token: token,
      encodedBody: JSONSerialization.data(withJSONObject: [
        "source": "narration", "percentage": 20, "positionSeconds": 9,
        "mediaOverlayFragment": "chapter-one.xhtml#second", "mediaOverlaySectionIndex": 0,
      ]))
    try await Self.fault("release", method: "POST")
    XCTAssertTrue(app.staticTexts["Position saved"].waitForExistence(timeout: 15))
    assertPassage(2, in: app)
    capture("IPAD-E01-A03-proof-concurrent-text-position-saved")
    let data = try await Self.request(
      "http://localhost:16482/api/v1/books/files/1/progress", token: token)
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = "IPAD-E01-A03-concurrent-public-progress"
    attachment.lifetime = .keepAlways
    add(attachment)
    let progress = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(progress["pageNumber"] as? Double, 2)
    XCTAssertEqual(progress["positionSeconds"] as? Double, 9)
    XCTAssertEqual(progress["mediaOverlayFragment"] as? String, "chapter-one.xhtml#second")
    XCTAssertEqual(progress["mediaOverlaySectionIndex"] as? Double, 0)
    XCTAssertEqual(progress["narrationPercentage"] as? Double, 20)
    try app.performAccessibilityAudit()
    app.buttons["Close reader"].tap()
    app.buttons["Done"].tap()
    app.buttons["signOut"].tap()
  }

  @MainActor
  func testIPADE01A03FailedSaveCanRetryOrDiscard() async throws {
    try await Self.resetProgress()
    let app = connectAndSignIn(serverURL: "http://localhost:16485")
    openPDF(app)
    XCTAssertTrue(app.staticTexts["Page 1 of 3"].waitForExistence(timeout: 15))
    try await Self.fault("fail", method: "POST")
    addTeardownBlock { try await Self.fault("recover", method: "POST") }
    app.otherElements["pdfReader"].swipeLeft()
    XCTAssertTrue(app.staticTexts["Position could not be saved."].waitForExistence(timeout: 10))
    capture("IPAD-E01-A03-proof-pdf-failed-position")
    XCTAssertTrue(app.buttons["Retry saving"].exists)
    XCTAssertTrue(app.buttons["Close without saving"].exists)
    try await Self.fault("recover", method: "POST")
    app.buttons["Retry saving"].tap()
    XCTAssertTrue(app.staticTexts["Position saved"].waitForExistence(timeout: 10))
    capture("IPAD-E01-A03-proof-pdf-retried-position")
    try await Self.fault("fail", method: "POST")
    app.otherElements["pdfReader"].swipeLeft()
    XCTAssertTrue(app.staticTexts["Page 3 of 3"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Position could not be saved."].waitForExistence(timeout: 10))
    app.buttons["Close without saving"].tap()
    XCTAssertTrue(app.buttons["Keep reading"].waitForExistence(timeout: 5))
    capture("IPAD-E01-A03-proof-pdf-discard-confirmation")
    app.buttons["Keep reading"].tap()
    XCTAssertTrue(app.staticTexts["Page 3 of 3"].exists)
    app.buttons["Close without saving"].tap()
    app.alerts.buttons["Discard and close"].tap()
    XCTAssertTrue(app.buttons["readFile1"].waitForExistence(timeout: 10))
    try await Self.fault("recover", method: "POST")
    app.buttons["readFile1"].tap()
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 15))
    assertPassage(2, in: app)
    capture("IPAD-E01-A03-proof-pdf-reopened-after-discard")
    app.buttons["Close reader"].tap()
    app.buttons["Done"].tap()
    app.buttons["signOut"].tap()
    XCTAssertTrue(app.buttons["connectServer"].waitForExistence(timeout: 10))
  }

  @MainActor
  func testIPADE01A03CloseWaitsForPendingPosition() async throws {
    try await Self.resetProgress()
    let app = connectAndSignIn(serverURL: "http://localhost:16485")
    openPDF(app)
    XCTAssertTrue(app.staticTexts["Page 1 of 3"].waitForExistence(timeout: 15))
    assertPassage(1, in: app)
    try await Self.fault("arm", method: "POST")
    addTeardownBlock { try await Self.fault("snapshot-reset", method: "POST") }
    app.otherElements["pdfReader"].swipeLeft()
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 10))
    try await Self.fault("held")
    capture("IPAD-E01-A03-proof-pdf-pending-position")
    app.buttons["Close reader"].tap()
    capture("IPAD-E01-A03-proof-pdf-waiting-to-close")
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].exists)
    XCTAssertFalse(app.buttons["Close reader"].isEnabled)
    try await Self.fault("release", method: "POST")
    let read = app.buttons["readFile1"]
    XCTAssertTrue(read.waitForExistence(timeout: 15))
    read.tap()
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 15))
    assertPassage(2, in: app)
    capture("IPAD-E01-A03-proof-pdf-immediate-close-resume")
    app.buttons["Close reader"].tap()
    app.buttons["Done"].tap()
    app.buttons["signOut"].tap()
    XCTAssertTrue(app.buttons["connectServer"].waitForExistence(timeout: 10))
  }

  @MainActor
  func testIPADE01A03PDFCurlAndResume() async throws {
    try await Self.resetProgress()
    let app = connectAndSignIn()
    openPDF(app)
    XCTAssertTrue(app.staticTexts["Page 1 of 3"].waitForExistence(timeout: 15))
    assertPassage(1, in: app)
    capture("IPAD-E01-A03-proof-pdf-first-page")
    try app.performAccessibilityAudit()
    let reader = app.otherElements["pdfReader"]
    XCTAssertTrue(reader.exists)
    reader.swipeLeft()
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Position saved"].waitForExistence(timeout: 10))
    assertPassage(2, in: app)
    capture("IPAD-E01-A03-proof-pdf-curled-page")
    XCUIDevice.shared.orientation = .landscapeLeft
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 5))
    assertPassage(2, in: app)
    capture("IPAD-E01-A03-proof-pdf-rotated")
    XCUIDevice.shared.orientation = .portrait
    app.terminate()
    app.launch()
    openPDF(app)
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 15))
    assertPassage(2, in: app)
    capture("IPAD-E01-A03-proof-pdf-resumed")
    try app.performAccessibilityAudit()
    app.buttons["Close reader"].tap()
    app.buttons["Done"].tap()
    app.buttons["signOut"].tap()
    XCTAssertTrue(app.buttons["connectServer"].waitForExistence(timeout: 10))
  }

}
