import CryptoKit
import Foundation
import XCTest

final class PDFPassageJourneyTests: XCTestCase {
  private nonisolated static let network: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 5
    configuration.timeoutIntervalForResource = 8
    configuration.waitsForConnectivity = false
    return URLSession(configuration: configuration)
  }()

  private nonisolated static var serverURL: String {
    var components = URLComponents(
      string: ProcessInfo.processInfo.environment["IPAD_ANNOTATION_SERVER_URL"]
        ?? "http://127.0.0.1:16482")!
    if components.host == "localhost" { components.host = "127.0.0.1" }
    if components.path == "/api/v1" { components.path = "" }
    return components.string!.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
  }

  override func tearDown() async throws {
    if let testRun, testRun.failureCount > 0 {
      let image = await MainActor.run { XCUIScreen.main.screenshot().pngRepresentation }
      attach(image, name: "IPAD-E02-A01-PDF-private-failure-\(name)", type: "public.png")
    }
    try await super.tearDown()
  }

  @MainActor
  func testIPADE02A01PDFPrivatePassagesCreateEditRetainDeleteUndoAndKeepSourceBytes() async throws {
    let administrator = try await login("ipad-owner")
    let account = try await createPassageAccount(administrator: administrator)
    let token = try await login(account.username)
    let user = try await object("auth/me", token: token)
    XCTAssertEqual(user["id"] as? Int, account.id)
    XCTAssertTrue((user["permissions"] as? [String] ?? []).contains("annotation_manage_own"))
    let book = try await object("books/1", token: token)
    let title = try XCTUnwrap(book["title"] as? String)
    let files = try XCTUnwrap(book["files"] as? [[String: Any]])
    let fileID = try XCTUnwrap(files.first { $0["format"] as? String == "pdf" }?["id"] as? Int)
    let source = try await request("books/files/\(fileID)/serve", token: token)
    let baseline = try await annotations(token)
    var known = Set(baseline.compactMap { $0["id"] as? Int })
    let app = launchAndSignIn(account.username)
    openPDF(title: title, fileID: fileID, app: app)
    var created: [[String: Any]] = []
    for (kind, label) in [
      ("highlight", "Highlight"), ("text_note", "Text note"), ("handwriting", "Handwriting"),
    ] {
      preview(app)
      tap(label, app)
      if kind == "text_note" {
        tap("pdfPassageFixtureScribble", app)
        let scribble = XCTNSPredicateExpectation(
          predicate: NSPredicate(format: "value == %@", "Converted English passage fixture"),
          object: app.textViews["passageNoteText"])
        XCTAssertEqual(XCTWaiter.wait(for: [scribble], timeout: 5), .completed)
      }
      if kind == "handwriting" {
        tap("pdfPassageFixtureStroke", app)
        XCTAssertTrue(app.staticTexts["1 retained strokes"].waitForExistence(timeout: 5))
      }
      capture("IPAD-E02-A01-PDF-\(kind)-semantic-private-preview")
      tap("pdfPassageSave", app)
      XCTAssertTrue(
        app.staticTexts["pdfPassageSelectionPreview"].wait(
          for: \.exists, toEqual: false, timeout: 10))
      let oldIDs = known
      let items = try await waitForAnnotations(token) { rows in
        rows.filter { !oldIDs.contains($0["id"] as? Int ?? -1) && $0["kind"] as? String == kind }
          .count == 1
      }
      let saved = try XCTUnwrap(
        items.first { !oldIDs.contains($0["id"] as? Int ?? -1) && $0["kind"] as? String == kind })
      let id = try XCTUnwrap(saved["id"] as? Int)
      known.insert(id)
      created.append(saved)
      XCTAssertEqual(saved["jumpFileId"] as? Int, fileID)
      XCTAssertTrue(saved["pdf"] is [String: Any])
      XCTAssertTrue((saved["sourceRevision"] as? String ?? "").hasPrefix("sha256:"))
      XCTAssertFalse((saved["pageFingerprint"] as? String ?? "").isEmpty)
      XCTAssertEqual(saved["version"] as? Int, 1)
      let delivered = try await request("books/files/\(fileID)/serve", token: token)
      XCTAssertEqual(delivered, source)
    }
    let handwritten = try XCTUnwrap(created.first { $0["kind"] as? String == "handwriting" })
    let id = try XCTUnwrap(handwritten["id"] as? Int)
    let originalDrawing = try XCTUnwrap(handwritten["drawing"] as? [String: Any])
    let strokes = try XCTUnwrap(originalDrawing["strokes"] as? [[String: Any]])
    XCTAssertEqual(strokes.count, 1)
    XCTAssertEqual(strokes.first?["color"] as? String, "#0000FF")
    XCTAssertEqual(strokes.first?["width"] as? Double, 12)
    let originalNative = try XCTUnwrap(originalDrawing["nativeData"] as? String)
    attach(
      try XCTUnwrap(Data(base64Encoded: originalNative)),
      name: "IPAD-E02-A01-PDF-original-retained-PKDrawing", type: "public.data")
    openNote(id, app)
    XCTAssertTrue(app.staticTexts["1 retained strokes"].waitForExistence(timeout: 5))
    tap("pdfPassageFixtureStroke", app)
    XCTAssertTrue(app.staticTexts["2 retained strokes"].waitForExistence(timeout: 5))
    tap("pdfPassageSave", app)
    let edited = try await waitForAnnotations(token) { rows in
      rows.contains { $0["id"] as? Int == id && ($0["version"] as? Int ?? 0) > 1 }
    }
    let editedItem = try XCTUnwrap(edited.first { $0["id"] as? Int == id })
    let editedDrawing = try XCTUnwrap(editedItem["drawing"] as? [String: Any])
    let editedStrokes = try XCTUnwrap(editedDrawing["strokes"] as? [[String: Any]])
    XCTAssertEqual(editedStrokes.count, 2)
    XCTAssertEqual(editedStrokes.first?["id"] as? String, strokes.first?["id"] as? String)
    XCTAssertEqual(editedStrokes.first?["color"] as? String, "#0000FF")
    XCTAssertNotEqual(editedDrawing["nativeData"] as? String, originalNative)
    tap("pdfCloseReader", app)
    app.terminate()
    E02ProfileSupport.configure(app)
    app.launch()
    XCTAssertTrue(app.buttons["signOut"].waitForExistence(timeout: 20))
    openPDF(title: title, fileID: fileID, app: app)
    openNote(id, app)
    XCTAssertTrue(app.staticTexts["2 retained strokes"].waitForExistence(timeout: 10))
    capture("IPAD-E02-A01-PDF-retained-colored-drawing-after-restart")
    tap("pdfPassageDelete", app)
    let deleted = try await waitForAnnotations(token) { rows in
      rows.contains { $0["id"] as? Int == id && $0["deletedAt"] is String }
    }
    let deletedVersion = try XCTUnwrap(deleted.first { $0["id"] as? Int == id }?["version"] as? Int)
    tap("pdfPassageUndo", app)
    let restored = try await waitForAnnotations(token) { rows in
      rows.contains {
        $0["id"] as? Int == id && $0["deletedAt"] is NSNull
          && ($0["version"] as? Int ?? 0) > deletedVersion
      }
    }
    let restoredItem = try XCTUnwrap(restored.first { $0["id"] as? Int == id })
    let restoredDrawing = try XCTUnwrap(restoredItem["drawing"] as? [String: Any])
    XCTAssertEqual(restoredDrawing["nativeData"] as? String, editedDrawing["nativeData"] as? String)
    let delivered = try await request("books/files/\(fileID)/serve", token: token)
    XCTAssertEqual(delivered, source)
    attach(
      source, name: "IPAD-E02-A01-PDF-unchanged-private-source-\(checksum(source))",
      type: "com.adobe.pdf")
    capture("IPAD-E02-A01-PDF-versioned-private-delete-Undo-restored")
    tap("pdfCloseReader", app)
    tap("signOut", app)
    app.terminate()
    try await setPassagePermission(account.id, allowed: false, administrator: administrator)
    let readerToken = try await login(account.username)
    let deniedUser = try await object("auth/me", token: readerToken)
    XCTAssertEqual(deniedUser["id"] as? Int, account.id)
    XCTAssertFalse((deniedUser["permissions"] as? [String] ?? []).contains("annotation_manage_own"))
    XCTAssertTrue((deniedUser["permissions"] as? [String] ?? []).contains("library_download"))
    let privateRows = try await annotations(readerToken)
    let owned = try XCTUnwrap(privateRows.first { $0["id"] as? Int == id })
    XCTAssertEqual(owned["clientId"] as? String, restoredItem["clientId"] as? String)
    XCTAssertEqual(owned["version"] as? Int, restoredItem["version"] as? Int)
    let reader = launchAndSignIn(account.username)
    openPDF(title: title, fileID: fileID, app: reader)
    XCTAssertTrue(reader.buttons["pdfPassagePreview"].waitForExistence(timeout: 15))
    XCTAssertFalse(reader.buttons["pdfPassagePreview"].isEnabled)
    XCTAssertFalse(reader.buttons["pdfPassageUndo"].isEnabled)
    XCTAssertFalse(reader.buttons["pdfPassageFixtureSelection"].isEnabled)
    openNote(id, reader)
    XCTAssertTrue(reader.staticTexts["2 retained strokes"].waitForExistence(timeout: 10))
    XCTAssertFalse(reader.buttons["pdfPassageSave"].isEnabled)
    XCTAssertFalse(reader.buttons["pdfPassageDelete"].isEnabled)
    XCTAssertFalse(reader.buttons["pdfPassageFixtureStroke"].isEnabled)
    capture("IPAD-E02-A01-PDF-owned-private-note-denied-controls")
    tap("pdfPassageCancel", reader)
    _ = try await request(
      "annotations/native/operations", method: "POST", token: readerToken,
      body: [
        "deviceId": UUID().uuidString,
        "operations": [
          [
            "operationId": UUID().uuidString,
            "clientId": try XCTUnwrap(owned["clientId"] as? String),
            "annotationId": id, "bookId": 1,
            "baseVersion": try XCTUnwrap(owned["version"] as? Int), "action": "delete",
          ]
        ],
      ], expected: 403)
    let afterDenial = try await annotations(readerToken)
    XCTAssertEqual(
      try JSONSerialization.data(withJSONObject: afterDenial, options: [.sortedKeys]),
      try JSONSerialization.data(withJSONObject: privateRows, options: [.sortedKeys]))
    let finalSource = try await request("books/files/\(fileID)/serve", token: readerToken)
    XCTAssertEqual(finalSource, source)
    try await setPassagePermission(account.id, allowed: true, administrator: administrator)
    let restoredToken = try await login(account.username)
    let restoredUser = try await object("auth/me", token: restoredToken)
    XCTAssertTrue(
      (restoredUser["permissions"] as? [String] ?? []).contains("annotation_manage_own"))
  }

  @MainActor private func createPassageAccount(administrator: String) async throws
    -> (username: String, id: Int)
  {
    let username = "ipad-pdf-passage-\(UUID().uuidString.lowercased())"
    let data = try await request(
      "users", method: "POST", token: administrator,
      body: [
        "username": username, "name": "PDF passage UI journey",
        "email": "\(username)@example.test",
        "permissionNames": ["library_download", "annotation_manage_own"],
      ])
    let user = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let userID = try XCTUnwrap(user["id"] as? Int)
    let endpoint = try XCTUnwrap(URL(string: "\(Self.serverURL)/api/v1/users/\(userID)"))
    addTeardownBlock {
      var request = URLRequest(url: endpoint)
      request.httpMethod = "DELETE"
      request.timeoutInterval = 5
      request.setValue("Bearer \(administrator)", forHTTPHeaderField: "Authorization")
      let (_, response) = try await Self.network.data(for: request)
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
    }
    let resetURL = try XCTUnwrap(user["resetUrl"] as? String)
    let resetToken = try XCTUnwrap(
      URLComponents(string: resetURL)?.queryItems?.first { $0.name == "token" }?.value)
    _ = try await request(
      "auth/reset-password", method: "POST",
      body: ["token": resetToken, "newPassword": "IpadFixture123"])
    return (username, userID)
  }

  @MainActor private func setPassagePermission(
    _ userID: Int, allowed: Bool, administrator: String
  ) async throws {
    let permissions = ["library_download"] + (allowed ? ["annotation_manage_own"] : [])
    _ = try await request(
      "users/\(userID)/permissions", method: "PUT", token: administrator,
      body: ["permissionNames": permissions], expected: 204)
  }

  @MainActor private func preview(_ app: XCUIApplication) {
    tap("pdfPassageSelectText", app)
    tap("pdfPassageFixtureSelection", app)
    XCTAssertTrue(app.staticTexts["pdfPassageSelectedText"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.staticTexts["pdfPassageSelectedText"].label.contains("Orbit fixture: passage 1"))
    tap("pdfPassagePreview", app)
    XCTAssertTrue(app.staticTexts["pdfPassageSelectionPreview"].waitForExistence(timeout: 10))
    XCTAssertTrue(
      app.staticTexts["pdfPassageSelectionPreview"].label.contains("Orbit fixture: passage 1"))
  }

  @MainActor private func openNote(_ id: Int, _ app: XCUIApplication) {
    tap("pdfPassageNotes", app)
    tap("pdfPassageOpen\(id)", app)
    XCTAssertTrue(app.staticTexts["pdfPassageSelectionPreview"].waitForExistence(timeout: 10))
  }

  @MainActor private func tap(_ id: String, _ app: XCUIApplication) {
    let element = app.buttons[id]
    XCTAssertTrue(element.wait(for: \.isHittable, toEqual: true, timeout: 15), id)
    XCTAssertTrue(element.wait(for: \.isEnabled, toEqual: true, timeout: 10), id)
    element.tap()
  }

  @MainActor private func launchAndSignIn(_ user: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "--annotation-input-driver",
    ]
    app.launchEnvironment["BOOKORBIT_ANNOTATION_INPUT_FIXTURE"] = "1"
    E02ProfileSupport.configure(app)
    app.launch()
    if app.buttons["signOut"].waitForExistence(timeout: 3) { app.buttons["signOut"].tap() }
    if app.buttons["Change server"].exists { app.buttons["Change server"].tap() }
    let server = app.textFields["serverURL"]
    XCTAssertTrue(server.waitForExistence(timeout: 10))
    replace(server, Self.serverURL)
    tap("connectServer", app)
    guard E02ProfileSupport.ensureSignInForm(app: app, serverURL: Self.serverURL) else {
      return app
    }
    XCTAssertTrue(app.textFields["username"].waitForExistence(timeout: 10))
    replace(app.textFields["username"], user)
    replace(app.secureTextFields["password"], "IpadFixture123")
    tap("signIn", app)
    XCTAssertTrue(app.buttons["signOut"].waitForExistence(timeout: 25))
    return app
  }

  @MainActor private func openPDF(title: String, fileID: Int, app: XCUIApplication) {
    if app.buttons["All books"].exists { app.buttons["All books"].tap() }
    tap("Table", app)
    let search = app.textViews["librarySearch"]
    XCTAssertTrue(search.wait(for: \.isHittable, toEqual: true, timeout: 10))
    replace(search, title)
    search.typeText("\n")
    tap("tableOpen1_title", app)
    tap("Book details", app)
    XCTAssertTrue(app.navigationBars["Book details"].waitForExistence(timeout: 10))
    guard E02ProfileSupport.openBookFile(app: app, fileID: fileID) else { return }
    XCTAssertTrue(app.buttons["pdfPassagePreview"].waitForExistence(timeout: 20))
  }

  @MainActor private func replace(_ field: XCUIElement, _ text: String) {
    field.tap()
    let old = field.value as? String ?? ""
    if old != field.placeholderValue {
      field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.utf16.count))
    }
    field.typeText(text)
  }

  @MainActor private func login(_ username: String) async throws -> String {
    let data = try await request(
      "auth/login", method: "POST",
      body: [
        "username": username, "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "PDF private passage assertion client",
      ])
    let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let refresh = try XCTUnwrap(value["refreshToken"] as? String)
    let endpoint = try XCTUnwrap(URL(string: "\(Self.serverURL)/api/v1/auth/logout"))
    addTeardownBlock {
      var request = URLRequest(url: endpoint)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: ["refreshToken": refresh])
      let (_, response) = try await Self.network.data(for: request)
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }
    return try XCTUnwrap(value["accessToken"] as? String)
  }

  @MainActor private func request(
    _ path: String, method: String = "GET", token: String? = nil, body: [String: Any]? = nil,
    expected: Int? = nil
  ) async throws -> Data {
    var request = URLRequest(url: try XCTUnwrap(URL(string: "\(Self.serverURL)/api/v1/\(path)")))
    request.httpMethod = method
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await Self.network.data(for: request)
    let status = try XCTUnwrap(response as? HTTPURLResponse).statusCode
    if let expected {
      XCTAssertEqual(status, expected)
    } else {
      XCTAssertTrue((200..<300).contains(status), path)
    }
    XCTAssertLessThanOrEqual(data.count, 24 * 1024 * 1024)
    return data
  }

  @MainActor private func object(_ path: String, token: String) async throws -> [String: Any] {
    let data = try await request(path, token: token)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @MainActor private func annotations(_ token: String) async throws -> [[String: Any]] {
    let value = try await object(
      "annotations/native/delta?bookId=1&cursor=0&limit=100", token: token)
    XCTAssertEqual(value["hasMore"] as? Bool, false)
    return try XCTUnwrap(value["items"] as? [[String: Any]])
  }

  @MainActor private func waitForAnnotations(_ token: String, matches: ([[String: Any]]) -> Bool)
    async throws -> [[String: Any]]
  {
    let deadline = Date().addingTimeInterval(25)
    var rows = try await annotations(token)
    while !matches(rows) && Date() < deadline {
      try await Task.sleep(for: .milliseconds(250))
      rows = try await annotations(token)
    }
    XCTAssertTrue(matches(rows), "Private canonical state did not converge")
    attach(
      try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]),
      name: "IPAD-E02-A01-PDF-private-canonical", type: "public.json")
    return rows
  }

  @MainActor private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "\(name)-\(E02ProfileSupport.name)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func checksum(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  private func attach(_ data: Data, name: String, type: String) {
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: type)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
