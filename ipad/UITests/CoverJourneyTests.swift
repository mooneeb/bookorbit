import ImageIO
import UIKit
import XCTest

final class CoverJourneyTests: XCTestCase {
  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
  }

  override func tearDownWithError() throws {
    if let testRun, testRun.failureCount > 0 { capture("failure-\(name)") }
    try super.tearDownWithError()
  }

  @MainActor
  func testIPADE01A02UploadReopenAndRevertEbookCover() async throws {
    let login = try await request(
      "auth/login", method: "POST",
      body: [
        "username": "ipad-editor", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "Cover fixture control",
      ])
    let credentials = try XCTUnwrap(JSONSerialization.jsonObject(with: login) as? [String: Any])
    let token = try XCTUnwrap(credentials["accessToken"] as? String)
    _ = try await request(
      "books/6/metadata-and-locks", method: "PATCH", token: token,
      body: ["metadata": [:], "lockedFields": []])
    for medium in ["ebook", "audio"] {
      _ = try await request("books/6/cover?medium=\(medium)", method: "DELETE", token: token)
    }
    let originalData = try await request("books/6", token: token)
    let original = try XCTUnwrap(JSONSerialization.jsonObject(with: originalData) as? [String: Any])
    XCTAssertEqual(Set(original["coverMedia"] as? [String] ?? []), Set(["ebook", "audio"]))
    let originalSlots = try XCTUnwrap(original["covers"] as? [String: Any])
    let originalAudio = try XCTUnwrap(originalSlots["audio"] as? NSDictionary)
    let audioBytes = try await request("books/6/cover?medium=audio&strict=true", token: token)
    assertImage(audioBytes, width: 512, height: 512, color: [30, 150, 78])
    let ebookBytes = try await request("books/6/cover?medium=ebook&strict=true", token: token)
    assertImage(ebookBytes, width: 512, height: 768, color: [180, 52, 48])

    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    if !app.textFields["serverURL"].waitForExistence(timeout: 5) {
      if app.buttons["signOut"].exists { app.buttons["signOut"].tap() }
      if app.buttons["Change server"].exists { app.buttons["Change server"].tap() }
    }
    XCTAssertTrue(app.textFields["serverURL"].waitForExistence(timeout: 10))
    let serverURL = app.textFields["serverURL"]
    if (serverURL.value as? String) != "http://localhost:16482" {
      serverURL.tap()
      serverURL.typeText(
        String(
          repeating: XCUIKeyboardKey.delete.rawValue,
          count: (serverURL.value as? String ?? "").count))
      serverURL.typeText("http://localhost:16482")
    }
    app.buttons["connectServer"].tap()
    XCTAssertTrue(app.textFields["username"].waitForExistence(timeout: 10))
    app.textFields["username"].tap()
    app.textFields["username"].typeText("ipad-editor")
    app.secureTextFields["password"].tap()
    app.secureTextFields["password"].typeText("IpadFixture123")
    app.buttons["signIn"].tap()
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    let search = app.searchFields.firstMatch
    let book = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Library book 00005")
    ).firstMatch
    search.tap()
    search.typeText("Library book 00005\n")
    XCTAssertTrue(app.staticTexts["1 book"].waitForExistence(timeout: 10))
    book.tap()
    let edit = app.buttons["editCovers"]
    XCTAssertTrue(edit.waitForExistence(timeout: 10))
    edit.tap()
    XCTAssertTrue(app.staticTexts["Ebook cover"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Audio cover"].exists)
    XCTAssertEqual(app.staticTexts.matching(identifier: "Extracted").count, 2)
    XCTAssertTrue(app.images["ebookCoverImage"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.images["audioCoverImage"].waitForExistence(timeout: 10))
    capture("IPAD-E01-A02-cover-original")
    app.buttons["chooseEbookCover"].tap()
    let photo = coverFixturePhoto(in: app, year: "2030")
    XCTAssertTrue(photo.waitForExistence(timeout: 10))
    capture("IPAD-E01-A02-cover-photo-picker")
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = "IPAD-E01-A02-photo-picker-public-hierarchy"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
    photo.tap()
    XCTAssertTrue(app.staticTexts["Selected image: 640 × 960"].waitForExistence(timeout: 10))
    capture("IPAD-E01-A02-cover-staged")
    let staged = try await request("books/6", token: token)
    let stagedRecord = try XCTUnwrap(JSONSerialization.jsonObject(with: staged) as? NSDictionary)
    XCTAssertEqual(stagedRecord["covers"] as? NSDictionary, originalSlots as NSDictionary)
    XCTAssertEqual(stagedRecord["coverVersion"] as? String, original["coverVersion"] as? String)
    app.buttons["saveEbookCover"].tap()
    XCTAssertTrue(app.staticTexts["Ebook cover saved."].waitForExistence(timeout: 15))
    let savedData = try await request("books/6", token: token)
    let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: savedData) as? [String: Any])
    let savedSlots = try XCTUnwrap(saved["covers"] as? [String: Any])
    let savedEbook = try XCTUnwrap(savedSlots["ebook"] as? [String: Any])
    XCTAssertEqual(savedEbook["source"] as? String, "custom")
    XCTAssertEqual(savedEbook["width"] as? Int, 640)
    XCTAssertEqual(savedEbook["height"] as? Int, 960)
    XCTAssertNotEqual(saved["coverVersion"] as? String, original["coverVersion"] as? String)
    XCTAssertEqual(savedSlots["audio"] as? NSDictionary, originalAudio)
    let savedAudioBytes = try await request("books/6/cover?medium=audio&strict=true", token: token)
    XCTAssertEqual(savedAudioBytes, audioBytes)
    let chosenBytes = try await request("books/6/cover?medium=ebook&strict=true", token: token)
    assertImage(chosenBytes, width: 640, height: 960, color: [48, 112, 192])
    capture("IPAD-E01-A02-cover-saved")
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    search.tap()
    search.typeText("Library book 00005\n")
    XCTAssertTrue(app.staticTexts["1 book"].waitForExistence(timeout: 10))
    book.tap()
    XCTAssertTrue(edit.waitForExistence(timeout: 10))
    edit.tap()
    XCTAssertTrue(app.staticTexts["Custom"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.images["ebookCoverImage"].waitForExistence(timeout: 10))
    capture("IPAD-E01-A02-cover-reopened")
    app.buttons["revertEbookCover"].tap()
    let revert = app.alerts.buttons["Revert"]
    XCTAssertTrue(revert.waitForExistence(timeout: 5))
    revert.tap()
    XCTAssertTrue(app.staticTexts["Ebook cover reverted."].waitForExistence(timeout: 15))
    let revertedData = try await request("books/6", token: token)
    let reverted = try XCTUnwrap(JSONSerialization.jsonObject(with: revertedData) as? [String: Any])
    let revertedSlots = try XCTUnwrap(reverted["covers"] as? [String: Any])
    XCTAssertEqual((revertedSlots["ebook"] as? [String: Any])?["source"] as? String, "extracted")
    XCTAssertNotEqual(reverted["coverVersion"] as? String, saved["coverVersion"] as? String)
    XCTAssertEqual(revertedSlots["audio"] as? NSDictionary, originalAudio)
    let revertedAudioBytes = try await request(
      "books/6/cover?medium=audio&strict=true", token: token)
    let revertedEbookBytes = try await request(
      "books/6/cover?medium=ebook&strict=true", token: token)
    XCTAssertEqual(revertedAudioBytes, audioBytes)
    XCTAssertEqual(revertedEbookBytes, ebookBytes)
    capture("IPAD-E01-A02-cover-reverted")
    let attachment = XCTAttachment(data: revertedData, uniformTypeIdentifier: "public.json")
    attachment.name = "IPAD-E01-A02-cover-reverted-public-record"
    attachment.lifetime = .keepAlways
    add(attachment)
    continueAfterFailure = true
    try app.performAccessibilityAudit()
    continueAfterFailure = false
    app.buttons["closeCoverEditor"].tap()
    XCTAssertTrue(edit.waitForExistence(timeout: 10))
    app.buttons["Done"].tap()
    app.buttons["signOut"].tap()
    _ = try await request(
      "auth/logout", method: "POST",
      body: ["refreshToken": try XCTUnwrap(credentials["refreshToken"] as? String)])
  }

  @MainActor
  func testIPADE01A02UploadPreservesOriginalResolutionAndTransparency() async throws {
    let login = try await request(
      "auth/login", method: "POST",
      body: [
        "username": "ipad-editor", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "Original cover fixture control",
      ])
    let credentials = try XCTUnwrap(JSONSerialization.jsonObject(with: login) as? [String: Any])
    let token = try XCTUnwrap(credentials["accessToken"] as? String)
    _ = try await request(
      "books/8/metadata-and-locks", method: "PATCH", token: token,
      body: ["metadata": [:], "lockedFields": []])
    for medium in ["ebook", "audio"] {
      _ = try await request("books/8/cover?medium=\(medium)", method: "DELETE", token: token)
    }
    let originalData = try await request("books/8", token: token)
    let original = try XCTUnwrap(JSONSerialization.jsonObject(with: originalData) as? [String: Any])
    let originalSlots = try XCTUnwrap(original["covers"] as? NSDictionary)
    let originalAudio = try await request("books/8/cover?medium=audio&strict=true", token: token)
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    if !app.textFields["serverURL"].waitForExistence(timeout: 5) {
      if app.buttons["signOut"].exists { app.buttons["signOut"].tap() }
      if app.buttons["Change server"].exists { app.buttons["Change server"].tap() }
    }
    XCTAssertTrue(app.textFields["serverURL"].waitForExistence(timeout: 10))
    if (app.textFields["serverURL"].value as? String) != "http://localhost:16482" {
      app.textFields["serverURL"].tap()
      let previous = app.textFields["serverURL"].value as? String ?? ""
      app.textFields["serverURL"].typeText(
        String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
      app.textFields["serverURL"].typeText("http://localhost:16482")
    }
    app.buttons["connectServer"].tap()
    XCTAssertTrue(app.textFields["username"].waitForExistence(timeout: 10))
    app.textFields["username"].tap()
    app.textFields["username"].typeText("ipad-editor")
    app.secureTextFields["password"].tap()
    app.secureTextFields["password"].typeText("IpadFixture123")
    app.buttons["signIn"].tap()
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    let search = app.searchFields.firstMatch
    let book = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Library book 00007")
    ).firstMatch
    search.tap()
    search.typeText("Library book 00007\n")
    XCTAssertTrue(app.staticTexts["1 book"].waitForExistence(timeout: 10))
    book.tap()
    XCTAssertTrue(app.buttons["editCovers"].waitForExistence(timeout: 10))
    app.buttons["editCovers"].tap()
    XCTAssertTrue(app.images["ebookCoverImage"].waitForExistence(timeout: 10))
    app.buttons["chooseEbookCover"].tap()
    let photo = coverFixturePhoto(in: app, year: "2031")
    XCTAssertTrue(photo.waitForExistence(timeout: 10))
    capture("IPAD-E01-A02-original-image-picker")
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = "IPAD-E01-A02-original-picker-public-hierarchy"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
    photo.tap()
    XCTAssertTrue(app.staticTexts["Selected image: 2,400 × 3,600"].waitForExistence(timeout: 10))
    capture("IPAD-E01-A02-original-image-staged")
    let stagedData = try await request("books/8", token: token)
    let staged = try XCTUnwrap(JSONSerialization.jsonObject(with: stagedData) as? NSDictionary)
    XCTAssertEqual(staged["covers"] as? NSDictionary, originalSlots)
    XCTAssertEqual(staged["coverVersion"] as? String, original["coverVersion"] as? String)
    app.buttons["saveEbookCover"].tap()
    XCTAssertTrue(app.staticTexts["Ebook cover saved."].waitForExistence(timeout: 15))
    let savedData = try await request("books/8", token: token)
    let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: savedData) as? [String: Any])
    let savedSlots = try XCTUnwrap(saved["covers"] as? NSDictionary)
    let ebook = try XCTUnwrap(savedSlots["ebook"] as? NSDictionary)
    XCTAssertEqual(ebook["source"] as? String, "custom")
    XCTAssertEqual(ebook["width"] as? Int, 2400)
    XCTAssertEqual(ebook["height"] as? Int, 3600)
    XCTAssertEqual(savedSlots["audio"] as? NSDictionary, originalSlots["audio"] as? NSDictionary)
    XCTAssertNotEqual(saved["coverVersion"] as? String, original["coverVersion"] as? String)
    let delivered = try await request("books/8/cover?medium=ebook&strict=true", token: token)
    assertImage(delivered, width: 2400, height: 3600, color: [144, 64, 160], x: 200)
    let source = try XCTUnwrap(CGImageSourceCreateWithData(delivered as CFData, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let sample = try XCTUnwrap(image.cropping(to: CGRect(x: 10, y: 10, width: 1, height: 1)))
    var pixel = [UInt8](repeating: 0, count: 4)
    try pixel.withUnsafeMutableBytes { buffer in
      let context = try XCTUnwrap(
        CGContext(
          data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
      XCTAssertEqual(buffer[3], 0, "The delivered original must preserve transparency")
    }
    let savedAudio = try await request("books/8/cover?medium=audio&strict=true", token: token)
    XCTAssertEqual(savedAudio, originalAudio)
    capture("IPAD-E01-A02-original-image-saved")
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    search.tap()
    search.typeText("Library book 00007\n")
    XCTAssertTrue(app.staticTexts["1 book"].waitForExistence(timeout: 10))
    book.tap()
    XCTAssertTrue(app.buttons["editCovers"].waitForExistence(timeout: 10))
    app.buttons["editCovers"].tap()
    XCTAssertTrue(app.images["ebookCoverImage"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Custom"].exists)
    XCTAssertTrue(app.staticTexts["2,400 × 3,600"].exists)
    capture("IPAD-E01-A02-original-image-reopened")
    continueAfterFailure = true
    try app.performAccessibilityAudit()
    continueAfterFailure = false
    app.buttons["closeCoverEditor"].tap()
    XCTAssertTrue(app.buttons["editCovers"].waitForExistence(timeout: 10))
    app.buttons["Done"].tap()
    app.buttons["signOut"].tap()
    _ = try await request(
      "auth/logout", method: "POST",
      body: ["refreshToken": try XCTUnwrap(credentials["refreshToken"] as? String)])
  }

  @MainActor
  func testIPADE01A02ConcurrentCoverLockRetainsSelectionAndReloadsLocks() async throws {
    let login = try await request(
      "auth/login", method: "POST",
      body: [
        "username": "ipad-editor", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "Concurrent cover fixture control",
      ])
    let credentials = try XCTUnwrap(JSONSerialization.jsonObject(with: login) as? [String: Any])
    let token = try XCTUnwrap(credentials["accessToken"] as? String)
    _ = try await request(
      "books/6/metadata-and-locks", method: "PATCH", token: token,
      body: ["metadata": [:], "lockedFields": []])
    _ = try await request("books/6/cover?medium=ebook", method: "DELETE", token: token)
    let original = try await request("books/6/cover?medium=ebook&strict=true", token: token)
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    if !app.textFields["serverURL"].waitForExistence(timeout: 5) {
      if app.buttons["signOut"].exists { app.buttons["signOut"].tap() }
      if app.buttons["Change server"].exists { app.buttons["Change server"].tap() }
    }
    XCTAssertTrue(app.textFields["serverURL"].waitForExistence(timeout: 10))
    if (app.textFields["serverURL"].value as? String) != "http://localhost:16482" {
      app.textFields["serverURL"].tap()
      let previous = app.textFields["serverURL"].value as? String ?? ""
      app.textFields["serverURL"].typeText(
        String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
      app.textFields["serverURL"].typeText("http://localhost:16482")
    }
    app.buttons["connectServer"].tap()
    XCTAssertTrue(app.textFields["username"].waitForExistence(timeout: 10))
    app.textFields["username"].tap()
    app.textFields["username"].typeText("ipad-editor")
    app.secureTextFields["password"].tap()
    app.secureTextFields["password"].typeText("IpadFixture123")
    app.buttons["signIn"].tap()
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    app.searchFields.firstMatch.tap()
    app.searchFields.firstMatch.typeText("Library book 00005\n")
    XCTAssertTrue(app.staticTexts["1 book"].waitForExistence(timeout: 10))
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Library book 00005"))
      .firstMatch.tap()
    XCTAssertTrue(app.buttons["editCovers"].waitForExistence(timeout: 10))
    app.buttons["editCovers"].tap()
    XCTAssertTrue(app.images["ebookCoverImage"].waitForExistence(timeout: 10))
    app.buttons["chooseEbookCover"].tap()
    let photo = coverFixturePhoto(in: app, year: "2030")
    XCTAssertTrue(photo.waitForExistence(timeout: 10))
    photo.tap()
    XCTAssertTrue(app.staticTexts["Selected image: 640 × 960"].waitForExistence(timeout: 10))
    _ = try await request(
      "books/6/metadata-and-locks", method: "PATCH", token: token,
      body: ["metadata": [:], "lockedFields": ["cover"]])
    app.buttons["saveEbookCover"].tap()
    XCTAssertTrue(
      app.staticTexts["This cover is locked. Unlock it in metadata before editing."]
        .waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Selected image: 640 × 960"].exists)
    XCTAssertFalse(app.buttons["saveEbookCover"].isEnabled)
    XCTAssertFalse(app.buttons["chooseEbookCover"].isEnabled)
    XCTAssertTrue(app.buttons["chooseAudioCover"].isEnabled)
    capture("IPAD-E01-A02-concurrent-cover-lock")
    let denied = try await request("books/6/cover?medium=ebook&strict=true", token: token)
    XCTAssertEqual(denied, original)
    app.buttons["Reload cover"].tap()
    XCTAssertTrue(
      app.staticTexts["This cover is locked. Unlock it in metadata before editing."].exists)
    XCTAssertFalse(app.buttons["saveEbookCover"].isEnabled)
    XCTAssertTrue(app.staticTexts["Selected image: 640 × 960"].exists)
    _ = try await request(
      "books/6/metadata-and-locks", method: "PATCH", token: token,
      body: ["metadata": [:], "lockedFields": []])
    app.buttons["Reload cover"].tap()
    let enabled = NSPredicate(format: "enabled == true")
    let recovered = expectation(for: enabled, evaluatedWith: app.buttons["saveEbookCover"])
    await fulfillment(of: [recovered], timeout: 10)
    XCTAssertTrue(app.staticTexts["Selected image: 640 × 960"].exists)
    XCTAssertTrue(app.buttons["chooseEbookCover"].isEnabled)
    capture("IPAD-E01-A02-concurrent-cover-unlocked-selection-kept")
    app.buttons["saveEbookCover"].tap()
    XCTAssertTrue(app.staticTexts["Ebook cover saved."].waitForExistence(timeout: 15))
    let delivered = try await request("books/6/cover?medium=ebook&strict=true", token: token)
    assertImage(delivered, width: 640, height: 960, color: [48, 112, 192])
    capture("IPAD-E01-A02-concurrent-cover-recovered-save")
    continueAfterFailure = true
    try app.performAccessibilityAudit()
    continueAfterFailure = false
    app.buttons["closeCoverEditor"].tap()
    XCTAssertTrue(app.buttons["editCovers"].waitForExistence(timeout: 10))
    app.buttons["Done"].tap()
    app.buttons["signOut"].tap()
    _ = try await request("books/6/cover?medium=ebook", method: "DELETE", token: token)
    _ = try await request(
      "auth/logout", method: "POST",
      body: ["refreshToken": try XCTUnwrap(credentials["refreshToken"] as? String)])
  }

  @MainActor
  func testIPADE01A02DelayedOldCoverCannotReplaceSavedPreview() async throws {
    let login = try await request(
      "auth/login", method: "POST",
      body: [
        "username": "ipad-editor", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "Delayed cover fixture control",
      ])
    let credentials = try XCTUnwrap(JSONSerialization.jsonObject(with: login) as? [String: Any])
    let token = try XCTUnwrap(credentials["accessToken"] as? String)
    _ = try await request(
      "books/6/metadata-and-locks", method: "PATCH", token: token,
      body: ["metadata": [:], "lockedFields": []])
    _ = try await request("books/6/cover?medium=ebook", method: "DELETE", token: token)
    let app = XCUIApplication()
    try await openCoverBook(app, server: "http://localhost:16485")
    try await coverFault("arm")
    app.buttons["editCovers"].tap()
    try await coverFault("held", method: "GET")
    app.buttons["chooseEbookCover"].tap()
    let photo = coverFixturePhoto(in: app, year: "2030")
    XCTAssertTrue(photo.waitForExistence(timeout: 10))
    photo.tap()
    XCTAssertTrue(app.staticTexts["Selected image: 640 × 960"].waitForExistence(timeout: 10))
    try await coverFault("held", method: "GET")
    app.buttons["saveEbookCover"].tap()
    XCTAssertTrue(app.staticTexts["Ebook cover saved."].waitForExistence(timeout: 10))
    assertRenderedCover(app, color: [48, 112, 192])
    capture("IPAD-E01-A02-saved-cover-before-old-response")
    try await coverFault("release")
    XCTAssertTrue(app.staticTexts["Custom"].exists)
    XCTAssertTrue(app.staticTexts["640 × 960"].exists)
    assertRenderedCover(app, color: [48, 112, 192])
    capture("IPAD-E01-A02-saved-cover-after-old-response")
    let delivered = try await request("books/6/cover?medium=ebook&strict=true", token: token)
    assertImage(delivered, width: 640, height: 960, color: [48, 112, 192])
    continueAfterFailure = true
    try app.performAccessibilityAudit()
    continueAfterFailure = false
    app.buttons["closeCoverEditor"].tap()
    XCTAssertTrue(app.buttons["editCovers"].waitForExistence(timeout: 10))
    app.buttons["Done"].tap()
    app.buttons["signOut"].tap()
    _ = try await request("books/6/cover?medium=ebook", method: "DELETE", token: token)
    _ = try await request(
      "auth/logout", method: "POST",
      body: ["refreshToken": try XCTUnwrap(credentials["refreshToken"] as? String)])
  }

  @MainActor
  func testIPADE01A02CoverFailuresRetainSelectionAndRequireAuthoritativeLocks() async throws {
    let login = try await request(
      "auth/login", method: "POST",
      body: [
        "username": "ipad-editor", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "Cover failure fixture control",
      ])
    let credentials = try XCTUnwrap(JSONSerialization.jsonObject(with: login) as? [String: Any])
    let token = try XCTUnwrap(credentials["accessToken"] as? String)
    _ = try await request(
      "books/6/metadata-and-locks", method: "PATCH", token: token,
      body: ["metadata": [:], "lockedFields": []])
    _ = try await request("books/6/cover?medium=ebook", method: "DELETE", token: token)
    let original = try await request("books/6/cover?medium=ebook&strict=true", token: token)
    let audio = try await request("books/6/cover?medium=audio&strict=true", token: token)
    let app = XCUIApplication()
    try await openCoverBook(app, server: "http://localhost:16485")
    app.buttons["editCovers"].tap()
    XCTAssertTrue(app.images["ebookCoverImage"].waitForExistence(timeout: 10))
    app.buttons["chooseEbookCover"].tap()
    let photo = coverFixturePhoto(in: app, year: "2030")
    XCTAssertTrue(photo.waitForExistence(timeout: 10))
    photo.tap()
    XCTAssertTrue(app.staticTexts["Selected image: 640 × 960"].waitForExistence(timeout: 10))
    try await coverFault("upload-fail")
    app.buttons["saveEbookCover"].tap()
    XCTAssertTrue(
      app.staticTexts["The server could not complete the request (503). Try again."]
        .waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Selected image: 640 × 960"].exists)
    XCTAssertTrue(app.buttons["saveEbookCover"].isEnabled)
    let denied = try await request("books/6/cover?medium=ebook&strict=true", token: token)
    XCTAssertEqual(denied, original)
    capture("IPAD-E01-A02-cover-upload-unavailable-selection-kept")
    try await coverFault("upload-recover")
    try await coverFault("snapshot-fail")
    _ = try await request(
      "books/6/metadata-and-locks", method: "PATCH", token: token,
      body: ["metadata": [:], "lockedFields": ["cover"]])
    app.buttons["saveEbookCover"].tap()
    XCTAssertTrue(
      app.staticTexts[
        "Cover information could not be refreshed. Your selection is kept. Reload before saving."
      ].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Selected image: 640 × 960"].exists)
    XCTAssertFalse(app.buttons["saveEbookCover"].isEnabled)
    XCTAssertFalse(app.buttons["chooseEbookCover"].isEnabled)
    capture("IPAD-E01-A02-cover-conflict-lock-information-unavailable")
    continueAfterFailure = true
    try app.performAccessibilityAudit()
    continueAfterFailure = false
    try await coverFault("snapshot-recover")
    app.buttons["Reload cover"].tap()
    XCTAssertTrue(
      app.staticTexts["This cover is locked. Unlock it in metadata before editing."]
        .waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["saveEbookCover"].isEnabled)
    _ = try await request(
      "books/6/metadata-and-locks", method: "PATCH", token: token,
      body: ["metadata": [:], "lockedFields": []])
    app.buttons["Reload cover"].tap()
    XCTAssertTrue(app.buttons["saveEbookCover"].wait(for: \.isEnabled, toEqual: true, timeout: 10))
    app.buttons["saveEbookCover"].tap()
    XCTAssertTrue(app.staticTexts["Ebook cover saved."].waitForExistence(timeout: 10))
    let delivered = try await request("books/6/cover?medium=ebook&strict=true", token: token)
    assertImage(delivered, width: 640, height: 960, color: [48, 112, 192])
    let savedAudio = try await request("books/6/cover?medium=audio&strict=true", token: token)
    XCTAssertEqual(savedAudio, audio)
    capture("IPAD-E01-A02-cover-failure-recovered-save")
    app.buttons["closeCoverEditor"].tap()
    XCTAssertTrue(app.buttons["editCovers"].waitForExistence(timeout: 10))
    app.buttons["Done"].tap()
    app.buttons["signOut"].tap()
    _ = try await request("books/6/cover?medium=ebook", method: "DELETE", token: token)
    _ = try await request(
      "auth/logout", method: "POST",
      body: ["refreshToken": try XCTUnwrap(credentials["refreshToken"] as? String)])
  }

  @MainActor
  private func coverFixturePhoto(in app: XCUIApplication, year: String) -> XCUIElement {
    let photo = app.images.matching(
      NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Photo, ", year)
    ).firstMatch
    let picker = app.scrollViews["photosView_content_scroll_view"]
    XCTAssertTrue(picker.waitForExistence(timeout: 10))
    for _ in 0..<20 {
      if photo.exists {
        if picker.frame.contains(photo.frame) && photo.isHittable { return photo }
        if photo.frame.minY < picker.frame.minY {
          picker.swipeDown(velocity: .slow)
          continue
        }
      }
      picker.swipeUp(velocity: .slow)
    }
    XCTFail("The cover fixture photo is not fully visible in the picker.")
    return photo
  }

  @MainActor
  private func openCoverBook(_ app: XCUIApplication, server: String) async throws {
    XCUIDevice.shared.orientation = .portrait
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    let field = app.textFields["serverURL"]
    if !field.waitForExistence(timeout: 5) {
      if app.buttons["signOut"].exists { app.buttons["signOut"].tap() }
      if app.buttons["Change server"].exists { app.buttons["Change server"].tap() }
    }
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    field.tap()
    let previous = field.value as? String ?? ""
    if previous != server {
      field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
      field.typeText(server)
    }
    XCTAssertEqual(field.value as? String, server)
    app.buttons["connectServer"].tap()
    XCTAssertTrue(app.textFields["username"].waitForExistence(timeout: 10))
    app.textFields["username"].tap()
    app.textFields["username"].typeText("ipad-editor")
    app.secureTextFields["password"].tap()
    app.secureTextFields["password"].typeText("IpadFixture123")
    app.buttons["signIn"].tap()
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    app.searchFields.firstMatch.tap()
    app.searchFields.firstMatch.typeText("Library book 00005\n")
    XCTAssertTrue(app.staticTexts["1 book"].waitForExistence(timeout: 10))
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Library book 00005"))
      .firstMatch.tap()
    XCTAssertTrue(app.buttons["editCovers"].waitForExistence(timeout: 10))
  }

  @MainActor
  private func coverFault(_ operation: String, method: String = "POST") async throws {
    var control = URLRequest(
      url: URL(string: "http://localhost:16485/__faults/cover/\(operation)")!,
      cachePolicy: .reloadIgnoringLocalCacheData)
    control.httpMethod = method
    control.timeoutInterval = 15
    let (_, response) = try await URLSession.shared.data(for: control)
    XCTAssertTrue((200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0))
  }

  @MainActor
  private func assertRenderedCover(_ app: XCUIApplication, color: [Int]) {
    guard let image = app.images["ebookCoverImage"].screenshot().image.cgImage,
      let sample = image.cropping(to: CGRect(x: image.width / 2, y: 10, width: 1, height: 1))
    else {
      XCTFail("The visible cover must render")
      return
    }
    var pixel = [UInt8](repeating: 0, count: 4)
    pixel.withUnsafeMutableBytes { buffer in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else {
        XCTFail("The visible cover pixel must decode")
        return
      }
      context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
      for channel in 0..<3 {
        XCTAssertLessThanOrEqual(abs(Int(buffer[channel]) - color[channel]), 10)
      }
    }
  }

  @MainActor
  private func request(
    _ path: String, method: String = "GET", token: String? = nil, body: [String: Any]? = nil
  ) async throws -> Data {
    var request = URLRequest(
      url: URL(string: "http://127.0.0.1:16482/api/v1/\(path)")!,
      cachePolicy: .reloadIgnoringLocalCacheData)
    request.httpMethod = method
    request.timeoutInterval = 15
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    XCTAssertTrue((200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0))
    return data
  }

  private func assertImage(
    _ data: Data, width: Int, height: Int, color: [Int], x: Int = 10,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      XCTFail("Delivered cover must decode as an image", file: file, line: line)
      return
    }
    XCTAssertEqual(image.width, width, file: file, line: line)
    XCTAssertEqual(image.height, height, file: file, line: line)
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes { buffer in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else {
        XCTFail("Delivered cover must render", file: file, line: line)
        return
      }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      let offset = (10 * width + x) * 4
      for channel in 0..<3 {
        XCTAssertLessThanOrEqual(
          abs(Int(buffer[offset + channel]) - color[channel]), 10, file: file, line: line)
      }
    }
  }

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
