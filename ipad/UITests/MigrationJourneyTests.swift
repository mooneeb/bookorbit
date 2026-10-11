import Foundation
import XCTest

final class MigrationJourneyTests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  @MainActor
  func testIPADE03A03ProviderConfigurationAndFailure() throws {
    let app = launch(username: "ipad-owner")
    let entry = app.buttons["migrationImportEntry"]
    XCTAssertTrue(entry.waitForExistence(timeout: 15))
    entry.tap()
    XCTAssertTrue(app.buttons["migrationProvider"].waitForExistence(timeout: 15))
    if app.buttons["migrationConfigureAnother"].exists {
      tap("migrationConfigureAnother", app: app)
    }
    for (provider, field) in [
      ("Booklore", "migrationHost"), ("Grimmory", "migrationHost"),
      ("Audiobookshelf", "migrationBaseURL"), ("Calibre-Web Automated", "migrationAppDatabasePath"),
    ] {
      choose("migrationProvider", value: provider, app: app)
      XCTAssertTrue(app.textFields[field].waitForExistence(timeout: 5))
      capture("IPAD-E03-A03-config-\(provider)")
    }
    set("migrationSourceName", value: "Invalid native source", app: app)
    set("migrationAppDatabasePath", value: "/missing/native/app.db", app: app)
    set("migrationMetadataDatabasePath", value: "/missing/native/metadata.db", app: app)
    tap("migrationSaveSource", app: app)
    XCTAssertTrue(app.staticTexts["migrationMessage"].waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["migrationApply"].exists)
    capture("IPAD-E03-A03-source-validation-error")
    try app.performAccessibilityAudit(for: [.contrast, .hitRegion, .sufficientElementDescription])
    app.buttons["Done"].tap()
    app.buttons["signOut"].tap()
    let restricted = launch(username: "ipad-restricted")
    XCTAssertFalse(restricted.buttons["migrationImportEntry"].exists)
    capture("IPAD-E03-A03-migration-permission-hidden")
  }

  @MainActor
  func testIPADE03A03MigrationRoundTrip() async throws {
    let fixtures = try nativeFixtures()
    XCTAssertEqual(fixtures.count, 5, "Every provider and both Audiobookshelf modes must run")
    let credentials = try await request(
      "auth/login",
      body: [
        "username": "ipad-owner", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "Native migration acceptance oracle",
      ])
    let token = try XCTUnwrap(credentials["accessToken"] as? String)
    let app = launch(username: "ipad-owner")
    tap("migrationImportEntry", app: app)
    for fixture in fixtures {
      if app.buttons["migrationConfigureAnother"].exists {
        tap("migrationConfigureAnother", app: app)
      }
      let type = try XCTUnwrap(fixture["type"] as? String)
      let mode = try XCTUnwrap(fixture["mode"] as? String)
      let testID = "IPAD-E03-A03-\(type)-\(mode)"
      try configure(fixture, app: app)
      capture("\(testID)-configured")
      tap("migrationSaveSource", app: app)
      XCTAssertTrue(app.buttons["migrationPreview"].waitForExistence(timeout: 30))
      if let sourceUser = fixture["sourceUserId"] as? String {
        choose("migrationUser\(sourceUser)", value: "ipad-owner", app: app)
      }
      tap("migrationAddPathMapping", app: app)
      set(
        "migrationSourcePrefix0", value: try XCTUnwrap(fixture["sourcePrefix"] as? String), app: app
      )
      set(
        "migrationTargetPrefix0", value: try XCTUnwrap(fixture["targetPrefix"] as? String), app: app
      )
      if let control = fixture["control"] as? [String: String] {
        try await failNextSourceBatch(control)
        tap("migrationPreview", app: app)
        let error = app.staticTexts.matching(
          NSPredicate(
            format: "identifier == %@ AND label CONTAINS %@", "migrationMessage", "status 503")
        ).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["migrationApply"].exists)
        capture("\(testID)-source-interrupted")
      }
      tap("migrationPreview", app: app)
      XCTAssertTrue(app.buttons["migrationApply"].waitForExistence(timeout: 90))
      XCTAssertTrue(app.buttons["migrationApply"].isEnabled)
      let expectedTotal = try XCTUnwrap(fixture["expectedTotal"] as? Int)
      if expectedTotal > 40 {
        tap("migrationNextMatches", app: app)
        let range = app.staticTexts["migrationMatchRange"]
        reveal(range, app: app)
        XCTAssertTrue(
          app.staticTexts.matching(
            NSPredicate(
              format: "identifier == %@ AND label CONTAINS %@", "migrationMatchRange", "41-80")
          ).firstMatch.waitForExistence(timeout: 15))
        XCTAssertLessThanOrEqual(
          app.staticTexts.matching(identifier: "migrationPreviewMatch").count, 40)
        tap("migrationPreviousMatches", app: app)
      }
      capture("\(testID)-dry-run")
      _ = try await request(
        "__faults/migration", token: token, body: ["mode": "delay", "delayMs": 15000])
      tap("migrationApply", app: app)
      let cancel = app.buttons["migrationCancel"]
      XCTAssertTrue(cancel.waitForExistence(timeout: 20))
      reveal(app.staticTexts["migrationRunID"], app: app)
      let runID = app.staticTexts["migrationRunID"].label
      XCTAssertFalse(runID.isEmpty)
      try await awaitExecutionCheckpoint(runID: try XCTUnwrap(Int(runID)), token: token)
      capture("\(testID)-running-before-cancel")
      tap("migrationCancel", app: app)
      XCTAssertTrue(app.buttons["migrationRetry"].waitForExistence(timeout: 30))
      XCTAssertEqual(app.staticTexts["migrationRunID"].label, runID)
      XCTAssertEqual(app.staticTexts["migrationRunState"].label, "failed")
      capture("\(testID)-cancelled")
      app.terminate()
      app.launch()
      tap("migrationImportEntry", app: app)
      XCTAssertTrue(app.buttons["migrationRetry"].waitForExistence(timeout: 30))
      XCTAssertEqual(app.staticTexts["migrationRunID"].label, runID)
      tap("migrationRetry", app: app)
      XCTAssertTrue(app.staticTexts["migrationReportSummary"].waitForExistence(timeout: 120))
      XCTAssertEqual(app.staticTexts["migrationRunID"].label, runID)
      XCTAssertEqual(app.staticTexts["migrationRunState"].label, "completed")
      XCTAssertTrue(app.staticTexts["migrationReportSummary"].label.contains("failed 0"))
      capture("\(testID)-same-run-retried-report")
      app.terminate()
      app.launch()
      tap("migrationImportEntry", app: app)
      XCTAssertTrue(app.staticTexts["migrationReportSummary"].waitForExistence(timeout: 30))
      XCTAssertEqual(app.staticTexts["migrationRunID"].label, runID)
      capture("\(testID)-report-relaunched")
      XCUIDevice.shared.orientation = .landscapeLeft
      capture("\(testID)-report-landscape")
      XCUIDevice.shared.orientation = .portrait
      try app.performAccessibilityAudit(for: [.contrast, .hitRegion, .sufficientElementDescription])
      let books = try XCTUnwrap(fixture["expectedBooks"] as? [[String: Any]])
      let ebook = try XCTUnwrap(books.first { $0["format"] as? String == "epub" })
      let ebookID = try XCTUnwrap(ebook["id"] as? Int)
      let ebookFileID = try XCTUnwrap(ebook["fileId"] as? Int)
      let saved = try await request("books/files/\(ebookFileID)/progress", token: token)
      XCTAssertEqual(saved["percentage"] as? Double, 77)
      let detail = try await request("books/\(ebookID)", token: token)
      XCTAssertEqual((detail["readStatus"] as? [String: Any])?["status"] as? String, "on_hold")
      let notes = try await request(
        "books/\(ebookID)/annotations?page=1&pageSize=100", token: token)
      let rows = try XCTUnwrap(notes["items"] as? [[String: Any]])
      XCTAssertEqual(rows.filter { $0["id"] as? Int == fixture["privateNoteId"] as? Int }.count, 1)
      if fixture["importsPassageNote"] as? Bool == true {
        XCTAssertEqual(
          rows.filter { $0["note"] as? String == "Imported permitted passage note" }.count, 1)
      }
      for book in books {
        let bookID = try XCTUnwrap(book["id"] as? Int)
        let format = try XCTUnwrap(book["format"] as? String)
        for reopen in 1...2 {
          tap("migrationBook\(bookID)", app: app)
          let read = app.buttons["readFile\(try XCTUnwrap(book["fileId"] as? Int))"]
          XCTAssertTrue(read.waitForExistence(timeout: 20))
          read.tap()
          try assertReader(format, expectsBookmarks: type == "audiobookshelf", app: app)
          capture("\(testID)-\(format)-reader-open-\(reopen)")
          closeReader(format, app: app)
          app.navigationBars.buttons.firstMatch.tap()
          XCTAssertTrue(app.staticTexts["migrationReportSummary"].waitForExistence(timeout: 20))
        }
      }
      app.buttons["Done"].tap()
      tap("openAnnotationHub", app: app)
      set(
        "annotationHubSearch", value: try XCTUnwrap(ebook["title"] as? String) + "\n",
        app: app)
      XCTAssertTrue(
        app.staticTexts[try XCTUnwrap(fixture["privateNote"] as? String)].waitForExistence(
          timeout: 20))
      if fixture["importsPassageNote"] as? Bool == true {
        XCTAssertTrue(
          app.staticTexts["Imported permitted passage note"].waitForExistence(timeout: 20))
      }
      capture("\(testID)-preserved-private-note-in-hub")
      tap("annotationHubDone", app: app)
      tap("migrationImportEntry", app: app)
      XCTAssertTrue(app.staticTexts["migrationReportSummary"].waitForExistence(timeout: 30))
    }
    _ = try await request(
      "auth/logout", body: ["refreshToken": try XCTUnwrap(credentials["refreshToken"] as? String)])
  }

  private func nativeFixtures() throws -> [[String: Any]] {
    let value = try XCTUnwrap(
      ProcessInfo.processInfo.environment["IPAD_MIGRATION_NATIVE_CONFIG"],
      "Retained controlled migration fixtures are required")
    let data =
      value.hasPrefix("[") ? Data(value.utf8) : try Data(contentsOf: URL(fileURLWithPath: value))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
  }

  @MainActor
  private func configure(_ fixture: [String: Any], app: XCUIApplication) throws {
    let type = try XCTUnwrap(fixture["type"] as? String)
    let config = try XCTUnwrap(fixture["connectionConfig"] as? [String: Any])
    let provider = [
      "booklore": "Booklore", "grimmory": "Grimmory", "audiobookshelf": "Audiobookshelf",
      "calibre_web_automated": "Calibre-Web Automated",
    ][type]!
    choose("migrationProvider", value: provider, app: app)
    set("migrationSourceName", value: try XCTUnwrap(fixture["name"] as? String), app: app)
    if type == "audiobookshelf" {
      choose(
        "migrationABSMode", value: config["mode"] as? String == "backup" ? "Backup" : "API",
        app: app)
      if config["mode"] as? String == "backup" {
        set("migrationBackupPath", value: try XCTUnwrap(config["backupPath"] as? String), app: app)
      } else {
        set("migrationBaseURL", value: try XCTUnwrap(config["baseUrl"] as? String), app: app)
        set(
          "migrationAPIToken", value: try XCTUnwrap(config["apiToken"] as? String), app: app,
          secure: true)
        let toggle = app.switches["Allow private network"]
        reveal(toggle, app: app)
        if toggle.value as? String == "0" { toggle.tap() }
      }
    } else if type == "calibre_web_automated" {
      set(
        "migrationAppDatabasePath", value: try XCTUnwrap(config["appDatabasePath"] as? String),
        app: app)
      set(
        "migrationMetadataDatabasePath",
        value: try XCTUnwrap(config["metadataDatabasePath"] as? String), app: app)
    } else {
      for (key, field) in [
        ("host", "migrationHost"), ("port", "migrationPort"), ("database", "migrationDatabase"),
        ("user", "migrationUsername"), ("password", "migrationPassword"),
        ("mediaRootPath", "migrationMediaRootPath"),
      ] {
        set(
          field, value: String(describing: config[key] ?? ""), app: app, secure: key == "password")
      }
    }
  }

  @MainActor
  private func assertReader(_ format: String, expectsBookmarks: Bool, app: XCUIApplication) throws {
    switch format {
    case "epub":
      XCTAssertTrue(app.buttons["epubCloseReader"].waitForExistence(timeout: 30))
      XCTAssertTrue(
        app.staticTexts.matching(
          NSPredicate(format: "label CONTAINS %@", "Migration source passage survives retry.")
        ).firstMatch.waitForExistence(timeout: 30))
    case "pdf":
      XCTAssertTrue(
        app.descendants(matching: .any)["pdfSourceInkCanvas"].waitForExistence(timeout: 30))
    case "cbz":
      XCTAssertTrue(app.images["comicPage1"].waitForExistence(timeout: 30))
      XCTAssertTrue(app.staticTexts["Page 1 of 1"].exists)
    case "mp3":
      XCTAssertTrue(
        app.staticTexts.matching(
          NSPredicate(
            format: "identifier == %@ AND label BEGINSWITH %@", "audiobookPlaybackTime", "0:04")
        ).firstMatch.waitForExistence(timeout: 30))
      XCTAssertTrue(
        app.buttons["audiobookPlayPause"].wait(for: \.isEnabled, toEqual: true, timeout: 20))
      if expectsBookmarks {
        tap("audiobookBookmarks", app: app)
        XCTAssertTrue(
          app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Imported audio bookmark")
          ).firstMatch.waitForExistence(timeout: 15))
        tap("audioBookmarksDone", app: app)
      }
    default: XCTFail("Unsupported migration reader format \(format)")
    }
  }

  @MainActor
  private func closeReader(_ format: String, app: XCUIApplication) {
    let id =
      ["epub": "epubCloseReader", "pdf": "pdfCloseReader", "mp3": "audiobookDone"][format]
      ?? "Close reader"
    tap(id, app: app)
  }

  @MainActor
  private func request(_ path: String, token: String? = nil, body: [String: Any]? = nil)
    async throws -> [String: Any]
  {
    let base =
      ProcessInfo.processInfo.environment["IPAD_E03_SERVER_URL"] ?? "http://localhost:16482"
    var request = URLRequest(url: try XCTUnwrap(URL(string: "\(base)/api/v1/\(path)")))
    request.timeoutInterval = 45
    request.httpMethod = body == nil ? "GET" : "POST"
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    XCTAssertTrue(
      (200..<300).contains(try XCTUnwrap(response as? HTTPURLResponse).statusCode),
      "\(path): \(String(decoding: data, as: UTF8.self))")
    if data.isEmpty { return [:] }
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
  }

  @MainActor
  private func failNextSourceBatch(_ control: [String: String]) async throws {
    var request = URLRequest(url: try XCTUnwrap(URL(string: try XCTUnwrap(control["url"]))))
    request.httpMethod = "POST"
    request.setValue(
      "Bearer \(try XCTUnwrap(control["token"]))", forHTTPHeaderField: "Authorization")
    let (_, response) = try await URLSession.shared.data(for: request)
    XCTAssertEqual(try XCTUnwrap(response as? HTTPURLResponse).statusCode, 200)
  }

  @MainActor
  private func awaitExecutionCheckpoint(runID: Int, token: String) async throws {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      let state = try await request("__faults/migration", token: token)
      if let observed = state["observed"] as? [String: Any], observed["runId"] as? Int == runID {
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTFail("The real migration must reach its controlled execution checkpoint before cancellation")
  }

  @MainActor
  private func launch(username: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    if !app.textFields["serverURL"].waitForExistence(timeout: 5) {
      if app.buttons["signOut"].exists { app.buttons["signOut"].tap() }
      if app.buttons["Change server"].exists { app.buttons["Change server"].tap() }
    }
    set(
      "serverURL",
      value: ProcessInfo.processInfo.environment["IPAD_E03_SERVER_URL"] ?? "http://localhost:16482",
      app: app)
    tap("connectServer", app: app)
    XCTAssertTrue(app.textFields["username"].waitForExistence(timeout: 15))
    set("username", value: username, app: app)
    set("password", value: "IpadFixture123", app: app, secure: true)
    tap("signIn", app: app)
    XCTAssertTrue(app.buttons["signOut"].waitForExistence(timeout: 20))
    return app
  }

  @MainActor
  private func choose(_ id: String, value: String, app: XCUIApplication) {
    let picker = app.buttons[id]
    reveal(picker, app: app)
    XCTAssertTrue(picker.waitForExistence(timeout: 10))
    picker.tap()
    let option = app.buttons[value]
    XCTAssertTrue(option.waitForExistence(timeout: 5))
    option.tap()
  }

  @MainActor
  private func set(_ id: String, value: String, app: XCUIApplication, secure: Bool = false) {
    let field = secure ? app.secureTextFields[id] : app.textFields[id]
    reveal(field, app: app)
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    field.tap()
    let old = field.value as? String ?? ""
    if old != field.placeholderValue {
      field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.utf16.count))
    }
    field.typeText(value)
  }

  @MainActor
  private func tap(_ id: String, app: XCUIApplication) {
    let button = app.buttons[id]
    reveal(button, app: app)
    XCTAssertTrue(button.waitForExistence(timeout: 15))
    button.tap()
  }

  @MainActor
  private func reveal(_ element: XCUIElement, app: XCUIApplication) {
    for _ in 0..<18 {
      if element.exists && element.isHittable { return }
      app.swipeUp()
    }
    for _ in 0..<36 {
      if element.exists && element.isHittable { return }
      app.swipeDown()
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
