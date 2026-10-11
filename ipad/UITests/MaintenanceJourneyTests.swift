import Foundation
import PDFKit
import XCTest

final class MaintenanceJourneyTests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  @MainActor
  func testIPADE03A05MaintenancePreviewPagingAndCoverReview() throws {
    let app = signIn(username: "ipad-owner")
    XCTAssertTrue(app.buttons["maintenanceEntry"].waitForExistence(timeout: 15))
    app.buttons["maintenanceEntry"].tap()
    XCTAssertTrue(app.buttons["maintenanceScan"].waitForExistence(timeout: 15))
    capture("IPAD-E03-A05-maintenance-duplicates-preview")
    app.buttons["maintenanceScan"].tap()
    XCTAssertTrue(app.staticTexts["Scan complete"].waitForExistence(timeout: 60))
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Duplicate group '"))
        .firstMatch.exists)
    capture("IPAD-E03-A05-maintenance-duplicate-result")
    app.buttons["maintenanceTool"].tap()
    app.buttons["Missing resources"].tap()
    XCTAssertTrue(app.buttons["maintenanceSweep"].waitForExistence(timeout: 15))
    app.buttons["maintenanceSweep"].tap()
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Cover check complete:'"))
        .firstMatch.waitForExistence(timeout: 60))
    app.buttons["maintenanceReviewCleanup"].tap()
    XCTAssertTrue(
      app.buttons["maintenanceReviewCleanup"].wait(for: \.isEnabled, toEqual: true, timeout: 15))
    capture("IPAD-E03-A05-maintenance-cover-cleanup-preview")
    if #available(iOS 17.0, *) {
      try app.performAccessibilityAudit(for: [
        .elementDetection, .hitRegion, .sufficientElementDescription,
      ])
    }
    XCTAssertTrue(
      app.buttons["maintenanceReviewCleanup"].wait(for: \.isHittable, toEqual: true, timeout: 10))
    capture("IPAD-E03-A05-maintenance-profile")
  }

  @MainActor
  func testIPADE03A05MergePreviewApplyAndReadableFileRepair() async throws {
    let fixtureText = try XCTUnwrap(E03ProfileSupport.environment("IPAD_MAINTENANCE_FIXTURE"))
    let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fixtureText.utf8)) as? [String: Any])
    let sourceFileID = try XCTUnwrap(fixture["sourceFileId"] as? Int)
    let sourceBookID = try XCTUnwrap(fixture["sourceBookId"] as? Int)
    let repairedFileID = try XCTUnwrap(fixture["missingFileId"] as? Int)
    let repairedBookID = try XCTUnwrap(fixture["missingBookId"] as? Int)
    let credentials = try await object("auth/login", body: ["username": "ipad-owner",
      "password": "IpadFixture123", "clientKind": "native", "deviceLabel": "Native maintenance preservation"])
    let token = try XCTUnwrap(credentials["accessToken"] as? String)
    let sourceNote = "Native merge preserves my private note"
    let repairNote = "Native repair preserves my private note"
    try await seedReading(bookID: sourceBookID, fileID: sourceFileID, note: sourceNote, token: token)
    try await seedReading(bookID: repairedBookID, fileID: repairedFileID, note: repairNote, token: token)
    let source = try await object("annotations/native/files/\(sourceFileID)/source?bookId=\(sourceBookID)&page=0", token: token)
    let identity = UUID().uuidString
    let inkResult = try await object("annotations/native/operations", token: token,
      body: ["deviceId": "E03 native maintenance", "operations": [[
        "operationId": UUID().uuidString, "clientId": identity, "bookId": sourceBookID,
        "baseVersion": 0, "action": "create", "payload": [
          "kind": "pdf_ink", "bookFileId": sourceFileID,
          "sourceRevision": try XCTUnwrap(source["sourceRevision"]),
          "pageFingerprint": try XCTUnwrap(source["pageFingerprint"]),
          "pdf": ["page": 0, "rect": ["x": 80, "y": 600, "width": 100, "height": 8], "rects": []],
          "drawing": ["format": "bookorbit-ink-v1", "strokes": [["id": "native-maintenance-ink",
            "color": "#000000", "width": 8, "points": [["x": 80, "y": 600], ["x": 180, "y": 600]]]]],
        ],
      ]]])
    XCTAssertEqual((inkResult["results"] as? [[String: Any]])?.first?["status"] as? String, "applied")
    let sourceBytes = try await request("books/files/\(sourceFileID)/serve", token: token)
    let sourceProgress = try await object("books/files/\(sourceFileID)/progress", token: token)
    let repairProgress = try await object("books/files/\(repairedFileID)/progress", token: token)
    let app = signIn(username: "ipad-owner")
    app.buttons["maintenanceEntry"].tap()
    XCTAssertTrue(app.buttons["maintenanceScan"].waitForExistence(timeout: 15))
    app.buttons["maintenanceScan"].tap()
    XCTAssertTrue(app.staticTexts["Scan complete"].waitForExistence(timeout: 60))
    let sourceID = String(sourceBookID)
    let targetBookID = try XCTUnwrap(fixture["targetBookId"] as? Int)
    let targetID = String(targetBookID)
    let keeper = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
        "maintenanceKeeper", "Keep book \(sourceID):")
    ).firstMatch
    reveal(keeper, app: app)
    XCTAssertTrue(keeper.waitForExistence(timeout: 15))
    keeper.tap()
    app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Keep book \(targetID):")
    ).firstMatch.tap()
    let merge = app.buttons["maintenanceMerge\(sourceID)"]
    XCTAssertTrue(merge.waitForExistence(timeout: 15))
    merge.tap()
    XCTAssertTrue(app.buttons["maintenanceApplyMerge"].waitForExistence(timeout: 15))
    capture("IPAD-E03-A05-native-merge-preview")
    app.buttons["maintenanceApplyMerge"].tap()
    XCTAssertTrue(app.staticTexts["maintenanceResult"].waitForExistence(timeout: 30))
    capture("IPAD-E03-A05-native-merge-result")
    app.buttons["maintenanceTool"].tap()
    app.buttons["Missing resources"].tap()
    let bookID = String(repairedBookID)
    let path = try XCTUnwrap(E03ProfileSupport.environment("IPAD_MAINTENANCE_REPLACEMENT_PATH"))
    let missing = app.buttons["maintenanceMissing\(bookID)"]
    XCTAssertTrue(missing.waitForExistence(timeout: 15))
    missing.tap()
    let replacement = app.textFields["maintenanceReplacementPath"]
    XCTAssertTrue(replacement.waitForExistence(timeout: 15))
    replacement.tap()
    replacement.typeText(path + "\n")
    app.buttons["maintenancePreviewRepair"].tap()
    XCTAssertTrue(app.buttons["maintenanceApplyRepair"].waitForExistence(timeout: 15))
    capture("IPAD-E03-A05-native-repair-preview")
    app.buttons["maintenanceApplyRepair"].tap()
    XCTAssertTrue(
      app.staticTexts["File repaired. Reading data was preserved."].waitForExistence(timeout: 30))
    XCTAssertFalse(app.buttons["maintenanceMissing\(bookID)"].exists)
    capture("IPAD-E03-A05-native-repair-result")
    let repairedBytes = try await request("books/files/\(repairedFileID)/serve", token: token)
    let expectedRepair = try Data(contentsOf: URL(fileURLWithPath: path))
    XCTAssertEqual(repairedBytes, expectedRepair)
    let mergedBytes = try await request("books/files/\(sourceFileID)/serve", token: token)
    XCTAssertEqual(mergedBytes, sourceBytes)
    let mergedPDF = try XCTUnwrap(PDFDocument(data: mergedBytes))
    XCTAssertTrue(mergedPDF.page(at: 0)?.annotations.contains { $0.type == "Ink" } == true)
    try await assertReading(bookID: targetBookID, fileID: sourceFileID, note: sourceNote,
      progress: sourceProgress, token: token)
    try await assertReading(bookID: repairedBookID, fileID: repairedFileID, note: repairNote,
      progress: repairProgress, token: token)
    app.buttons["Done"].firstMatch.tap()
    try await reopen(app, bookID: targetBookID, fileID: sourceFileID, note: sourceNote,
      inkIdentity: identity, label: "merged", token: token)
    try await reopen(app, bookID: repairedBookID, fileID: repairedFileID, note: repairNote,
      inkIdentity: nil, label: "repaired", token: token)
    let book = try await object("books/\(repairedBookID)", token: token)
    let libraryID = try XCTUnwrap(book["libraryId"] as? Int)
    let library = try await object("libraries/\(libraryID)", token: token)
    _ = try await object("libraries/\(libraryID)", token: token, method: "PATCH",
      body: ["fileRenameEnabled": true, "fileNamingPattern": "{title}"])
    app.buttons["maintenanceEntry"].tap()
    app.buttons["maintenanceTool"].tap()
    app.buttons["Rename"].tap()
    let selected = app.switches["maintenanceRename\(repairedBookID)"]
    for _ in 0..<8 where !selected.exists && app.buttons["Next"].exists {
      app.buttons["Next"].tap()
    }
    reveal(selected, app: app)
    XCTAssertTrue(selected.wait(for: \.isHittable, toEqual: true, timeout: 15))
    selected.tap()
    capture("IPAD-E03-A05-native-rename-preview")
    let apply = app.buttons["maintenanceApplyRename"]
    reveal(apply, app: app)
    XCTAssertTrue(apply.wait(for: \.isEnabled, toEqual: true, timeout: 15))
    apply.tap()
    XCTAssertTrue(app.staticTexts["maintenanceResult"].waitForExistence(timeout: 30))
    XCTAssertEqual(app.staticTexts["maintenanceResult"].label, "Renamed 1, failed 0, skipped 0.")
    capture("IPAD-E03-A05-native-rename-result")
    let renamedBytes = try await request("books/files/\(repairedFileID)/serve", token: token)
    XCTAssertEqual(renamedBytes, repairedBytes)
    try await assertReading(bookID: repairedBookID, fileID: repairedFileID, note: repairNote,
      progress: repairProgress, token: token)
    app.buttons["Done"].firstMatch.tap()
    try await reopen(app, bookID: repairedBookID, fileID: repairedFileID, note: repairNote,
      inkIdentity: nil, label: "renamed", token: token)
    _ = try await object("libraries/\(libraryID)", token: token, method: "PATCH",
      body: ["fileRenameEnabled": library["fileRenameEnabled"] ?? false,
        "fileNamingPattern": library["fileNamingPattern"] ?? NSNull()])
  }

  @MainActor
  func testIPADE03A05MaintenanceHiddenWithoutSpecificPermission() {
    let app = signIn(username: "ipad-reader")
    XCTAssertFalse(app.buttons["maintenanceEntry"].exists)
    capture("IPAD-E03-A05-maintenance-reader-denied")
  }

  @MainActor
  private func seedReading(bookID: Int, fileID: Int, note: String, token: String) async throws {
    _ = try await object("books/\(bookID)/personal-note", token: token, method: "PATCH", body: ["note": note])
    _ = try await object("books/files/\(fileID)/progress", token: token,
      body: ["source": "text", "percentage": 42, "pageNumber": 1])
    _ = try await object("books/\(bookID)/annotations", token: token, body: [
      "bookFileId": fileID, "pdf": ["page": 0, "rect": ["x": 0.1, "y": 0.1, "width": 0.2, "height": 0.1], "rects": []],
      "text": "Preserved maintenance passage", "note": "Native maintenance passage note",
    ])
  }

  @MainActor
  private func assertReading(bookID: Int, fileID: Int, note: String,
    progress: [String: Any], token: String) async throws {
    let book = try await object("books/\(bookID)", token: token)
    XCTAssertEqual(book["personalNote"] as? String, note)
    let after = try await object("books/files/\(fileID)/progress", token: token)
    XCTAssertEqual(try JSONSerialization.data(withJSONObject: after, options: .sortedKeys),
      try JSONSerialization.data(withJSONObject: progress, options: .sortedKeys))
    let annotations = try await object("books/\(bookID)/annotations?page=1&pageSize=100", token: token)
    XCTAssertTrue((annotations["items"] as? [[String: Any]] ?? []).contains {
      $0["note"] as? String == "Native maintenance passage note"
    })
  }

  @MainActor
  private func reopen(_ app: XCUIApplication, bookID: Int, fileID: Int, note: String,
    inkIdentity: String?, label: String, token: String) async throws {
    if app.buttons["All books"].exists { app.buttons["All books"].tap() }
    app.buttons["Table"].tap()
    let book = try await object("books/\(bookID)", token: token)
    let search = app.textViews["librarySearch"]
    XCTAssertTrue(search.wait(for: \.isHittable, toEqual: true, timeout: 15))
    search.tap()
    search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (search.value as? String ?? "").utf16.count))
    search.typeText(try XCTUnwrap(book["title"] as? String) + "\n")
    let open = app.buttons["tableOpen\(bookID)_title"]
    XCTAssertTrue(open.wait(for: \.isHittable, toEqual: true, timeout: 15))
    open.tap()
    app.buttons["Book details"].tap()
    let visibleNote = app.staticTexts["bookReadingCurrentNote"]
    reveal(visibleNote, app: app)
    XCTAssertEqual(visibleNote.label, note)
    capture("IPAD-E03-A05-native-\(label)-private-note-reopened")
    guard E02ProfileSupport.openBookFile(app: app, fileID: fileID) else { return }
    XCTAssertTrue(app.buttons["pdfContents"].wait(for: \.isEnabled, toEqual: true, timeout: 30))
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Page 1 of ")).firstMatch.exists)
    if let inkIdentity {
      XCTAssertTrue(app.images["pdfInkItem\(inkIdentity)"].waitForExistence(timeout: 20))
    }
    capture("IPAD-E03-A05-native-\(label)-reader-progress-reopened")
    app.buttons["pdfCloseReader"].tap()
    app.navigationBars["Book details"].buttons.firstMatch.tap()
    let page = try await object("books/\(bookID)/annotations?page=1&pageSize=100", token: token)
    let passage = try XCTUnwrap((page["items"] as? [[String: Any]] ?? []).first {
      $0["note"] as? String == "Native maintenance passage note"
    })
    let passageID = try XCTUnwrap(passage["id"] as? Int)
    app.buttons["openAnnotationHub"].tap()
    let hubSearch = app.textFields["annotationHubSearch"]
    XCTAssertTrue(hubSearch.wait(for: \.isHittable, toEqual: true, timeout: 15))
    hubSearch.tap()
    hubSearch.typeText("Native maintenance passage note\n")
    let row = app.buttons["annotationHubItem\(passageID)"]
    XCTAssertTrue(row.wait(for: \.isHittable, toEqual: true, timeout: 20))
    row.tap()
    XCTAssertTrue(app.staticTexts["Native maintenance passage note"].waitForExistence(timeout: 15))
    capture("IPAD-E03-A05-native-\(label)-passage-note-reopened")
    app.buttons["Done"].firstMatch.tap()
    app.buttons["annotationHubDone"].tap()
  }

  @MainActor
  private func reveal(_ element: XCUIElement, app: XCUIApplication) {
    let list = app.collectionViews.allElementsBoundByIndex.last(where: { $0.isHittable }) ?? app
    for _ in 0..<8 where !element.isHittable { list.swipeUp() }
    for _ in 0..<8 where !element.isHittable { list.swipeDown() }
  }

  @MainActor
  private func object(_ path: String, token: String? = nil, method: String? = nil,
    body: [String: Any]? = nil) async throws -> [String: Any] {
    let data = try await request(path, token: token, method: method, body: body)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @MainActor
  private func request(_ path: String, token: String? = nil, method: String? = nil,
    body: [String: Any]? = nil) async throws -> Data {
    let server = E03ProfileSupport.environment("IPAD_E03_SERVER_URL") ?? "http://localhost:16482"
    var request = URLRequest(url: try XCTUnwrap(URL(string: "\(server)/api/v1/\(path)")))
    request.httpMethod = method ?? (body == nil ? "GET" : "POST")
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    XCTAssertTrue((200..<300).contains(try XCTUnwrap(response as? HTTPURLResponse).statusCode), path)
    return data
  }

  @MainActor
  private func signIn(username: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    E03ProfileSupport.configure(app)
    app.launch()
    if !app.textFields["serverURL"].waitForExistence(timeout: 5) {
      if app.buttons["signOut"].exists { app.buttons["signOut"].tap() }
      if app.buttons["Change server"].exists { app.buttons["Change server"].tap() }
    }
    let server = app.textFields["serverURL"]
    XCTAssertTrue(server.waitForExistence(timeout: 10))
    server.tap()
    let old = server.value as? String ?? ""
    server.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.utf16.count))
    server.typeText("http://localhost:16482")
    app.buttons["connectServer"].tap()
    XCTAssertTrue(app.textFields["username"].waitForExistence(timeout: 15))
    app.textFields["username"].tap()
    app.textFields["username"].typeText(username)
    app.secureTextFields["password"].tap()
    app.secureTextFields["password"].typeText("IpadFixture123")
    app.buttons["signIn"].tap()
    XCTAssertTrue(app.buttons["browseAuthors"].waitForExistence(timeout: 30))
    return app
  }

  @MainActor
  private func capture(_ name: String) {
    E03ProfileSupport.capture(name, test: self)
  }
}
