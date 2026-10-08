import Foundation
import XCTest

final class OfflineRemovalJourneyTests: XCTestCase {
  private let httpSession = URLSession(configuration: .ephemeral)

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
  }

  @MainActor
  func testIPADE02A04RemovalReclaimsSelectedAndDeselectedContentAcrossRestart() async throws {
    try await fault("reset")
    let token = try await loginAPI()
    let pdf = try await bookDetails(bookID: 8, format: "pdf", token: token)
    let audio = try await bookDetails(bookID: 8, format: "m4a", token: token)
    let original = try await api("books/files/\(pdf.fileID)/serve", token: token)
    let manifestData = try await api("audiobooks/8/manifest", token: token)
    let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
    let assets = try XCTUnwrap(manifest["assets"] as? [[String: Any]])
    let asset = try XCTUnwrap(assets.first { $0["fileId"] as? Int == audio.fileID })
    let assetID = try XCTUnwrap(asset["assetId"] as? String)
    let audioBytes = try await api("audiobooks/8/assets/\(assetID)/content", token: token)
    let notesBefore = try await api(
      "annotations/native/delta?bookId=8&cursor=0&limit=100", token: token)
    let app = launchAndSignIn()
    openBookDetail(pdf, app: app)
    chooseFiles([pdf.fileID, audio.fileID], excluding: [], app: app)
    app.buttons["Done"].tap()
    chooseFiles([audio.fileID], excluding: [pdf.fileID], app: app)
    removeDownload(app)
    XCTAssertTrue(
      app.staticTexts["offlineStatus"].wait(
        for: \.label,
        toEqual:
          "Downloaded content removed from this iPad. Your server book and saved reading work are retained.",
        timeout: 20))
    app.buttons["Done"].tap()
    app.terminate()
    app.launch()
    app.buttons["offlineLibrary"].tap()
    XCTAssertFalse(app.buttons["offlineBook8"].waitForExistence(timeout: 3))
    app.buttons["Done"].tap()
    let retained = try await api("books/8", token: token)
    let detail = try XCTUnwrap(JSONSerialization.jsonObject(with: retained) as? [String: Any])
    let files = try XCTUnwrap(detail["files"] as? [[String: Any]])
    XCTAssertTrue(files.contains { $0["id"] as? Int == pdf.fileID })
    XCTAssertTrue(files.contains { $0["id"] as? Int == audio.fileID })
    let notesAfter = try await api(
      "annotations/native/delta?bookId=8&cursor=0&limit=100", token: token)
    XCTAssertEqual(
      try JSONSerialization.jsonObject(with: notesBefore) as? NSDictionary,
      try JSONSerialization.jsonObject(with: notesAfter) as? NSDictionary)
    try await fault("reset")
    openBookDetail(pdf, app: app)
    chooseFiles([pdf.fileID, audio.fileID], excluding: [], app: app)
    let delivery = try await traffic()
    assertCompleteDownload(
      "/api/v1/books/files/\(pdf.fileID)/serve", bytes: original.count, traffic: delivery)
    assertCompleteDownload(
      "/api/v1/audiobooks/8/assets/\(assetID)/content", bytes: audioBytes.count, traffic: delivery)
    app.buttons["Done"].tap()
    try await fault("offline")
    app.terminate()
    app.launch()
    openOfflineBook(pdf, app: app)
    readFile(pdf.fileID, app: app)
    XCTAssertTrue(app.staticTexts["Page 1 of 3"].waitForExistence(timeout: 20))
    try await fault("online")
  }

  @MainActor
  func testIPADE02A04PendingProgressAndBookmarksBlockRemovalAndSurviveRestart() async throws {
    try await fault("reset")
    let token = try await loginAPI()
    let book = try await bookDetails(bookID: 10, format: "cbz", token: token)
    let title = "Removal protected bookmark \(UUID().uuidString)"
    let app = launchAndSignIn()
    openBookDetail(book, app: app)
    downloadSelectedFile(book.fileID, app: app)
    try await fault("offline")
    readFile(book.fileID, app: app)
    XCTAssertTrue(app.buttons["comicNextPage"].waitForExistence(timeout: 15))
    app.buttons["comicNextPage"].tap()
    XCTAssertTrue(app.staticTexts["Position saved on this iPad"].waitForExistence(timeout: 15))
    app.buttons["Close reader"].tap()
    openResources(app)
    assertRemovalBlocked(app)
    app.buttons["Done"].tap()
    try await fault("online")
    app.terminate()
    app.launch()
    openOfflineBook(book, app: app)
    readFile(book.fileID, app: app)
    var synced = false
    for _ in 0..<50 {
      let data = try await api("books/files/\(book.fileID)/progress", token: token)
      let progress = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      if progress?["pageNumber"] as? Int == 2 {
        synced = true
        break
      }
      try await Task.sleep(for: .milliseconds(200))
    }
    XCTAssertTrue(
      synced, "Progress must commit before separately testing pending bookmark protection")
    try await fault("offline")
    openBookmarks(app)
    replaceText(app.descendants(matching: .any)["bookmarkTitle"].firstMatch, with: title)
    app.buttons["saveBookmark"].tap()
    XCTAssertTrue(
      app.staticTexts["Bookmark saved on this iPad. It will sync when connected."].waitForExistence(
        timeout: 15))
    app.buttons["Done"].tap()
    app.buttons["Close reader"].tap()
    openResources(app)
    assertRemovalBlocked(app)
    app.terminate()
    app.launch()
    openOfflineBook(book, app: app)
    readFile(book.fileID, app: app)
    XCTAssertTrue(app.images["comicPage2"].waitForExistence(timeout: 20))
    openBookmarks(app)
    XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
    try await fault("online")
  }

  @MainActor
  func testIPADE02A04PendingAnnotationBlocksRemovalAndRemainsEditableOffline() async throws {
    try await fault("reset")
    let token = try await loginAPI()
    let book = try await bookDetails(bookID: 1, format: "pdf", token: token)
    let app = launchAndSignIn()
    openBookDetail(book, app: app)
    downloadSelectedFile(book.fileID, app: app)
    readFile(book.fileID, app: app)
    XCTAssertTrue(app.buttons["pdfInkDraw"].waitForExistence(timeout: 20))
    try await fault("offline")
    let items = app.images.matching(NSPredicate(format: "identifier BEGINSWITH %@", "pdfInkItem"))
    let before = Set(items.allElementsBoundByIndex.map(\.identifier))
    tapInkControl("pdfInkFixtureStroke", app: app)
    XCTAssertTrue(app.staticTexts["Ink saved locally"].waitForExistence(timeout: 15))
    let identity = try XCTUnwrap(
      items.allElementsBoundByIndex.first { !before.contains($0.identifier) }?.identifier)
    app.buttons["Close reader"].tap()
    openResources(app)
    assertRemovalBlocked(app)
    app.terminate()
    app.launch()
    openOfflineBook(book, app: app)
    readFile(book.fileID, app: app)
    XCTAssertTrue(app.images[identity].waitForExistence(timeout: 20))
    XCTAssertTrue(app.buttons["pdfInkDraw"].isEnabled)
    try await fault("online")
  }

  @MainActor
  private func tapInkControl(_ id: String, app: XCUIApplication) {
    let controls = app.buttons.matching(identifier: id)
    let toolbars = app.scrollViews.matching(identifier: "pdfInkToolbar")
    let windows = app.windows.containing(.scrollView, identifier: "pdfInkToolbar")
    let pages = app.staticTexts.matching(
      NSPredicate(format: "label MATCHES %@", "Page [0-9]+ of [0-9]+"))
    guard controls.element.waitForExistence(timeout: 10), controls.count == 1,
      toolbars.count == 1, windows.count == 1, pages.count == 1
    else {
      XCTFail("Expected unique ink control, toolbar, reader window and logical page: \(id).")
      return
    }
    let control = controls.element
    let toolbar = toolbars.element
    let window = windows.element
    let windowFrame = window.frame
    let pageLabel = pages.element.label
    let visible = toolbar.frame.intersection(windowFrame)
    for _ in 0..<6 {
      if control.isHittable && visible.contains(control.frame) { break }
      let rowY = control.frame.midY
      guard rowY > visible.minY, rowY < visible.maxY else {
        XCTFail("Ink control row is outside the visible toolbar: \(id).")
        return
      }
      let revealLeft = control.frame.minX < visible.minX
      let startX = visible.minX + visible.width * (revealLeft ? 0.3 : 0.7)
      let endX = visible.minX + visible.width * (revealLeft ? 0.65 : 0.35)
      // The scroll view frame includes window chrome above the actual control row.
      let start = toolbar.coordinate(
        withNormalizedOffset: CGVector(
          dx: (startX - toolbar.frame.minX) / toolbar.frame.width,
          dy: (rowY - toolbar.frame.minY) / toolbar.frame.height))
      let end = start.withOffset(CGVector(dx: endX - startX, dy: 0))
      start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
      guard window.frame == windowFrame, pages.element.label == pageLabel else {
        XCTFail("Revealing ink control moved the reader window or changed its logical page: \(id).")
        return
      }
    }
    guard control.wait(for: \.isHittable, toEqual: true, timeout: 5),
      visible.contains(control.frame), control.wait(for: \.isEnabled, toEqual: true, timeout: 10)
    else {
      XCTFail("Ink control is not fully visible, hittable and enabled: \(id).")
      return
    }
    control.tap()
  }

  @MainActor
  private func chooseFiles(_ selected: [Int], excluding: [Int], app: XCUIApplication) {
    openResources(app)
    for id in selected + excluding {
      let row = app.buttons["offlineSelectFile\(id)"]
      XCTAssertTrue(row.waitForExistence(timeout: 10))
      let expected = selected.contains(id) ? "Selected" : "Not selected"
      if row.value as? String != expected { row.tap() }
      XCTAssertEqual(row.value as? String, expected)
    }
    app.buttons["offlineDownload"].tap()
    XCTAssertTrue(
      app.staticTexts["Verified ready for offline reading"].waitForExistence(timeout: 45))
  }

  @MainActor
  private func openResources(_ app: XCUIApplication) {
    let action = app.buttons["offlineResources"]
    let content = app.descendants(matching: .any)["bookDetailContent"].firstMatch
    for _ in 0..<6 where !action.isHittable { content.swipeDown() }
    XCTAssertTrue(action.wait(for: \.isHittable, toEqual: true, timeout: 10))
    action.tap()
    XCTAssertTrue(app.staticTexts["offlineStatus"].waitForExistence(timeout: 10))
  }

  @MainActor
  private func removeDownload(_ app: XCUIApplication) {
    let remove = app.buttons["offlineRemoveDownload"]
    for _ in 0..<6 where !remove.isHittable { app.swipeUp() }
    XCTAssertTrue(remove.wait(for: \.isHittable, toEqual: true, timeout: 10))
    remove.tap()
    app.buttons["offlineConfirmRemoveDownload"].tap()
  }

  @MainActor
  private func assertRemovalBlocked(_ app: XCUIApplication) {
    removeDownload(app)
    let error = app.staticTexts["offlineError"]
    XCTAssertTrue(error.waitForExistence(timeout: 15))
    XCTAssertTrue(
      error.label.contains("pending notes, bookmarks, reading progress, or recovery work"))
    XCTAssertTrue(app.buttons["offlineRemoveDownload"].exists)
  }

  private func assertCompleteDownload(_ path: String, bytes: Int, traffic: [[String: Any]]) {
    XCTAssertGreaterThan(bytes, 0)
    XCTAssertTrue(
      traffic.contains {
        $0["path"] as? String == path && $0["status"] as? Int == 200 && $0["bytes"] as? Int == bytes
      }, "Removed content must be delivered completely again: \(path)")
  }

  @MainActor
  private func traffic() async throws -> [[String: Any]] {
    let request = URLRequest(
      url: URL(string: "http://127.0.0.1:16485/__faults/annotations/traffic")!)
    let (data, response) = try await httpSession.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(value["truncated"] as? Bool, false)
    return try XCTUnwrap(value["items"] as? [[String: Any]])
  }

  private func attach(_ data: Data, name: String, type: String) {
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: type)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
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
      "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "--annotation-input-driver",
      "-AppleInterfaceStyle", profile.contains("dark") ? "Dark" : "Light",
      "-UIPreferredContentSizeCategoryName",
      profile.contains("large") ? "UICTContentSizeCategoryXXXL" : "UICTContentSizeCategoryL",
    ]
    app.launchEnvironment["BOOKORBIT_ANNOTATION_INPUT_FIXTURE"] = "1"
    E02ProfileSupport.configure(app)
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
    guard E02ProfileSupport.ensureSignInForm(app: app, serverURL: "http://127.0.0.1:16485") else {
      return app
    }
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

}
