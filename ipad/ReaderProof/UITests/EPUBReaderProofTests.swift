import UIKit
import XCTest

final class EPUBReaderProofTests: ReaderProofTestCase {
  @MainActor
  func testIPADE01A04LocalEPUBResolvesUTF16Passage() async throws {
    try await Self.resetProgress(fileID: 2)
    let (app, passage) = openEPUB()
    let before = try capturePassage(passage, name: "IPAD-E01-A04-epub-unselected-passage")
    let anchor = app.textFields["passageAnchor"]
    XCTAssertTrue(anchor.exists)
    anchor.tap()
    anchor.typeText("epubcfi(/6/2[c1ref]!/4/2[p1],/1:6,/1:14)")
    app.buttons["Resolve passage"].tap()
    let resolved = app.staticTexts["resolvedPassage"]
    XCTAssertTrue(resolved.waitForExistence(timeout: 10))
    XCTAssertEqual(resolved.label, "😀 cafe\u{301}")
    XCTAssertEqual(
      app.staticTexts["roundTripAnchor"].label,
      "epubcfi(/6/2[c1ref]!/4/2[p1],/1:6,/1:14)")
    capture("IPAD-E01-A04-proof-epub-resolved-selection")
    let selected = try capturePassage(passage, name: "IPAD-E01-A04-epub-painted-selection")
    XCTAssertGreaterThan(
      selected, before + 100, "The actual passage must visibly paint its selection.")
    XCUIDevice.shared.orientation = .landscapeLeft
    XCTAssertTrue(passage.wait(for: \.isHittable, toEqual: true, timeout: 10))
    app.buttons["Resolve passage"].tap()
    XCTAssertTrue(resolved.waitForExistence(timeout: 10))
    XCTAssertEqual(resolved.label, "😀 cafe\u{301}")
    XCTAssertEqual(
      app.staticTexts["roundTripAnchor"].label,
      "epubcfi(/6/2[c1ref]!/4/2[p1],/1:6,/1:14)")
    capture("IPAD-E01-A04-proof-epub-selection-rotated")
    XCTAssertGreaterThan(
      try capturePassage(passage, name: "IPAD-E01-A04-epub-rotated-selection"), before + 100)
    closeReader(app)
  }

  @MainActor
  func testIPADE01A05EPUBContentAccessibility() async throws {
    try await Self.resetProgress(fileID: 2)
    let (app, passage) = openEPUB()
    try app.performAccessibilityAudit()
    XCUIDevice.shared.orientation = .landscapeLeft
    XCTAssertTrue(passage.wait(for: \.isHittable, toEqual: true, timeout: 10))
    capture("IPAD-E01-A05-proof-epub-rotated-audit")
    try app.performAccessibilityAudit()
    closeReader(app)
  }

  @MainActor
  func testIPADE01A05PlainDeliveredChapterAccessibility() async throws {
    try await Self.resetProgress(fileID: 2)
    let (app, passage) = openEPUB()
    let plain = app.buttons["Inspect plain chapter"]
    XCTAssertTrue(plain.waitForExistence(timeout: 5))
    plain.tap()
    XCTAssertTrue(app.staticTexts["Plain chapter loaded"].waitForExistence(timeout: 10))
    XCTAssertTrue(passage.wait(for: \.isHittable, toEqual: true, timeout: 10))
    XCTAssertLessThan(passage.frame.minX, 40)
    capture("IPAD-E01-A05-plain-delivered-chapter-audit")
    try app.performAccessibilityAudit()
    closeReader(app)
  }

  @MainActor
  func testIPADE01A03EPUBPassageSaveAndResume() async throws {
    try await Self.resetProgress(fileID: 2)
    let (app, _) = openEPUB()
    let anchor = app.textFields["passageAnchor"]
    anchor.tap()
    anchor.typeText("epubcfi(/6/4[c2ref]!/4/2[p3],/1:0,/1:6)")
    app.buttons["Resolve passage"].tap()
    let resolved = app.staticTexts["resolvedPassage"]
    XCTAssertTrue(resolved.waitForExistence(timeout: 10))
    XCTAssertEqual(resolved.label, "Second")
    let passage = app.webViews.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@", "Second chapter begins here.")
    ).firstMatch
    XCTAssertTrue(passage.wait(for: \.isHittable, toEqual: true, timeout: 10))
    capture("IPAD-E01-A03-epub-second-chapter-before-save")
    let save = app.buttons["Save passage position"]
    XCTAssertTrue(save.waitForExistence(timeout: 5))
    save.tap()
    XCTAssertTrue(app.staticTexts["Position saved"].waitForExistence(timeout: 10))
    capture("IPAD-E01-A03-epub-second-chapter-saved")
    app.buttons["Close reader"].tap()
    app.buttons["readFile2"].tap()
    XCTAssertTrue(passage.wait(for: \.isHittable, toEqual: true, timeout: 20))
    capture("IPAD-E01-A03-epub-second-chapter-reopened")
    app.terminate()
    let (relaunched, _) = openEPUB(expectedText: "Second chapter begins here.")
    capture("IPAD-E01-A03-epub-second-chapter-relaunched")
    closeReader(relaunched)
  }

  @MainActor
  func testIPADE01A03EPUBSaveReplacesDevicePositionsAndPreservesNarration() async throws {
    try await Self.resetProgress(fileID: 2)
    let credentialsData = try await Self.request(
      "http://localhost:16482/api/v1/auth/login", method: "POST",
      body: [
        "username": "ipad-reader", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "EPUB companion position fixture",
      ])
    let credentials = try XCTUnwrap(
      JSONSerialization.jsonObject(with: credentialsData) as? [String: Any])
    let token = try XCTUnwrap(credentials["accessToken"] as? String)
    let refreshToken = try XCTUnwrap(credentials["refreshToken"] as? String)
    addTeardownBlock {
      try await Self.fault("snapshot-reset", method: "POST")
      _ = try await Self.request(
        "http://localhost:16482/api/v1/auth/logout", method: "POST",
        body: ["refreshToken": refreshToken])
    }
    let initialProgress = try JSONSerialization.data(withJSONObject: [
      "source": "text", "percentage": 25,
      "cfi": "epubcfi(/6/2[c1ref]!/4/2[p1],/1:0,/1:5)",
      "koboLocationSource": "OPS/c1.xhtml", "koboLocationType": "KoboSpan",
      "koboLocationValue": "kobo.1.1", "koboContentSourceProgressPercent": 25,
      "koreaderProgress": "/body/DocFragment[1]/body/p[1]/text().0",
      "positionSeconds": 18.5, "mediaOverlayFragment": "p4",
      "mediaOverlaySectionIndex": 1,
    ])
    _ = try await Self.request(
      "http://localhost:16482/api/v1/books/files/2/progress", method: "POST", token: token,
      encodedBody: initialProgress)
    let (app, _) = openEPUB(serverURL: "http://localhost:16485")
    let anchor = app.textFields["passageAnchor"]
    anchor.tap()
    anchor.typeText("epubcfi(/6/4[c2ref]!/4/2[p3],/1:0,/1:6)")
    app.buttons["Resolve passage"].tap()
    XCTAssertTrue(app.staticTexts["resolvedPassage"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.staticTexts["resolvedPassage"].label, "Second")
    try await Self.fault("write-arm", method: "POST")
    app.buttons["Save passage position"].tap()
    try await Self.fault("held")
    capture("IPAD-E01-A03-epub-progress-write-held")
    _ = try await Self.request(
      "http://localhost:16482/api/v1/books/files/2/progress", method: "POST", token: token,
      encodedBody: JSONSerialization.data(withJSONObject: [
        "source": "narration", "percentage": 30, "positionSeconds": 20.5,
        "mediaOverlayFragment": "p5", "mediaOverlaySectionIndex": 1,
      ]))
    try await Self.fault("release", method: "POST")
    XCTAssertTrue(app.staticTexts["Position saved"].waitForExistence(timeout: 10))
    capture("IPAD-E01-A03-epub-companion-positions-saved")
    let progressData = try await Self.request(
      "http://localhost:16482/api/v1/books/files/2/progress", token: token)
    let progress = try XCTUnwrap(JSONSerialization.jsonObject(with: progressData) as? [String: Any])
    let attachment = XCTAttachment(data: progressData, uniformTypeIdentifier: "public.json")
    attachment.name = "IPAD-E01-A03-epub-companion-positions-public-progress"
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTAssertEqual(progress["cfi"] as? String, "epubcfi(/6/4[c2ref]!/4/2[p3],/1:0,/1:6)")
    for field in [
      "koboLocationSource", "koboLocationType", "koboLocationValue",
      "koboContentSourceProgressPercent", "koreaderProgress",
    ] {
      XCTAssertTrue(
        progress[field] is NSNull, "Obsolete \(field) must not accompany the new passage.")
    }
    XCTAssertEqual(progress["positionSeconds"] as? Double, 20.5)
    XCTAssertEqual(progress["mediaOverlayFragment"] as? String, "p5")
    XCTAssertEqual(progress["mediaOverlaySectionIndex"] as? Int, 1)
    XCTAssertEqual(progress["narrationPercentage"] as? Double, 30)
    closeReader(app)
  }

  @MainActor
  private func openEPUB(
    expectedText: String = "Alpha 😀 cafe\u{301} omega.", serverURL: String? = nil
  ) -> (
    XCUIApplication, XCUIElement
  ) {
    let app = connectAndSignIn(serverURL: serverURL)
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    let search = app.searchFields.firstMatch
    search.tap()
    search.typeText("Native renderer proof\n")
    let book = app.buttons["Native renderer proof"]
    XCTAssertTrue(book.waitForExistence(timeout: 10))
    book.tap()
    capture("IPAD-E01-A04-proof-epub-before-reader")
    let read = app.buttons["readFile2"]
    XCTAssertTrue(read.waitForExistence(timeout: 5))
    read.tap()
    let passage = app.webViews.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@", expectedText)
    ).firstMatch
    let hasPassage = passage.wait(for: \.isHittable, toEqual: true, timeout: 20)
    capture("IPAD-E01-A04-proof-epub-open-outcome")
    XCTAssertTrue(hasPassage)
    capture("IPAD-E01-A04-proof-epub-first-passage")
    return (app, passage)
  }

  @MainActor
  private func closeReader(_ app: XCUIApplication) {
    XCUIDevice.shared.orientation = .portrait
    app.buttons["Close reader"].tap()
    app.buttons["Done"].tap()
    app.buttons["signOut"].tap()
    XCTAssertTrue(app.buttons["connectServer"].waitForExistence(timeout: 10))
  }

  @MainActor
  private func capturePassage(_ passage: XCUIElement, name: String) throws -> Int {
    let screenshot = passage.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    let image = try XCTUnwrap(screenshot.image.cgImage)
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let count = try pixels.withUnsafeMutableBytes { buffer in
      let context = try XCTUnwrap(
        CGContext(
          data: buffer.baseAddress, width: image.width, height: image.height,
          bitsPerComponent: 8, bytesPerRow: image.width * 4,
          space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue))
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return stride(from: 0, to: buffer.count, by: 4).filter { offset in
        Int(buffer[offset + 2]) > Int(buffer[offset]) + 15
          && Int(buffer[offset + 2]) > Int(buffer[offset + 1]) + 5
      }.count
    }
    let measurements = XCTAttachment(
      string: "{\"bluePixels\":\(count),\"width\":\(image.width),\"height\":\(image.height)}")
    measurements.name = "\(name)-pixels"
    measurements.lifetime = .keepAlways
    add(measurements)
    return count
  }
}
