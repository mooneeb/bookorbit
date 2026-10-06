import Vision
import XCTest

final class ComicReaderProofTests: ReaderProofTestCase {
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
        "koreaderProgress": "/body/DocFragment[1]/body",
      ]))
    let seededData = try await Self.request(
      "http://localhost:16482/api/v1/books/files/\(fileID)/progress", token: token)
    let seeded = try XCTUnwrap(JSONSerialization.jsonObject(with: seededData) as? [String: Any])
    XCTAssertEqual(seeded["koreaderProgress"] as? String, "/body/DocFragment[1]/body")
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
    XCTAssertTrue(
      progress["koreaderProgress"] is NSNull, "A new native page replaces the old device position")
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
    book.tap()
    capture("IPAD-E01-A04-comic-book-details")
    let read = app.buttons["readFile\(fileID)"]
    XCTAssertTrue(read.waitForExistence(timeout: 5))
    read.tap()
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
