import Vision
import XCTest

final class ComicReaderProofTests: ReaderProofTestCase {
  @MainActor
  func testIPADE01A03ComicCloseWaitsForLatestPageAndPreservesNarration() async throws {
    let fileID = try await prepareComic()
    let login = try await Self.request(
      "http://localhost:16482/api/v1/auth/login", method: "POST",
      body: [
        "username": "ipad-reader", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "Comic concurrent narration QA",
      ])
    let credentials = try XCTUnwrap(JSONSerialization.jsonObject(with: login) as? [String: Any])
    let token = try XCTUnwrap(credentials["accessToken"] as? String)
    let refreshToken = try XCTUnwrap(credentials["refreshToken"] as? String)
    addTeardownBlock {
      _ = try await Self.request(
        "http://localhost:16482/api/v1/auth/logout", method: "POST",
        body: ["refreshToken": refreshToken])
    }
    _ = try await Self.request(
      "http://localhost:16482/api/v1/books/files/\(fileID)/progress", method: "POST", token: token,
      encodedBody: JSONSerialization.data(withJSONObject: [
        "source": "narration", "percentage": 10, "positionSeconds": 4,
        "mediaOverlayFragment": "chapter-one.xhtml#first", "mediaOverlaySectionIndex": 0,
      ]))
    let app = connectAndSignIn(serverURL: "http://localhost:16485")
    openComic(app, fileID: fileID)
    try assertComicPixels(1, in: app, state: "concurrent-first-page")
    try await comicFault("write-arm", fileID: fileID)
    app.otherElements["comicReader"].swipeLeft()
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 10))
    try await Self.fault("held")
    app.otherElements["comicReader"].swipeLeft()
    XCTAssertTrue(app.staticTexts["Page 3 of 3"].waitForExistence(timeout: 10))
    try assertComicPixels(3, in: app, state: "latest-page-save-held")
    app.buttons["Close reader"].tap()
    XCTAssertTrue(app.buttons["Close reader"].wait(for: \.isEnabled, toEqual: false, timeout: 5))
    XCTAssertTrue(app.staticTexts["Page 3 of 3"].exists)
    capture("IPAD-E01-A03-comic-close-waits-for-latest-save")
    _ = try await Self.request(
      "http://localhost:16482/api/v1/books/files/\(fileID)/progress", method: "POST", token: token,
      encodedBody: JSONSerialization.data(withJSONObject: [
        "source": "narration", "percentage": 20, "positionSeconds": 9,
        "mediaOverlayFragment": "chapter-one.xhtml#second", "mediaOverlaySectionIndex": 0,
      ]))
    try await Self.fault("release", method: "POST")
    XCTAssertTrue(app.buttons["readFile\(fileID)"].waitForExistence(timeout: 15))
    let data = try await Self.request(
      "http://localhost:16482/api/v1/books/files/\(fileID)/progress", token: token)
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = "IPAD-E01-A03-comic-latest-page-concurrent-public-progress"
    attachment.lifetime = .keepAlways
    add(attachment)
    let progress = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(progress["pageNumber"] as? Double, 3)
    XCTAssertEqual(progress["percentage"] as? Double, 100)
    XCTAssertEqual(progress["positionSeconds"] as? Double, 9)
    XCTAssertEqual(progress["mediaOverlayFragment"] as? String, "chapter-one.xhtml#second")
    XCTAssertEqual(progress["mediaOverlaySectionIndex"] as? Double, 0)
    XCTAssertEqual(progress["narrationPercentage"] as? Double, 20)
    app.buttons["readFile\(fileID)"].tap()
    XCTAssertTrue(app.staticTexts["Page 3 of 3"].waitForExistence(timeout: 15))
    try assertComicPixels(3, in: app, state: "latest-page-immediate-reopen")
    try app.performAccessibilityAudit()
    closeComicAndSignOut(app, fileID: fileID)
  }

  @MainActor
  func testIPADE01A05ComicOpenFailureCanRetry() async throws {
    let fileID = try await prepareComic()
    try await comicFault("count-fail", fileID: fileID)
    let app = connectAndSignIn(serverURL: "http://localhost:16485")
    openComic(app, fileID: fileID)
    XCTAssertTrue(
      app.staticTexts["The server could not complete the request (503). Try again."]
        .waitForExistence(timeout: 10))
    capture("IPAD-E01-A05-comic-opening-failed")
    try app.performAccessibilityAudit()
    let retry = app.buttons["Retry opening"]
    XCTAssertTrue(
      retry.waitForExistence(timeout: 5),
      "A recoverable opening failure needs a visible retry action")
    XCTAssertFalse(
      app.staticTexts["Opening comic…"].exists,
      "A completed opening failure must not remain in the loading state")
    try await comicFault("count-recover", fileID: fileID)
    retry.tap()
    XCTAssertTrue(app.staticTexts["Page 1 of 3"].waitForExistence(timeout: 15))
    try assertComicPixels(1, in: app, state: "opening-recovered")
    try app.performAccessibilityAudit()
    closeComicAndSignOut(app, fileID: fileID)
  }

  @MainActor
  func testIPADE01A05ComicFailedSaveCanRetryOrDiscard() async throws {
    let fileID = try await prepareComic()
    let app = connectAndSignIn(serverURL: "http://localhost:16485")
    openComic(app, fileID: fileID)
    try assertComicPixels(1, in: app, state: "failure-first-page")
    try await comicFault("progress-fail", fileID: fileID)
    app.otherElements["comicReader"].swipeLeft()
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Position could not be saved."].waitForExistence(timeout: 10))
    try assertComicPixels(2, in: app, state: "save-failed")
    XCTAssertTrue(app.buttons["Retry saving"].isHittable)
    XCTAssertTrue(app.buttons["Close without saving"].isHittable)
    try app.performAccessibilityAudit()
    try await comicFault("progress-recover", fileID: fileID)
    app.buttons["Retry saving"].tap()
    XCTAssertTrue(app.staticTexts["Position saved"].waitForExistence(timeout: 10))
    try assertComicPixels(2, in: app, state: "save-retried")
    try await comicFault("progress-fail", fileID: fileID)
    app.otherElements["comicReader"].swipeLeft()
    XCTAssertTrue(app.staticTexts["Page 3 of 3"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Position could not be saved."].waitForExistence(timeout: 10))
    try assertComicPixels(3, in: app, state: "third-save-failed")
    app.buttons["Close without saving"].tap()
    XCTAssertTrue(app.alerts["Discard unsaved position?"].waitForExistence(timeout: 5))
    capture("IPAD-E01-A05-comic-discard-confirmation")
    app.alerts.buttons["Keep reading"].tap()
    XCTAssertTrue(app.staticTexts["Page 3 of 3"].exists)
    app.buttons["Close without saving"].tap()
    app.alerts.buttons["Discard and close"].tap()
    XCTAssertTrue(app.buttons["readFile\(fileID)"].waitForExistence(timeout: 10))
    try await comicFault("progress-recover", fileID: fileID)
    app.buttons["readFile\(fileID)"].tap()
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 15))
    try assertComicPixels(2, in: app, state: "discard-reopened")
    try app.performAccessibilityAudit()
    closeComicAndSignOut(app, fileID: fileID)
  }

  @MainActor
  func testIPADE01A05ComicPageFailureCanRetry() async throws {
    let fileID = try await prepareComic()
    try await comicFault("pages-fail", fileID: fileID)
    let app = connectAndSignIn(serverURL: "http://localhost:16485")
    openComic(app, fileID: fileID)
    XCTAssertTrue(app.staticTexts["Page 1 of 3"].waitForExistence(timeout: 15))
    let retry = app.buttons["Retry page"]
    XCTAssertTrue(retry.waitForExistence(timeout: 10))
    XCTAssertFalse(app.images["comicPage1"].exists)
    capture("IPAD-E01-A05-comic-page-delivery-failed")
    try app.performAccessibilityAudit()
    XCTAssertFalse(
      app.staticTexts["Loading comic page…"].exists,
      "A failed page request must not announce that it is still loading")
    try await comicFault("pages-recover", fileID: fileID)
    retry.tap()
    try assertComicPixels(1, in: app, state: "page-delivery-recovered")
    XCTAssertFalse(app.buttons["Retry page"].exists)
    try app.performAccessibilityAudit()
    app.otherElements["comicReader"].swipeLeft()
    XCTAssertTrue(app.staticTexts["Position saved"].waitForExistence(timeout: 10))
    try assertComicPixels(2, in: app, state: "page-delivery-recovered-curl")
    closeComicAndSignOut(app, fileID: fileID)
  }

  @MainActor
  func testIPADE01A04ComicCurlRotationAndResume() async throws {
    let login = try await Self.request(
      "http://localhost:16482/api/v1/auth/login", method: "POST",
      body: [
        "username": "ipad-reader", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "Comic reader proof fixture",
      ])
    let credentials = try XCTUnwrap(JSONSerialization.jsonObject(with: login) as? [String: Any])
    let token = try XCTUnwrap(credentials["accessToken"] as? String)
    let refreshToken = try XCTUnwrap(credentials["refreshToken"] as? String)
    let bookData = try await Self.request("http://localhost:16482/api/v1/books/10", token: token)
    let book = try XCTUnwrap(JSONSerialization.jsonObject(with: bookData) as? [String: Any])
    let files = try XCTUnwrap(book["files"] as? [[String: Any]])
    let fileID = try XCTUnwrap(files.first { $0["format"] as? String == "cbz" }?["id"] as? Int)
    _ = try await Self.request(
      "http://localhost:16482/api/v1/books/files/\(fileID)/progress", method: "DELETE", token: token
    )
    _ = try await Self.request(
      "http://localhost:16482/api/v1/books/files/\(fileID)/progress", method: "POST", token: token,
      encodedBody: JSONSerialization.data(withJSONObject: [
        "source": "text", "percentage": 100.0 / 3, "pageNumber": 1,
        "cfi": "epubcfi(/6/2[c1ref]!/4/2[p1],/1:0,/1:5)",
        "koboLocationSource": "OPS/c1.xhtml", "koboLocationType": "KoboSpan",
        "koboLocationValue": "kobo.1.1", "koboContentSourceProgressPercent": 25,
        "koreaderProgress": "/body/DocFragment[1]/body",
        "positionSeconds": 9, "mediaOverlayFragment": "chapter-one.xhtml#second",
        "mediaOverlaySectionIndex": 0,
      ]))
    let seededData = try await Self.request(
      "http://localhost:16482/api/v1/books/files/\(fileID)/progress", token: token)
    let seeded = try XCTUnwrap(JSONSerialization.jsonObject(with: seededData) as? [String: Any])
    XCTAssertEqual(seeded["koreaderProgress"] as? String, "/body/DocFragment[1]/body")
    XCTAssertEqual(seeded["cfi"] as? String, "epubcfi(/6/2[c1ref]!/4/2[p1],/1:0,/1:5)")
    XCTAssertEqual(seeded["koboLocationValue"] as? String, "kobo.1.1")
    XCTAssertEqual(seeded["positionSeconds"] as? Double, 9)
    let seedAttachment = XCTAttachment(data: seededData, uniformTypeIdentifier: "public.json")
    seedAttachment.name = "IPAD-E01-A04-comic-existing-text-locator"
    seedAttachment.lifetime = .keepAlways
    add(seedAttachment)
    addTeardownBlock {
      _ = try await Self.request(
        "http://localhost:16482/api/v1/auth/logout", method: "POST",
        body: ["refreshToken": refreshToken])
    }
    let app = connectAndSignIn()
    openComic(app, fileID: fileID)
    XCTAssertTrue(app.staticTexts["Page 1 of 3"].waitForExistence(timeout: 15))
    try assertComicPixels(1, in: app, state: "first-page")
    try app.performAccessibilityAudit()
    app.otherElements["comicReader"].swipeLeft()
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Position saved"].waitForExistence(timeout: 10))
    try assertComicPixels(2, in: app, state: "curled-page")
    XCUIDevice.shared.orientation = .landscapeLeft
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 5))
    try assertComicPixels(2, in: app, state: "landscape")
    try app.performAccessibilityAudit()
    let data = try await Self.request(
      "http://localhost:16482/api/v1/books/files/\(fileID)/progress", token: token)
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = "IPAD-E01-A04-comic-public-progress"
    attachment.lifetime = .keepAlways
    add(attachment)
    let progress = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(progress["pageNumber"] as? Double, 2)
    XCTAssertEqual(try XCTUnwrap(progress["percentage"] as? Double), 200.0 / 3, accuracy: 0.01)
    for field in [
      "cfi", "koboLocationSource", "koboLocationType", "koboLocationValue",
      "koboContentSourceProgressPercent", "koreaderProgress",
    ] {
      XCTAssertTrue(progress[field] is NSNull, "A new native page replaces obsolete \(field)")
    }
    XCTAssertEqual(progress["positionSeconds"] as? Double, 9)
    XCTAssertEqual(progress["mediaOverlayFragment"] as? String, "chapter-one.xhtml#second")
    XCTAssertEqual(progress["mediaOverlaySectionIndex"] as? Double, 0)
    app.buttons["Close reader"].tap()
    XCTAssertTrue(app.buttons["readFile\(fileID)"].waitForExistence(timeout: 10))
    XCUIDevice.shared.orientation = .portrait
    app.terminate()
    app.launch()
    openComic(app, fileID: fileID)
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 15))
    try assertComicPixels(2, in: app, state: "resumed")
    try app.performAccessibilityAudit()
    app.buttons["Close reader"].tap()
    app.buttons["Done"].tap()
    app.buttons["signOut"].tap()
    XCTAssertTrue(app.buttons["connectServer"].waitForExistence(timeout: 10))
  }

  @MainActor
  private func openComic(_ app: XCUIApplication, fileID: Int) {
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    let search = app.searchFields.firstMatch
    search.tap()
    search.typeText("Library book 00009\n")
    let book = app.buttons["Library book 00009"]
    XCTAssertTrue(book.waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["1 book"].waitForExistence(timeout: 10))
    capture("IPAD-E01-A04-comic-single-result-library")
    book.tap()
    capture("IPAD-E01-A04-comic-book-details")
    let read = app.buttons["readFile\(fileID)"]
    XCTAssertTrue(read.waitForExistence(timeout: 5))
    read.tap()
  }

  @MainActor
  private func prepareComic() async throws -> Int {
    let login = try await Self.request(
      "http://localhost:16482/api/v1/auth/login", method: "POST",
      body: [
        "username": "ipad-reader", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "Comic failure QA",
      ])
    let credentials = try XCTUnwrap(JSONSerialization.jsonObject(with: login) as? [String: Any])
    let token = try XCTUnwrap(credentials["accessToken"] as? String)
    let refreshToken = try XCTUnwrap(credentials["refreshToken"] as? String)
    let bookData = try await Self.request("http://localhost:16482/api/v1/books/10", token: token)
    let book = try XCTUnwrap(JSONSerialization.jsonObject(with: bookData) as? [String: Any])
    let files = try XCTUnwrap(book["files"] as? [[String: Any]])
    let fileID = try XCTUnwrap(files.first { $0["format"] as? String == "cbz" }?["id"] as? Int)
    _ = try await Self.request(
      "http://localhost:16482/api/v1/books/files/\(fileID)/progress", method: "DELETE", token: token
    )
    try await comicFault("reset", fileID: fileID)
    addTeardownBlock {
      _ = try await Self.request(
        "http://localhost:16485/__faults/comic/\(fileID)/reset", method: "POST")
      _ = try await Self.request(
        "http://localhost:16482/api/v1/auth/logout", method: "POST",
        body: ["refreshToken": refreshToken])
    }
    return fileID
  }

  @MainActor
  private func comicFault(_ operation: String, fileID: Int) async throws {
    _ = try await Self.request(
      "http://localhost:16485/__faults/comic/\(fileID)/\(operation)", method: "POST")
  }

  @MainActor
  private func closeComicAndSignOut(_ app: XCUIApplication, fileID: Int) {
    app.buttons["Close reader"].tap()
    XCTAssertTrue(app.buttons["readFile\(fileID)"].waitForExistence(timeout: 10))
    app.buttons["Done"].tap()
    app.buttons["signOut"].tap()
    XCTAssertTrue(app.buttons["connectServer"].waitForExistence(timeout: 10))
  }

  @MainActor
  private func assertComicPixels(_ page: Int, in app: XCUIApplication, state: String) throws {
    XCTAssertTrue(app.images["comicPage\(page)"].waitForExistence(timeout: 10))
    let screenshot = app.otherElements["comicReader"].screenshot()
    let image = try XCTUnwrap(screenshot.image.cgImage)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US"]
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    let text = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
    XCTAssertTrue(
      text.contains("Orbit comic: page \(page)"), "Actual delivered page pixels must match")
    let json = XCTAttachment(
      data: try JSONSerialization.data(withJSONObject: ["page": page, "recognizedText": text]),
      uniformTypeIdentifier: "public.json")
    json.name = "IPAD-E01-A04-comic-pixels-\(state)"
    json.lifetime = .keepAlways
    add(json)
    let pixels = XCTAttachment(screenshot: screenshot)
    pixels.name = "IPAD-E01-A04-comic-page-pixels-\(state)"
    pixels.lifetime = .keepAlways
    add(pixels)
    capture("IPAD-E01-A04-comic-\(state)")
  }
}
