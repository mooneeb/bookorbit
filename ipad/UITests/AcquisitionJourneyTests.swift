import CryptoKit
import Foundation
import PDFKit
import XCTest

final class AcquisitionJourneyTests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  @MainActor
  func testIPADE03A01NativeFileSelectionDockReviewFinalizeAndReader() async throws {
    let token = try await loginToken("ipad-editor")
    let restricted = try await loginToken("ipad-restricted")
    let destination = try await importDestination(token)
    try await control("reset")
    try await control("arm")
    let app = launch(username: "ipad-editor")
    tap("acquisitionEntry", app: app)
    tap("acquisitionSelectFile", app: app)
    selectFile("E03 upload large", app: app)
    let held = try await heldChunk()
    let sessionID = try XCTUnwrap(held["sessionId"] as? String)
    let offset = try XCTUnwrap(held["offset"] as? Int)
    let partial = try await object("uploads/\(sessionID)", token: token)
    let size = try XCTUnwrap(partial["sizeBytes"] as? Int)
    XCTAssertGreaterThan(size, 8 * 1024 * 1024)
    XCTAssertGreaterThan(offset, 0)
    XCTAssertLessThan(offset, size)
    XCTAssertEqual(partial["receivedBytes"] as? Int, offset)
    XCTAssertEqual(partial["status"] as? String, "receiving")
    XCTAssertTrue(app.progressIndicators["acquisitionUploadProgress"].exists)
    capture("IPAD-E03-A01-native-partial-upload-held")
    tap("acquisitionPause", app: app)
    XCTAssertTrue(app.buttons["acquisitionResume"].waitForExistence(timeout: 15))
    app.terminate()
    try await control("reset")
    let paused = try await object("uploads/\(sessionID)", token: token)
    XCTAssertEqual(paused["receivedBytes"] as? Int, offset)
    app.launch()
    tap("acquisitionEntry", app: app)
    tap("acquisitionResume", app: app)
    XCTAssertTrue(app.textFields["acquisitionTitle"].waitForExistence(timeout: 60))
    let completed = try await object("uploads/\(sessionID)", token: token)
    XCTAssertEqual(completed["id"] as? String, sessionID)
    XCTAssertEqual(completed["receivedBytes"] as? Int, size)
    XCTAssertEqual(completed["status"] as? String, "completed")
    let dockID = try XCTUnwrap(completed["bookDockFileId"] as? Int)
    let filename = try XCTUnwrap(completed["filename"] as? String)
    let page = try await object(
      "book-dock/files?page=1&limit=20&search=\(query(filename))", token: token)
    XCTAssertEqual(page["total"] as? Int, 1)
    let title = "Native upload reviewed \(UUID().uuidString)"
    try await review(app, title: title, dockID: dockID, destination: destination, token: token)
    try app.performAccessibilityAudit(for: [.hitRegion, .sufficientElementDescription])
    capture("IPAD-E03-A01-dock-review-preview")
    finalizeAndRelaunch(app)
    let receipt = try await object("uploads/\(sessionID)", token: token)
    let bookID = try XCTUnwrap(receipt["bookId"] as? Int)
    try await assertImportedBook(
      app, token: token, restricted: restricted, bookID: bookID, title: title,
      expectedSize: size, expectedHash: environment("IPAD_E03_LARGE_UPLOAD_SHA256"))
  }

  @MainActor
  func testIPADE03A01ServerDockScanReviewDurableFinalizeAndReader() async throws {
    let token = try await loginToken("ipad-owner")
    let restricted = try await loginToken("ipad-restricted")
    let destination = try await importDestination(token)
    let app = launch(username: "ipad-owner")
    tap("openServerScanning", app: app)
    XCTAssertTrue(
      app.descendants(matching: .any)["bookDockServerFolder"].waitForExistence(timeout: 15))
    let seeded = try await controlObject("seed-dock")
    let filename = try XCTUnwrap(seeded["filename"] as? String)
    tap("scanBookDockFolder", app: app)
    XCTAssertTrue(app.staticTexts["serverScanNotice"].waitForExistence(timeout: 30))
    capture("IPAD-E03-A01-server-dock-folder-scanned")
    let staged = try await readyDockFile(filename: filename, token: token)
    let dockID = try XCTUnwrap(staged["id"] as? Int)
    let sourceSize = try XCTUnwrap(staged["fileSize"] as? Int)
    tap("scanBookDockFolder", app: app)
    let repeated = try await object(
      "book-dock/files?page=1&limit=20&search=\(query(filename))", token: token)
    XCTAssertEqual(repeated["total"] as? Int, 1)
    tap("scanReviewBookDock", app: app)
    tap("acquisitionDock\(dockID)", app: app)
    let title = "Native scanned reviewed \(UUID().uuidString)"
    try await review(app, title: title, dockID: dockID, destination: destination, token: token)
    capture("IPAD-E03-A01-scanned-dock-review-preview")
    finalizeAndRelaunch(app)
    let matches = try await searchBooks(title: title, token: token)
    XCTAssertEqual(matches.count, 1)
    let bookID = try XCTUnwrap(matches.first?["id"] as? Int)
    try await assertImportedBook(
      app, token: token, restricted: restricted, bookID: bookID, title: title,
      expectedSize: sourceSize, expectedHash: seeded["sha256"] as? String)
  }

  @MainActor
  private func review(
    _ app: XCUIApplication, title: String, dockID: Int,
    destination: (library: Int, folder: Int), token: String
  ) async throws {
    set("acquisitionTitle", value: title, app: app)
    set("acquisitionAuthors", value: "Native acceptance author", app: app)
    tap("acquisitionLibrary\(destination.library)", app: app)
    tap("acquisitionFolder\(destination.folder)", app: app)
    tap("acquisitionReview", app: app)
    let finalize = app.buttons["acquisitionFinalize"]
    XCTAssertTrue(finalize.waitForExistence(timeout: 30))
    XCTAssertTrue(finalize.wait(for: \.isEnabled, toEqual: true, timeout: 15))
    let approved = try await object("book-dock/files/\(dockID)", token: token)
    let metadata = try XCTUnwrap(approved["selectedMetadata"] as? [String: Any])
    XCTAssertEqual(metadata["title"] as? String, title)
    XCTAssertEqual(metadata["authors"] as? [String], ["Native acceptance author"])
    XCTAssertEqual(approved["targetLibraryId"] as? Int, destination.library)
    XCTAssertEqual(approved["targetFolderId"] as? Int, destination.folder)
  }

  @MainActor
  private func finalizeAndRelaunch(_ app: XCUIApplication) {
    tap("acquisitionFinalize", app: app)
    let watching = app.buttons["acquisitionPauseImport"]
    let complete = app.buttons["acquisitionDismissImport"]
    XCTAssertTrue(watching.waitForExistence(timeout: 10) || complete.waitForExistence(timeout: 10))
    capture("IPAD-E03-A01-durable-import-before-relaunch")
    app.terminate()
    app.launch()
    tap("acquisitionEntry", app: app)
    reveal(app.buttons["acquisitionRead"], app: app)
    XCTAssertTrue(app.buttons["acquisitionRead"].waitForExistence(timeout: 60))
    capture("IPAD-E03-A01-durable-import-restored")
  }

  @MainActor
  private func assertImportedBook(
    _ app: XCUIApplication, token: String, restricted: String, bookID: Int,
    title: String, expectedSize: Int, expectedHash: String?
  ) async throws {
    let book = try await object("books/\(bookID)", token: token)
    XCTAssertEqual(book["title"] as? String, title)
    let files = try XCTUnwrap(book["files"] as? [[String: Any]])
    let file = try XCTUnwrap(
      files.first(where: { ($0["format"] as? String)?.lowercased() == "pdf" }))
    let fileID = try XCTUnwrap(file["id"] as? Int)
    let delivered = try await request("books/files/\(fileID)/download", token: token)
    XCTAssertEqual(delivered.count, expectedSize)
    let document = try XCTUnwrap(PDFDocument(data: delivered))
    XCTAssertGreaterThan(document.pageCount, 0)
    let expectedHash = try XCTUnwrap(expectedHash, "The harness must provide the source PDF SHA256")
    XCTAssertEqual(
      SHA256.hash(data: delivered).map { String(format: "%02x", $0) }.joined(), expectedHash)
    _ = try await request("books/\(bookID)", token: restricted, expectedStatus: 404)
    _ = try await request("books/files/\(fileID)/download", token: restricted, expectedStatus: 404)
    let matches = try await searchBooks(title: title, token: token)
    XCTAssertEqual(matches.count, 1)
    XCTAssertEqual(matches.first?["id"] as? Int, bookID)
    tap("acquisitionRead", app: app)
    let read = app.buttons["readFile\(fileID)"]
    reveal(read, app: app)
    XCTAssertTrue(read.waitForExistence(timeout: 20))
    read.tap()
    let contents = app.buttons["pdfContents"]
    XCTAssertTrue(contents.waitForExistence(timeout: 30))
    XCTAssertTrue(contents.wait(for: \.isEnabled, toEqual: true, timeout: 30))
    XCTAssertTrue(app.buttons["pdfCloseReader"].exists)
    capture("IPAD-E03-A01-native-reader-\(bookID)")
    tap("pdfCloseReader", app: app)
    tap("Done", app: app)
    tap("acquisitionDismissImport", app: app)
    XCTAssertTrue(
      app.buttons["acquisitionDismissImport"].wait(for: \.exists, toEqual: false, timeout: 15))
  }

  @MainActor
  private func importDestination(_ token: String) async throws -> (library: Int, folder: Int) {
    let capabilities = try await object("uploads/capabilities", token: token)
    let libraries = try XCTUnwrap(capabilities["libraries"] as? [[String: Any]])
    let library = try XCTUnwrap(
      libraries.first(where: { ($0["name"] as? String) == "Fixture library" }))
    let folders = try XCTUnwrap(library["folders"] as? [[String: Any]])
    return (try XCTUnwrap(library["id"] as? Int), try XCTUnwrap(folders.first?["id"] as? Int))
  }

  @MainActor
  private func readyDockFile(filename: String, token: String) async throws -> [String: Any] {
    for _ in 0..<120 {
      let page = try await object(
        "book-dock/files?page=1&limit=20&search=\(query(filename))", token: token)
      let files = try XCTUnwrap(page["items"] as? [[String: Any]])
      if let file = files.first(where: {
        ($0["fileName"] as? String) == filename && ($0["status"] as? String) == "ready"
      }) {
        XCTAssertEqual(page["total"] as? Int, 1)
        return file
      }
      try await Task.sleep(for: .milliseconds(250))
    }
    throw NSError(
      domain: "AcquisitionAcceptance", code: 1,
      userInfo: [
        NSLocalizedDescriptionKey: "The real scanned file did not become ready"
      ])
  }

  @MainActor
  private func searchBooks(title: String, token: String) async throws -> [[String: Any]] {
    let data = try await request("books/search?q=\(query(title))&limit=2", token: token)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
  }

  @MainActor
  private func heldChunk() async throws -> [String: Any] {
    for _ in 0..<100 {
      let value = try await controlObject("held", method: "GET")
      if value["held"] as? Bool == true { return value }
      try await Task.sleep(for: .milliseconds(200))
    }
    throw NSError(
      domain: "AcquisitionAcceptance", code: 2,
      userInfo: [
        NSLocalizedDescriptionKey: "The native uploader did not reach the controlled partial offset"
      ])
  }

  @MainActor
  private func loginToken(_ username: String) async throws -> String {
    let result = try await object(
      "auth/login",
      body: [
        "username": username, "password": environment("IPAD_FIXTURE_PASSWORD") ?? "IpadFixture123",
        "clientKind": "native", "deviceLabel": "Acquisition acceptance",
      ])
    return try XCTUnwrap(result["accessToken"] as? String)
  }

  @MainActor
  private func object(
    _ path: String, token: String? = nil, body: [String: Any]? = nil
  ) async throws -> [String: Any] {
    let data = try await request(path, token: token, body: body)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @MainActor
  private func request(
    _ path: String, token: String? = nil, body: [String: Any]? = nil, expectedStatus: Int? = nil
  ) async throws -> Data {
    var request = URLRequest(url: try XCTUnwrap(URL(string: "\(serverURL)/api/v1/\(path)")))
    request.httpMethod = body == nil ? "GET" : "POST"
    request.timeoutInterval = 45
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = try XCTUnwrap(response as? HTTPURLResponse).statusCode
    if let expectedStatus {
      XCTAssertEqual(status, expectedStatus, path)
    } else {
      XCTAssertTrue(
        (200..<300).contains(status), "\(path): \(status) \(String(decoding: data, as: UTF8.self))")
    }
    return data
  }

  @MainActor
  private func control(_ action: String) async throws {
    _ = try await controlRequest(action)
  }

  @MainActor
  private func controlObject(
    _ action: String, method: String = "POST"
  ) async throws -> [String: Any] {
    let data = try await controlRequest(action, method: method)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @MainActor
  private func controlRequest(_ action: String, method: String = "POST") async throws -> Data {
    let base = environment("IPAD_E03_FAULT_URL") ?? "http://127.0.0.1:16488"
    var request = URLRequest(
      url: try XCTUnwrap(URL(string: "\(base)/__faults/acquisition/\(action)")))
    request.httpMethod = method
    let (data, response) = try await URLSession.shared.data(for: request)
    XCTAssertTrue(
      (200..<300).contains(try XCTUnwrap(response as? HTTPURLResponse).statusCode), action)
    return data
  }

  private var serverURL: String {
    environment("IPAD_E03_SERVER_URL") ?? "http://127.0.0.1:16488"
  }
  private func environment(_ name: String) -> String? {
    ProcessInfo.processInfo.environment[name]
      ?? ProcessInfo.processInfo.environment["TEST_RUNNER_\(name)"]
  }
  private func query(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
  }

  @MainActor
  private func launch(username: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    if app.buttons["signOut"].waitForExistence(timeout: 3) { app.buttons["signOut"].tap() }
    if app.buttons["Change server"].exists { app.buttons["Change server"].tap() }
    set("serverURL", value: serverURL, app: app)
    tap("connectServer", app: app)
    set("username", value: username, app: app)
    set(
      "password", value: environment("IPAD_FIXTURE_PASSWORD") ?? "IpadFixture123", app: app,
      secure: true)
    tap("signIn", app: app)
    XCTAssertTrue(app.buttons["signOut"].waitForExistence(timeout: 20))
    return app
  }

  @MainActor
  private func selectFile(_ name: String, app: XCUIApplication) {
    let browse = app.buttons["Browse"].firstMatch
    if browse.waitForExistence(timeout: 3) { browse.tap() }
    for label in ["On My iPad", "BookOrbit"] {
      let item = app.descendants(matching: .any).matching(
        NSPredicate(format: "label == %@", label)
      ).firstMatch
      if item.waitForExistence(timeout: 3) { item.tap() }
    }
    let file = app.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS %@", name)
    ).firstMatch
    XCTAssertTrue(file.waitForExistence(timeout: 15))
    file.tap()
  }

  @MainActor
  private func set(_ id: String, value: String, app: XCUIApplication, secure: Bool = false) {
    let field = secure ? app.secureTextFields[id] : app.textFields[id]
    reveal(field, app: app)
    XCTAssertTrue(field.waitForExistence(timeout: 15))
    field.tap()
    field.typeText(
      String(
        repeating: XCUIKeyboardKey.delete.rawValue,
        count: (field.value as? String ?? "").utf16.count))
    field.typeText(value)
  }

  @MainActor
  private func tap(_ id: String, app: XCUIApplication) {
    let button = app.buttons[id].firstMatch
    reveal(button, app: app)
    XCTAssertTrue(button.waitForExistence(timeout: 20), id)
    XCTAssertTrue(button.wait(for: \.isEnabled, toEqual: true, timeout: 20), id)
    button.tap()
  }

  @MainActor
  private func reveal(_ element: XCUIElement, app: XCUIApplication) {
    if element.waitForExistence(timeout: 2), element.isHittable { return }
    for _ in 0..<5 {
      app.swipeUp()
      if element.exists && element.isHittable { return }
    }
    for _ in 0..<8 {
      app.swipeDown()
      if element.exists && element.isHittable { return }
    }
  }

  @MainActor
  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
