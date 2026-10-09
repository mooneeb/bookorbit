import Foundation
import PencilKit
import XCTest

final class PassageEditingJourneyTests: XCTestCase {
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
      attach(image, name: "IPAD-E02-P2-passage-failure-\(name)", type: "public.png")
    }
    try await super.tearDown()
  }

  @MainActor
  func testIPADE02P2TaggedPencilReleaseReplayUndoSharedAnchorBlueInkAndDeniedEditing() async throws
  {
    let administrator = try await login("ipad-owner")
    let username = "ipad-passage-\(UUID().uuidString.lowercased())"
    let user = try await object(
      "users", method: "POST", token: administrator,
      body: [
        "username": username, "name": "Passage UI journey",
        "email": "\(username)@example.test",
        "permissionNames": ["library_download", "annotation_manage_own"],
      ])
    let userID = try XCTUnwrap(user["id"] as? Int)
    let cleanupURL = try XCTUnwrap(URL(string: "\(Self.serverURL)/api/v1/users/\(userID)"))
    addTeardownBlock {
      var request = URLRequest(url: cleanupURL)
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
    let fixtureBook = try await object("books/2", token: administrator)
    let libraryID = try XCTUnwrap(fixtureBook["libraryId"] as? Int)
    _ = try await request(
      "libraries/\(libraryID)/access", method: "POST", token: administrator,
      body: ["userId": userID, "accessLevel": "viewer"], expected: 201)
    let token = try await login(username)
    let currentUser = try await object("auth/me", token: token)
    XCTAssertEqual(currentUser["id"] as? Int, userID)
    XCTAssertEqual(currentUser["isSuperuser"] as? Bool, false)
    XCTAssertEqual(
      Set(currentUser["permissions"] as? [String] ?? []),
      Set(["library_download", "annotation_manage_own"]))
    _ = try await request("books/2", token: token, expected: 200)
    let initial = try await annotations(token)
    XCTAssertTrue(initial.isEmpty)
    let app = launchAndSignIn(username)
    openEPUB(app)
    guard enterWritingMode(app) else { return }
    if app.buttons["pencilWritingMode"].value as? String != "Writing" {
      captureWritingModeFailure(app)
    }
    XCTAssertEqual(app.buttons["pencilWritingMode"].value as? String, "Writing")
    tap("epubFixturePencilRelease", app)
    XCTAssertFalse(app.staticTexts["passageSelectionPreview"].exists)
    let released = try await waitForAnnotations(token) { rows in rows.count == 1 }
    let highlight = try XCTUnwrap(released.first)
    let highlightID = try XCTUnwrap(highlight["id"] as? Int)
    XCTAssertEqual(highlight["kind"] as? String, "highlight")
    XCTAssertTrue((highlight["cfi"] as? String ?? "").hasPrefix("epubcfi("))
    XCTAssertEqual(highlight["text"] as? String, "Alpha 😀 café omega.")
    XCTAssertEqual(highlight["version"] as? Int, 1)
    capture("IPAD-E02-P2-tagged-Pencil-release-single-highlight")
    tap("epubFixtureRepeatPencilRelease", app)
    tap("epubFixtureRepeatPencilRelease", app)
    tap("passageUndo", app)
    let undone = try await waitForAnnotations(token) { rows in
      rows.contains { $0["id"] as? Int == highlightID && $0["deletedAt"] is String }
    }
    XCTAssertEqual(undone.count, 1, "Repeated release must preserve one canonical operation")
    XCTAssertTrue(undone.allSatisfy { $0["deletedAt"] is String })
    capture("IPAD-E02-P2-tagged-Pencil-replay-single-Undo")
    var known = Set(undone.compactMap { $0["id"] as? Int })
    var created: [[String: Any]] = []
    for (kind, label) in [
      ("highlight", "Highlight"), ("text_note", "Text note"), ("handwriting", "Handwriting"),
    ] {
      tap("epubFixtureSelectPassage", app)
      tap("epubMarkPassage", app)
      XCTAssertTrue(app.staticTexts["passageSelectionPreview"].waitForExistence(timeout: 10))
      tap(label, app)
      if kind == "text_note" { tap("passageFixtureScribble", app) }
      if kind == "handwriting" {
        tap("passageFixtureBlueStroke", app)
        XCTAssertTrue(app.staticTexts["1 retained strokes"].waitForExistence(timeout: 5))
        capture("IPAD-E02-P2-tagged-blue-transformed-PKDrawing-preview")
      }
      tap("passageSave", app)
      XCTAssertTrue(
        app.staticTexts["passageSelectionPreview"].wait(for: \.exists, toEqual: false, timeout: 10))
      let previous = known
      let rows = try await waitForAnnotations(token) { items in
        items.contains {
          !previous.contains($0["id"] as? Int ?? -1) && $0["kind"] as? String == kind
        }
      }
      let item = try XCTUnwrap(
        rows.first { !previous.contains($0["id"] as? Int ?? -1) && $0["kind"] as? String == kind })
      known.insert(try XCTUnwrap(item["id"] as? Int))
      created.append(item)
    }
    XCTAssertEqual(Set(created.compactMap { $0["cfi"] as? String }).count, 1)
    let handwriting = try XCTUnwrap(created.first { $0["kind"] as? String == "handwriting" })
    let handwritingID = try XCTUnwrap(handwriting["id"] as? Int)
    let drawing = try XCTUnwrap(handwriting["drawing"] as? [String: Any])
    let strokes = try XCTUnwrap(drawing["strokes"] as? [[String: Any]])
    XCTAssertEqual(strokes.count, 1)
    XCTAssertEqual(strokes.first?["color"] as? String, "#0000FF")
    XCTAssertEqual(strokes.first?["width"] as? Double, 12)
    let points = try XCTUnwrap(strokes.first?["points"] as? [[String: Any]])
    XCTAssertEqual(try XCTUnwrap(points.first?["x"] as? Double), 72, accuracy: 0.01)
    XCTAssertEqual(try XCTUnwrap(points.first?["y"] as? Double), 84, accuracy: 0.01)
    let nativeData = try XCTUnwrap(
      Data(base64Encoded: try XCTUnwrap(drawing["nativeData"] as? String)))
    let retained = try PKDrawing(data: nativeData)
    let nativeStroke = try XCTUnwrap(retained.strokes.first)
    XCTAssertEqual(retained.strokes.count, 1)
    XCTAssertEqual(nativeStroke.ink.color, UIColor.blue)
    XCTAssertEqual(nativeStroke.transform.a, 2)
    XCTAssertEqual(nativeStroke.transform.d, 2)
    XCTAssertEqual(nativeStroke.path.first?.size.width, 6)
    attach(nativeData, name: "IPAD-E02-P2-retained-blue-transformed-PKDrawing", type: "public.data")
    tap("epubFixtureSelectPassage", app)
    XCTAssertTrue(app.staticTexts["1 retained strokes"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.descendants(matching: .any)["passageInkCanvas"].exists)
    XCTAssertFalse(app.textViews["passageNoteText"].exists)
    capture("IPAD-E02-P2-same-anchor-opens-retained-handwriting")
    tap("passageCancel", app)
    tap("epubCloseReader", app)
    tap("signOut", app)
    app.terminate()
    _ = try await request(
      "users/\(userID)/permissions", method: "PUT", token: administrator,
      body: ["permissionNames": ["library_download"]])
    let deniedToken = try await login(username)
    let deniedUser = try await object("auth/me", token: deniedToken)
    XCTAssertFalse((deniedUser["permissions"] as? [String] ?? []).contains("annotation_manage_own"))
    let beforeDenied = try await annotations(deniedToken)
    let denied = launchAndSignIn(username)
    openEPUB(denied)
    tap("epubFixtureSelectPassage", denied)
    XCTAssertTrue(denied.staticTexts["1 retained strokes"].waitForExistence(timeout: 10))
    XCTAssertFalse(denied.buttons["passageSave"].exists)
    XCTAssertFalse(denied.buttons["passageDelete"].exists)
    tap("passageCancel", denied)
    XCTAssertFalse(denied.buttons["epubMarkPassage"].exists)
    XCTAssertFalse(denied.buttons["epubFixturePencilRelease"].exists)
    XCTAssertFalse(denied.buttons["passageUndo"].isEnabled)
    capture("IPAD-E02-P2-denied-private-passage-editing-controls")
    let afterDenied = try await annotations(deniedToken)
    XCTAssertEqual(
      try JSONSerialization.data(withJSONObject: afterDenied, options: [.sortedKeys]),
      try JSONSerialization.data(withJSONObject: beforeDenied, options: [.sortedKeys]))
    _ = try await request(
      "annotations/native/operations", method: "POST", token: deniedToken,
      body: [
        "deviceId": UUID().uuidString,
        "operations": [
          [
            "operationId": UUID().uuidString,
            "clientId": try XCTUnwrap(handwriting["clientId"] as? String),
            "annotationId": handwritingID, "bookId": 2,
            "baseVersion": try XCTUnwrap(handwriting["version"] as? Int), "action": "delete",
          ]
        ],
      ], expected: 403)
    let afterRefusal = try await annotations(deniedToken)
    XCTAssertEqual(
      try JSONSerialization.data(withJSONObject: afterRefusal, options: [.sortedKeys]),
      try JSONSerialization.data(withJSONObject: beforeDenied, options: [.sortedKeys]))
  }

  @MainActor private func launchAndSignIn(_ username: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "--annotation-input-driver",
    ]
    app.launchEnvironment["BOOKORBIT_ANNOTATION_INPUT_FIXTURE"] = "1"
    E02ProfileSupport.configure(app)
    app.launch()
    if !app.textFields["serverURL"].waitForExistence(timeout: 3) {
      for _ in 0..<6 where !app.buttons["signOut"].exists {
        if app.buttons["passageCancel"].exists {
          app.buttons["passageCancel"].tap()
        } else if app.buttons["epubCloseReader"].exists {
          app.buttons["epubCloseReader"].tap()
        } else if app.buttons["pdfCloseReader"].exists {
          app.buttons["pdfCloseReader"].tap()
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
    replaceText(server, Self.serverURL)
    tap("connectServer", app)
    guard E02ProfileSupport.ensureSignInForm(app: app, serverURL: Self.serverURL) else {
      return app
    }
    XCTAssertTrue(app.textFields["username"].waitForExistence(timeout: 10))
    replaceText(app.textFields["username"], username)
    replaceText(app.secureTextFields["password"], "IpadFixture123")
    tap("signIn", app)
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 25))
    return app
  }

  @MainActor private func openEPUB(_ app: XCUIApplication) {
    if app.buttons["All books"].exists { app.buttons["All books"].tap() }
    tap("Table", app)
    let search = app.textViews["librarySearch"]
    XCTAssertTrue(search.wait(for: \.isHittable, toEqual: true, timeout: 10))
    replaceText(search, "Native renderer proof")
    search.typeText("\n")
    tap("tableOpen2_title", app)
    tap("Book details", app)
    guard E02ProfileSupport.openBookFile(app: app, fileID: 2) else { return }
    XCTAssertTrue(app.buttons["epubFixtureSelectPassage"].waitForExistence(timeout: 20))
  }

  @MainActor private func tap(_ id: String, _ app: XCUIApplication) {
    let button = app.buttons[id]
    XCTAssertTrue(button.wait(for: \.isHittable, toEqual: true, timeout: 10), id)
    XCTAssertTrue(button.wait(for: \.isEnabled, toEqual: true, timeout: 10), id)
    button.tap()
  }

  @MainActor private func enterWritingMode(_ app: XCUIApplication) -> Bool {
    let modes = app.buttons.matching(identifier: "pencilWritingMode")
    let mode = modes.element
    let panels = app.scrollViews.containing(.button, identifier: "pencilWritingMode")
    let windows = app.windows.containing(.button, identifier: "pencilWritingMode")
    guard modes.firstMatch.waitForExistence(timeout: 10), modes.count == 1,
      mode.wait(for: \.isEnabled, toEqual: true, timeout: 10),
      mode.wait(for: \.isHittable, toEqual: true, timeout: 10),
      panels.count == 1, windows.count == 1,
      panels.element.frame.intersection(windows.element.frame).contains(mode.frame)
    else {
      captureWritingModeFailure(app)
      XCTFail("Expected one enabled, hittable writing mode control fully inside its reader panel.")
      return false
    }
    mode.tap()
    let writing = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "Writing"), object: mode)
    guard XCTWaiter.wait(for: [writing], timeout: 10) == .completed else {
      captureWritingModeFailure(app)
      XCTFail("Writing mode did not become observable within 10 seconds after its single ID tap.")
      XCTAssertEqual(mode.value as? String, "Writing")
      return false
    }
    XCTAssertEqual(mode.value as? String, "Writing")
    return true
  }

  @MainActor private func captureWritingModeFailure(_ app: XCUIApplication) {
    attach(
      Data(app.debugDescription.utf8), name: "IPAD-E02-P2-writing-mode-failure-AX",
      type: "public.plain-text")
    capture("IPAD-E02-P2-writing-mode-failure-visible")
  }

  @MainActor private func replaceText(_ field: XCUIElement, _ value: String) {
    field.tap()
    let existing = field.value as? String ?? ""
    XCTAssertLessThanOrEqual(existing.utf16.count, 512)
    if !existing.isEmpty && existing != field.placeholderValue {
      field.typeText(
        String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.utf16.count))
    }
    field.typeText(value)
  }

  @MainActor private func login(_ username: String) async throws -> String {
    let credentials = try await object(
      "auth/login", method: "POST",
      body: [
        "username": username, "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "Passage assertion client",
      ])
    let refresh = try XCTUnwrap(credentials["refreshToken"] as? String)
    let endpoint = try XCTUnwrap(URL(string: "\(Self.serverURL)/api/v1/auth/logout"))
    addTeardownBlock {
      var request = URLRequest(url: endpoint)
      request.httpMethod = "POST"
      request.timeoutInterval = 5
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: ["refreshToken": refresh])
      let (_, response) = try await Self.network.data(for: request)
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }
    return try XCTUnwrap(credentials["accessToken"] as? String)
  }

  @MainActor private func request(
    _ path: String, method: String = "GET", token: String? = nil,
    body: [String: Any]? = nil, expected: Int? = nil
  ) async throws -> Data {
    var request = URLRequest(url: try XCTUnwrap(URL(string: "\(Self.serverURL)/api/v1/\(path)")))
    request.httpMethod = method
    request.timeoutInterval = 5
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await Self.network.data(for: request)
    let status = try XCTUnwrap((response as? HTTPURLResponse)?.statusCode)
    if let expected {
      XCTAssertEqual(status, expected, path)
    } else {
      XCTAssertTrue((200..<300).contains(status), path)
    }
    return data
  }

  @MainActor private func object(
    _ path: String, method: String = "GET", token: String? = nil, body: [String: Any]? = nil
  ) async throws -> [String: Any] {
    let data = try await request(path, method: method, token: token, body: body)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @MainActor private func annotations(_ token: String) async throws -> [[String: Any]] {
    let page = try await object(
      "annotations/native/delta?bookId=2&cursor=0&limit=100", token: token)
    XCTAssertEqual(page["hasMore"] as? Bool, false, "The isolated journey must remain bounded")
    return try XCTUnwrap(page["items"] as? [[String: Any]])
  }

  @MainActor private func waitForAnnotations(
    _ token: String, condition: ([[String: Any]]) -> Bool
  ) async throws -> [[String: Any]] {
    let deadline = Date().addingTimeInterval(20)
    var rows = try await annotations(token)
    while !condition(rows) && Date() < deadline {
      try await Task.sleep(for: .milliseconds(250))
      rows = try await annotations(token)
    }
    XCTAssertTrue(condition(rows), "Public annotation state did not converge")
    attach(
      try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys, .prettyPrinted]),
      name: "IPAD-E02-P2-public-passage-delta", type: "public.json")
    return rows
  }

  private func attach(_ data: Data, name: String, type: String) {
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: type)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "\(name)-\(E02ProfileSupport.name)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
