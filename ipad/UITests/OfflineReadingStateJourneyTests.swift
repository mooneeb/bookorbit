import CryptoKit
import Foundation
import XCTest

final class OfflineReadingStateJourneyTests: XCTestCase {
  private let httpSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 20
    configuration.waitsForConnectivity = false
    return URLSession(configuration: configuration)
  }()

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
  }

  override func tearDown() async throws {
    if let testRun, testRun.failureCount > 0 {
      let data = await MainActor.run { XCUIScreen.main.screenshot().pngRepresentation }
      attach(data, name: "IPAD-E02-A04-reading-state-failure-\(name)", type: "public.png")
    }
    try await super.tearDown()
  }

  @MainActor
  func testIPADE02A04PDFPageAndBookmarkCreationDeletionSurviveOfflineRestart() async throws {
    try await exerciseFixedPages(bookID: 1, format: "pdf", nextPage: "pdfNextPage", kind: "PDF")
  }

  @MainActor
  func testIPADE02A04ComicPageAndBookmarkCreationDeletionSurviveOfflineRestart() async throws {
    try await exerciseFixedPages(
      bookID: 10, format: "cbz", nextPage: "comicNextPage", kind: "Comic")
  }

  @MainActor
  func testIPADE02A04KnownPDFInkPublicationPreservesQueuedReadingStateAcrossRestart()
    async throws
  {
    try await fault("reset")
    let token = try await loginAPI()
    let book = try await bookDetails(bookID: 1, format: "pdf", token: token)
    _ = try await api("books/files/\(book.fileID)/progress", method: "DELETE", token: token)
    let title = "IPAD-E02-A04 publication page 2 \(UUID().uuidString)"
    let app = launchAndSignIn()
    openBookDetail(book, app: app)
    downloadSelectedFile(book.fileID, app: app)
    app.buttons["sourceRecovery"].tap()
    XCTAssertTrue(app.staticTexts["sourceRecoveryEmpty"].waitForExistence(timeout: 15))
    app.buttons["sourceRecoveryClose"].tap()
    let sourceData = try await api(
      "annotations/native/files/\(book.fileID)/source?bookId=\(book.bookID)&page=1", token: token)
    let source = try XCTUnwrap(JSONSerialization.jsonObject(with: sourceData) as? [String: Any])
    let originalRevision = try XCTUnwrap(source["sourceRevision"] as? String)
    let fingerprint = try XCTUnwrap(source["pageFingerprint"] as? String)
    let before = try await api("books/files/\(book.fileID)/serve", token: token)
    XCTAssertEqual(originalRevision, "sha256:\(checksum(before))")
    try await fault("offline")
    readFile(book.fileID, app: app)
    XCTAssertTrue(app.staticTexts["Page 1 of 3"].waitForExistence(timeout: 20))
    app.buttons["pdfNextPage"].tap()
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Position saved on this iPad"].waitForExistence(timeout: 15))
    openBookmarks(app)
    let field = app.descendants(matching: .any)["bookmarkTitle"].firstMatch
    XCTAssertTrue(field.wait(for: \.isHittable, toEqual: true, timeout: 10))
    replaceText(field, with: title)
    app.buttons["saveBookmark"].tap()
    XCTAssertTrue(
      app.staticTexts["Bookmark saved on this iPad. It will sync when connected."].waitForExistence(
        timeout: 15))
    capture("IPAD-E02-A04-PDF-page2-bookmark-queued-before-other-client-publication")
    app.terminate()
    let clientID = UUID().uuidString
    let publicationData = try await api(
      "annotations/native/operations", method: "POST", token: token,
      body: [
        "deviceId": "IPAD-E02-A04-other-authenticated-client",
        "operations": [
          [
            "operationId": UUID().uuidString, "clientId": clientID, "bookId": book.bookID,
            "baseVersion": 0, "action": "create",
            "payload": [
              "kind": "pdf_ink", "bookFileId": book.fileID, "text": "",
              "pdf": [
                "page": 1, "rect": ["x": 76, "y": 196, "width": 108, "height": 8],
                "rects": [],
              ],
              "drawing": [
                "format": "bookorbit-ink-v1",
                "strokes": [
                  [
                    "id": "IPAD-E02-A04-shared-publication-\(clientID)", "color": "#ff0000",
                    "width": 8, "points": [["x": 80, "y": 200], ["x": 180, "y": 200]],
                  ]
                ],
              ],
              "sourceRevision": originalRevision, "pageFingerprint": fingerprint,
            ],
          ]
        ],
      ])
    let response = try XCTUnwrap(
      JSONSerialization.jsonObject(with: publicationData) as? [String: Any])
    let result = try XCTUnwrap((response["results"] as? [[String: Any]])?.first)
    XCTAssertEqual(result["status"] as? String, "applied")
    let annotation = try XCTUnwrap(result["annotation"] as? [String: Any])
    let inkIdentity = try XCTUnwrap(annotation["clientId"] as? String)
    XCTAssertEqual(UUID(uuidString: inkIdentity), UUID(uuidString: clientID))
    XCTAssertEqual((annotation["pdf"] as? [String: Any])?["page"] as? Int, 1)
    let publication = try XCTUnwrap(result["publication"] as? [String: Any])
    XCTAssertEqual(publication["status"] as? String, "published")
    let newRevision = try XCTUnwrap(publication["sourceRevision"] as? String)
    let after = try await api("books/files/\(book.fileID)/serve", token: token)
    XCTAssertNotEqual(before, after)
    XCTAssertNotEqual(before.count, after.count)
    XCTAssertEqual(newRevision, "sha256:\(checksum(after))")
    let proofData = try await api(
      "annotations/native/files/\(book.fileID)/source?bookId=\(book.bookID)&page=1&sourceRevision=\(originalRevision)",
      token: token)
    let proof = try XCTUnwrap(JSONSerialization.jsonObject(with: proofData) as? [String: Any])
    XCTAssertEqual(proof["matchedSourceRevision"] as? String, originalRevision)
    XCTAssertEqual(proof["sourceRevision"] as? String, newRevision)
    XCTAssertEqual(proof["pageFingerprint"] as? String, fingerprint)
    attach(
      publicationData, name: "IPAD-E02-A04-other-client-canonical-publication", type: "public.json")
    attach(before, name: "IPAD-E02-A04-complete-PDF-before-publication", type: "com.adobe.pdf")
    attach(after, name: "IPAD-E02-A04-complete-PDF-after-publication", type: "com.adobe.pdf")
    app.launch()
    openOfflineBook(book, app: app)
    readFile(book.fileID, app: app)
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 20))
    openBookmarks(app)
    XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
    capture("IPAD-E02-A04-PDF-queued-page-and-bookmark-retained-during-publication")
    app.terminate()
    try await fault("online")
    app.launch()
    openOfflineBook(book, app: app)
    readFile(book.fileID, app: app)
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 25))
    XCTAssertTrue(app.images["pdfInkItem\(inkIdentity)"].waitForExistence(timeout: 20))
    XCTAssertEqual(app.images["pdfInkItem\(inkIdentity)"].label, "Ink item, page 2")
    XCTAssertTrue(app.buttons["pdfInkDraw"].isEnabled)
    XCTAssertFalse(app.staticTexts["pdfInkError"].exists)
    XCTAssertFalse(app.staticTexts["readerPositionConflict"].exists)
    openBookmarks(app)
    let saved = try await waitForBookmarks(bookID: book.bookID, fileID: book.fileID, token: token) {
      $0.filter { $0["title"] as? String == title }.count == 1
    }
    let bookmark = try XCTUnwrap(saved.first { $0["title"] as? String == title })
    let bookmarkID = try XCTUnwrap(bookmark["id"] as? Int)
    XCTAssertEqual(bookmark["pageNumber"] as? Int, 2)
    XCTAssertTrue(app.buttons["openBookmark\(bookmarkID)"].waitForExistence(timeout: 10))
    app.buttons["Done"].tap()
    XCUIDevice.shared.press(.home)
    app.activate()
    _ = try await waitForProgress(fileID: book.fileID, token: token, page: 2)
    capture("IPAD-E02-A04-PDF-known-publication-and-queued-reading-state-converged")
    app.buttons["Close reader"].tap()
    app.buttons["sourceRecovery"].tap()
    XCTAssertTrue(app.staticTexts["sourceRecoveryEmpty"].waitForExistence(timeout: 15))
    XCTAssertFalse(app.staticTexts["Source replaced"].exists)
    XCTAssertFalse(app.staticTexts["sourceRecoveryError"].exists)
    capture("IPAD-E02-A04-PDF-known-publication-has-no-false-source-recovery")
    app.buttons["sourceRecoveryClose"].tap()
    app.buttons["offlineResources"].tap()
    XCTAssertTrue(
      app.staticTexts["Verified ready for offline reading"].waitForExistence(timeout: 15))
    app.buttons["Done"].tap()
    try await fault("offline")
    app.terminate()
    app.launch()
    openOfflineBook(book, app: app)
    readFile(book.fileID, app: app)
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 25))
    XCTAssertTrue(app.images["pdfInkItem\(inkIdentity)"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.buttons["pdfInkDraw"].isEnabled)
    XCTAssertFalse(app.staticTexts["pdfInkError"].exists)
    openBookmarks(app)
    XCTAssertTrue(app.buttons["openBookmark\(bookmarkID)"].waitForExistence(timeout: 10))
    capture("IPAD-E02-A04-PDF-new-complete-source-and-current-anchors-readable-offline")
    try await fault("online")
    let retried = try await bookmarks(bookID: book.bookID, fileID: book.fileID, token: token)
    XCTAssertEqual(retried.filter { $0["title"] as? String == title }.count, 1)
    XCTAssertEqual(retried.first { $0["title"] as? String == title }?["id"] as? Int, bookmarkID)
  }

  @MainActor
  func testIPADE02A04CompleteEPUBAndRecordedReadAlongPlayAfterOfflineRestart() async throws {
    try await fault("reset")
    let token = try await loginAPI()
    let book = try await bookDetails(bookID: 2, format: "epub", token: token)
    _ = try await api("books/files/\(book.fileID)/progress", method: "DELETE", token: token)
    let app = launchAndSignIn()
    openBookDetail(book, app: app)
    downloadSelectedFile(book.fileID, app: app)
    let downloaded = try await traffic()
    try await fault("offline")
    app.terminate()
    app.launch()
    openOfflineBook(book, app: app)
    readFile(book.fileID, app: app)
    let first = app.webViews.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@", "Alpha 😀 cafe\u{301} omega.")
    ).firstMatch
    XCTAssertTrue(first.wait(for: \.isHittable, toEqual: true, timeout: 25))
    app.buttons["epubReaderTools"].tap()
    app.buttons["epubRecordedReadAlong"].tap()
    let start = app.buttons["recordedStartPassage"]
    XCTAssertTrue(start.wait(for: \.isEnabled, toEqual: true, timeout: 15))
    start.tap()
    let segment = app.staticTexts["recordedSegmentText"]
    XCTAssertTrue(segment.waitForExistence(timeout: 25))
    XCTAssertTrue(segment.label.contains("Alpha"))
    capture("IPAD-E02-A04-EPUB-first-recorded-passage-playing-offline")
    for text in [
      "First chapter ends here.", "Second chapter begins here.", "Second chapter ends here.",
    ] {
      let literal = NSPredicate(format: "label CONTAINS %@", text)
      XCTAssertTrue(
        app.staticTexts.matching(literal).firstMatch.waitForExistence(timeout: 15), text)
      XCTAssertTrue(segment.label.contains(text))
      XCTAssertFalse(app.staticTexts["recordedNarrationError"].exists)
    }
    XCTAssertTrue(
      app.buttons["recordedToggle"].wait(for: \.label, toEqual: "Play recording", timeout: 15))
    XCTAssertTrue(app.staticTexts["recordedSegmentTime"].label.hasPrefix("6.0 / 6.0"))
    XCTAssertFalse(app.staticTexts["recordedNarrationError"].exists)
    capture("IPAD-E02-A04-EPUB-all-four-recorded-passages-completed-offline")
    app.buttons["recordedCloseControls"].tap()
    let final = app.webViews.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@", "Second chapter ends here.")
    ).firstMatch
    XCTAssertTrue(final.wait(for: \.isHittable, toEqual: true, timeout: 10))
    XCTAssertFalse(app.staticTexts["epubReaderError"].exists)
    capture("IPAD-E02-A04-EPUB-final-publication-passage-visible-offline")
    let offlineTraffic = try await traffic()
    XCTAssertEqual(successfulBytes(Array(offlineTraffic.dropFirst(downloaded.count))), 0)
  }

  @MainActor
  func testIPADE02A04SelectedAudioPlaysCompletelyAfterRestartWithoutUnselectedPDFBytes()
    async throws
  {
    try await fault("reset")
    let token = try await loginAPI()
    let book = try await bookDetails(bookID: 8, format: "m4a", token: token)
    let unselected = try await bookDetails(bookID: 8, format: "pdf", token: token)
    let app = launchAndSignIn()
    openBookDetail(book, app: app)
    downloadSelectedFile(book.fileID, excluding: [unselected.fileID], app: app)
    let downloaded = try await traffic()
    assertNoUnselectedBody(fileID: unselected.fileID, traffic: downloaded)
    try await fault("offline")
    app.terminate()
    app.launch()
    openOfflineBook(book, app: app)
    readFile(book.fileID, app: app)
    let play = app.buttons["audiobookPlayPause"]
    XCTAssertTrue(play.wait(for: \.isEnabled, toEqual: true, timeout: 25))
    XCTAssertEqual(app.staticTexts["audiobookCurrentTrack"].label, "Track 1 of 1")
    XCTAssertEqual(app.staticTexts["audiobookPlaybackTime"].label, "0:00 / 0:01")
    capture("IPAD-E02-A04-Audio-selected-track-ready-after-offline-restart")
    play.tap()
    XCTAssertTrue(play.wait(for: \.label, toEqual: "Pause", timeout: 10))
    XCTAssertFalse(app.staticTexts["audiobookError"].exists)
    XCTAssertTrue(play.wait(for: \.label, toEqual: "Play", timeout: 15))
    XCTAssertTrue(app.staticTexts["audiobookPlaybackTime"].label.hasSuffix(" / 0:01"))
    capture("IPAD-E02-A04-Audio-complete-track-played-without-transport")
    let offlineTraffic = try await traffic()
    assertNoUnselectedBody(fileID: unselected.fileID, traffic: offlineTraffic)
    XCTAssertEqual(successfulBytes(Array(offlineTraffic.dropFirst(downloaded.count))), 0)
  }

  @MainActor
  func testIPADE02A04PDFResumeCandidatesAndOfflineChoiceSurviveTwoRestarts() async throws {
    try await fault("reset")
    let token = try await loginAPI()
    let book = try await bookDetails(bookID: 1, format: "pdf", token: token)
    _ = try await api("books/files/\(book.fileID)/progress", method: "DELETE", token: token)
    let app = launchAndSignIn()
    openBookDetail(book, app: app)
    downloadSelectedFile(book.fileID, app: app)
    readFile(book.fileID, app: app)
    XCTAssertTrue(app.staticTexts["Page 1 of 3"].waitForExistence(timeout: 20))
    let baseline = try await progress(fileID: book.fileID, token: token)
    try await fault("offline")
    app.buttons["pdfNextPage"].tap()
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Position saved on this iPad"].waitForExistence(timeout: 15))
    _ = try await api(
      "books/files/\(book.fileID)/progress", method: "POST", token: token,
      body: [
        "pageNumber": 3, "percentage": 100, "source": "text",
        "baseVersion": try XCTUnwrap(baseline["textVersion"] as? String),
      ])
    try await fault("online")
    app.terminate()
    app.launch()
    openOfflineBook(book, app: app)
    readFile(book.fileID, app: app)
    XCTAssertTrue(app.staticTexts["readerPositionConflict"].waitForExistence(timeout: 20))
    let local = app.buttons["readerPositionChooseLocal"]
    let remote = app.buttons["readerPositionChooseRemote"]
    XCTAssertTrue(local.label.contains("Page 2"))
    XCTAssertTrue(remote.label.contains("Page 3"))
    XCTAssertFalse(app.buttons["pdfNextPage"].isEnabled)
    capture("IPAD-E02-A04-PDF-conflicting-page2-page3-after-restart")
    try await fault("offline")
    XCTAssertTrue(local.wait(for: \.isEnabled, toEqual: true, timeout: 10))
    local.tap()
    XCTAssertTrue(
      app.staticTexts["Chosen position saved on this iPad."].waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].exists)
    capture("IPAD-E02-A04-PDF-resume-choice-saved-without-transport")
    app.terminate()
    app.launch()
    openOfflineBook(book, app: app)
    readFile(book.fileID, app: app)
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 20))
    XCTAssertTrue(app.staticTexts["readerPositionConflict"].exists)
    XCTAssertTrue(local.label.contains("Page 2"))
    XCTAssertTrue(remote.label.contains("Page 3"))
    capture("IPAD-E02-A04-PDF-chosen-local-page-and-both-candidates-after-second-restart")
    try await fault("online")
    local.tap()
    _ = try await waitForProgress(fileID: book.fileID, token: token, page: 2)
    XCTAssertTrue(
      app.staticTexts["readerPositionConflict"].wait(for: \.exists, toEqual: false, timeout: 15))
    app.terminate()
    app.launch()
    openOfflineBook(book, app: app)
    readFile(book.fileID, app: app)
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 20))
    XCTAssertFalse(app.staticTexts["readerPositionConflict"].exists)
    capture("IPAD-E02-A04-PDF-resume-choice-published-and-reopened")
  }

  @MainActor
  private func exerciseFixedPages(bookID: Int, format: String, nextPage: String, kind: String)
    async throws
  {
    try await fault("reset")
    let token = try await loginAPI()
    let book = try await bookDetails(bookID: bookID, format: format, token: token)
    _ = try await api("books/files/\(book.fileID)/progress", method: "DELETE", token: token)
    let title = "IPAD-E02-A04 \(kind) page 2 (\(profile))"
    let app = launchAndSignIn()
    openBookDetail(book, app: app)
    downloadSelectedFile(book.fileID, app: app)
    try await fault("offline")
    readFile(book.fileID, app: app)
    XCTAssertTrue(app.staticTexts["Page 1 of 3"].waitForExistence(timeout: 20))
    let next = app.buttons[nextPage]
    XCTAssertTrue(next.wait(for: \.isHittable, toEqual: true, timeout: 10))
    next.tap()
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Position saved on this iPad"].waitForExistence(timeout: 15))
    assertSecondPage(kind, app: app)
    next.tap()
    XCTAssertTrue(app.staticTexts["Page 3 of 3"].waitForExistence(timeout: 10))
    if kind == "PDF" {
      XCTAssertTrue(
        app.staticTexts.matching(
          NSPredicate(format: "label CONTAINS %@", "Orbit fixture: passage 3")
        ).firstMatch.wait(for: \.isHittable, toEqual: true, timeout: 10))
    } else {
      XCTAssertTrue(app.images["comicPage3"].waitForExistence(timeout: 10))
    }
    capture("IPAD-E02-A04-\(kind)-last-complete-page-readable-offline")
    app.buttons[kind == "PDF" ? "pdfPreviousPage" : "comicPreviousPage"].tap()
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Position saved on this iPad"].waitForExistence(timeout: 15))
    openBookmarks(app)
    let field = app.descendants(matching: .any)["bookmarkTitle"].firstMatch
    XCTAssertTrue(field.wait(for: \.isHittable, toEqual: true, timeout: 10))
    replaceText(field, with: title)
    let save = app.buttons["saveBookmark"]
    XCTAssertTrue(save.wait(for: \.isEnabled, toEqual: true, timeout: 10))
    save.tap()
    XCTAssertTrue(
      app.staticTexts["Bookmark saved on this iPad. It will sync when connected."].waitForExistence(
        timeout: 15))
    XCTAssertTrue(app.staticTexts[title].exists)
    capture("IPAD-E02-A04-\(kind)-offline-page2-bookmark-created")
    app.terminate()
    app.launch()
    openOfflineBook(book, app: app)
    readFile(book.fileID, app: app)
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 20))
    assertSecondPage(kind, app: app)
    openBookmarks(app)
    XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
    let local = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "openBookmark-")
    )
    .matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    XCTAssertTrue(local.exists)
    capture("IPAD-E02-A04-\(kind)-page-and-pending-bookmark-after-restart")
    try await fault("online")
    app.buttons["Done"].tap()
    XCUIDevice.shared.press(.home)
    app.activate()
    XCTAssertTrue(app.buttons["readerBookmarks"].waitForExistence(timeout: 20))
    openBookmarks(app)
    let saved = try await waitForBookmarks(bookID: book.bookID, fileID: book.fileID, token: token) {
      $0.filter { $0["title"] as? String == title }.count == 1
    }
    let bookmark = try XCTUnwrap(saved.first { $0["title"] as? String == title })
    let bookmarkID = try XCTUnwrap(bookmark["id"] as? Int)
    XCTAssertEqual(bookmark["pageNumber"] as? Int, 2)
    XCTAssertEqual(bookmark["fileId"] as? Int, book.fileID)
    XCTAssertTrue(app.buttons["openBookmark\(bookmarkID)"].waitForExistence(timeout: 10))
    let progress = try await waitForProgress(fileID: book.fileID, token: token, page: 2)
    XCTAssertEqual((progress["textVersion"] as? String)?.count, 64)
    capture("IPAD-E02-A04-\(kind)-reconnected-exactly-one-bookmark-and-page2")
    app.buttons["Done"].tap()
    openBookmarks(app)
    let retried = try await bookmarks(bookID: book.bookID, fileID: book.fileID, token: token)
    XCTAssertEqual(retried.filter { $0["title"] as? String == title }.count, 1)
    XCTAssertEqual(retried.first { $0["title"] as? String == title }?["id"] as? Int, bookmarkID)
    try await fault("offline")
    let remove = app.buttons["removeBookmark\(bookmarkID)"]
    XCTAssertTrue(remove.wait(for: \.isEnabled, toEqual: true, timeout: 10))
    remove.tap()
    app.alerts.buttons["Remove"].tap()
    XCTAssertTrue(
      app.staticTexts["Removal saved on this iPad. It will sync when connected."].waitForExistence(
        timeout: 15))
    XCTAssertFalse(app.staticTexts[title].exists)
    capture("IPAD-E02-A04-\(kind)-offline-bookmark-delete-queued")
    app.terminate()
    app.launch()
    openOfflineBook(book, app: app)
    readFile(book.fileID, app: app)
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 20))
    openBookmarks(app)
    XCTAssertTrue(app.buttons["saveBookmark"].wait(for: \.isEnabled, toEqual: true, timeout: 10))
    XCTAssertFalse(app.staticTexts[title].exists)
    XCTAssertFalse(app.buttons["openBookmark\(bookmarkID)"].exists)
    capture("IPAD-E02-A04-\(kind)-deleted-bookmark-stays-hidden-after-restart")
    try await fault("online")
    app.buttons["Done"].tap()
    openBookmarks(app)
    _ = try await waitForBookmarks(bookID: book.bookID, fileID: book.fileID, token: token) {
      !$0.contains { $0["id"] as? Int == bookmarkID || $0["title"] as? String == title }
    }
    XCTAssertFalse(app.buttons["openBookmark\(bookmarkID)"].exists)
    capture("IPAD-E02-A04-\(kind)-authoritative-bookmark-deletion-reconnected")
  }

  private var profile: String {
    ProcessInfo.processInfo.environment["IPAD_E02_PROFILE"] ?? "pro13-portrait-light"
  }

  private struct FixtureBook {
    let bookID: Int
    let fileID: Int
    let title: String
  }

  @MainActor
  private func launchAndSignIn() -> XCUIApplication {
    XCUIDevice.shared.orientation = profile.contains("landscape") ? .landscapeLeft : .portrait
    let app = XCUIApplication()
    app.launchArguments = [
      "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
      "-AppleInterfaceStyle", profile.contains("dark") ? "Dark" : "Light",
      "-UIPreferredContentSizeCategoryName",
      profile.contains("large") ? "UICTContentSizeCategoryXXXL" : "UICTContentSizeCategoryL",
    ]
    app.launch()
    if !app.textFields["serverURL"].waitForExistence(timeout: 3) {
      for _ in 0..<6 where !app.buttons["signOut"].exists {
        if app.buttons["epubCloseReader"].exists {
          app.buttons["epubCloseReader"].tap()
        } else if app.buttons["Close reader"].exists {
          app.buttons["Close reader"].tap()
        } else if app.buttons["annotationHubDone"].exists {
          app.buttons["annotationHubDone"].tap()
        } else if app.buttons["sourceRecoveryClose"].exists {
          app.buttons["sourceRecoveryClose"].tap()
        } else if app.buttons["Done"].exists {
          app.buttons["Done"].firstMatch.tap()
        } else {
          break
        }
      }
      if app.buttons["signOut"].exists { app.buttons["signOut"].tap() }
      if app.buttons["Change server"].exists { app.buttons["Change server"].tap() }
    }
    let server = app.textFields["serverURL"]
    XCTAssertTrue(server.waitForExistence(timeout: 10))
    replaceText(server, with: "http://127.0.0.1:16485")
    app.buttons["connectServer"].tap()
    let username = app.textFields["username"]
    XCTAssertTrue(username.wait(for: \.isHittable, toEqual: true, timeout: 10))
    username.tap()
    username.typeText("ipad-owner")
    app.secureTextFields["password"].tap()
    app.secureTextFields["password"].typeText("IpadFixture123")
    app.buttons["signIn"].tap()
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 25))
    return app
  }

  @MainActor
  private func openBookDetail(_ book: FixtureBook, app: XCUIApplication) {
    if app.buttons["All books"].exists { app.buttons["All books"].tap() }
    app.buttons["Table"].tap()
    let search = app.textViews["librarySearch"]
    XCTAssertTrue(search.wait(for: \.isHittable, toEqual: true, timeout: 10))
    replaceText(search, with: "\(book.title)\n")
    let actions = app.buttons["tableOpen\(book.bookID)_title"]
    XCTAssertTrue(actions.wait(for: \.isHittable, toEqual: true, timeout: 15))
    actions.tap()
    let details = app.buttons["Book details"]
    XCTAssertTrue(details.wait(for: \.isHittable, toEqual: true, timeout: 10))
    details.tap()
    XCTAssertTrue(app.navigationBars["Book details"].waitForExistence(timeout: 10))
    let content = app.descendants(matching: .any).matching(identifier: "bookDetailContent")
    XCTAssertTrue(content.element.wait(for: \.isHittable, toEqual: true, timeout: 10))
    XCTAssertEqual(content.count, 1)
  }

  @MainActor
  private func downloadSelectedFile(_ id: Int, excluding: [Int] = [], app: XCUIApplication) {
    app.buttons["offlineResources"].tap()
    for unselected in excluding {
      let row = app.buttons["offlineSelectFile\(unselected)"]
      XCTAssertTrue(row.waitForExistence(timeout: 10))
      if row.value as? String == "Selected" { row.tap() }
      XCTAssertEqual(row.value as? String, "Not selected")
    }
    let file = app.buttons["offlineSelectFile\(id)"]
    XCTAssertTrue(file.waitForExistence(timeout: 10))
    if file.value as? String != "Selected" { file.tap() }
    let download = app.buttons["offlineDownload"]
    XCTAssertTrue(download.wait(for: \.isEnabled, toEqual: true, timeout: 10))
    download.tap()
    XCTAssertTrue(
      app.staticTexts["Verified ready for offline reading"].waitForExistence(timeout: 45))
    app.buttons["Done"].tap()
  }

  @MainActor
  private func readFile(_ id: Int, app: XCUIApplication) {
    attach(
      Data(app.debugDescription.utf8), name: "IPAD-E02-A04-book-details-hierarchy-file-\(id)",
      type: "public.plain-text")
    let containers = app.descendants(matching: .any).matching(identifier: "bookDetailContent")
    let content = containers.element
    XCTAssertTrue(content.wait(for: \.isHittable, toEqual: true, timeout: 10))
    XCTAssertEqual(containers.count, 1)
    let matches = content.buttons.matching(identifier: "readFile\(id)")
    let read = matches.element
    for _ in 0..<6 where !read.isHittable { content.swipeUp() }
    XCTAssertTrue(read.wait(for: \.isHittable, toEqual: true, timeout: 10))
    XCTAssertEqual(matches.count, 1)
    read.tap()
  }

  @MainActor
  private func openOfflineBook(_ book: FixtureBook, app: XCUIApplication) {
    let offline = app.buttons["offlineLibrary"]
    XCTAssertTrue(offline.wait(for: \.isHittable, toEqual: true, timeout: 25))
    offline.tap()
    let row = app.buttons["offlineBook\(book.bookID)"]
    XCTAssertTrue(row.wait(for: \.isHittable, toEqual: true, timeout: 10))
    row.tap()
  }

  @MainActor
  private func openBookmarks(_ app: XCUIApplication) {
    let button = app.buttons["readerBookmarks"]
    XCTAssertTrue(button.wait(for: \.isHittable, toEqual: true, timeout: 10))
    button.tap()
    XCTAssertTrue(app.buttons["saveBookmark"].waitForExistence(timeout: 10))
  }

  @MainActor
  private func assertSecondPage(_ kind: String, app: XCUIApplication) {
    if kind == "PDF" {
      XCTAssertTrue(
        app.staticTexts.matching(
          NSPredicate(format: "label CONTAINS %@", "Orbit fixture: passage 2")
        ).firstMatch.isHittable)
    } else {
      XCTAssertTrue(app.images["comicPage2"].waitForExistence(timeout: 10))
    }
  }

  @MainActor
  private func replaceText(_ field: XCUIElement, with value: String) {
    field.tap()
    let old = field.value as? String ?? ""
    if !old.isEmpty && old != field.placeholderValue {
      field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.95)).tap()
      field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.utf16.count))
    }
    field.typeText(value)
  }

  @MainActor
  private func bookDetails(bookID: Int, format: String, token: String) async throws -> FixtureBook {
    let data = try await api("books/\(bookID)", token: token)
    let detail = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let files = try XCTUnwrap(detail["files"] as? [[String: Any]])
    let file = try XCTUnwrap(files.first { ($0["format"] as? String)?.lowercased() == format })
    return FixtureBook(
      bookID: bookID, fileID: try XCTUnwrap(file["id"] as? Int),
      title: try XCTUnwrap(detail["title"] as? String))
  }

  @MainActor
  private func loginAPI() async throws -> String {
    let data = try await api(
      "auth/login", method: "POST",
      body: [
        "username": "ipad-owner", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "Offline reading UI assertions",
      ])
    let credentials = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let refresh = try XCTUnwrap(credentials["refreshToken"] as? String)
    addTeardownBlock { [refresh, httpSession] in
      var request = URLRequest(url: URL(string: "http://127.0.0.1:16482/api/v1/auth/logout")!)
      request.httpMethod = "POST"
      request.timeoutInterval = 15
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: ["refreshToken": refresh])
      let (_, response) = try await httpSession.data(for: request)
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }
    return try XCTUnwrap(credentials["accessToken"] as? String)
  }

  @MainActor
  private func api(
    _ path: String, method: String = "GET", token: String? = nil, body: [String: Any]? = nil
  ) async throws -> Data {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:16482/api/v1/\(path)")!)
    request.httpMethod = method
    request.timeoutInterval = 15
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await httpSession.data(for: request)
    XCTAssertTrue((200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0), path)
    return data
  }

  @MainActor
  private func fault(_ action: String) async throws {
    var request = URLRequest(
      url: URL(string: "http://127.0.0.1:16485/__faults/annotations/\(action)")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 15
    let (_, response) = try await httpSession.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
  }

  @MainActor
  private func traffic() async throws -> [[String: Any]] {
    var request = URLRequest(
      url: URL(string: "http://127.0.0.1:16485/__faults/annotations/traffic")!)
    request.timeoutInterval = 15
    let (data, response) = try await httpSession.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    let trace = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(trace["truncated"] as? Bool, false)
    attach(data, name: "IPAD-E02-A04-real-transport-traffic", type: "public.json")
    return try XCTUnwrap(trace["items"] as? [[String: Any]])
  }

  private func successfulBytes(_ items: [[String: Any]]) -> Int {
    items.reduce(0) { total, item in
      let status = item["status"] as? Int ?? 0
      return total + ((200..<300).contains(status) ? item["bytes"] as? Int ?? 0 : 0)
    }
  }

  private func checksum(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func assertNoUnselectedBody(fileID: Int, traffic: [[String: Any]]) {
    let delivery = "/api/v1/books/files/\(fileID)/serve"
    for request in traffic where request["path"] as? String == delivery {
      let status = request["status"] as? Int ?? 0
      if (200..<300).contains(status) {
        XCTAssertEqual(status, 206)
        XCTAssertEqual(request["range"] as? String, "bytes=0-0")
        XCTAssertEqual(request["bytes"] as? Int, 1)
      }
    }
  }

  @MainActor
  private func bookmarks(bookID: Int, fileID: Int, token: String) async throws -> [[String: Any]] {
    let data = try await api(
      "books/\(bookID)/bookmarks/page?fileId=\(fileID)&limit=40", token: token)
    let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertTrue(
      value["nextCursor"] is NSNull, "The bookmark journey fixture is bounded to one page")
    return try XCTUnwrap(value["items"] as? [[String: Any]])
  }

  @MainActor
  private func waitForBookmarks(
    bookID: Int, fileID: Int, token: String, condition: ([[String: Any]]) -> Bool
  ) async throws -> [[String: Any]] {
    let deadline = Date().addingTimeInterval(20)
    var items = try await bookmarks(bookID: bookID, fileID: fileID, token: token)
    while !condition(items) && Date() < deadline {
      try await Task.sleep(for: .milliseconds(250))
      items = try await bookmarks(bookID: bookID, fileID: fileID, token: token)
    }
    XCTAssertTrue(condition(items), "The public bookmark state did not converge")
    attach(
      try JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys]),
      name: "IPAD-E02-A04-public-bookmarks-file-\(fileID)", type: "public.json")
    return items
  }

  @MainActor
  private func waitForProgress(fileID: Int, token: String, page: Int) async throws -> [String: Any]
  {
    let deadline = Date().addingTimeInterval(20)
    var value: [String: Any] = [:]
    repeat {
      let data = try await api("books/files/\(fileID)/progress", token: token)
      value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
      if value["pageNumber"] as? Int == page { break }
      try await Task.sleep(for: .milliseconds(250))
    } while Date() < deadline
    XCTAssertEqual(value["pageNumber"] as? Int, page)
    attach(
      try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
      name: "IPAD-E02-A04-public-progress-file-\(fileID)", type: "public.json")
    return value
  }

  @MainActor
  private func progress(fileID: Int, token: String) async throws -> [String: Any] {
    let data = try await api("books/files/\(fileID)/progress", token: token)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @MainActor
  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "\(name)-\(profile)"
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
