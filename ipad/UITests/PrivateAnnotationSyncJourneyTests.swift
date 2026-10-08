import Foundation
import PencilKit
import XCTest

final class PrivateAnnotationSyncJourneyTests: XCTestCase {
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
      attach(image, name: "IPAD-E02-A05-private-sync-failure-\(name)", type: "public.png")
    }
    try await super.tearDown()
  }

  @MainActor
  func testIPADE02A05PrivateEPUBAutomaticallyDiscoversRemoteChangesAndKeepsDirtyDraft() async throws
  {
    let administrator = try await login("ipad-owner")
    let username = "ipad-private-sync-\(UUID().uuidString.lowercased())"
    let user = try await object(
      "users", method: "POST", token: administrator,
      body: [
        "username": username, "name": "Private sync UI journey",
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
    let token = try await login(username)
    try await fault("reset")
    let proxy = Self.faultURL
    let reconnectURL = try XCTUnwrap(URL(string: "\(proxy)/__faults/annotations/online"))
    addTeardownBlock {
      var request = URLRequest(url: reconnectURL)
      request.httpMethod = "POST"
      request.timeoutInterval = 5
      let (_, response) = try await Self.network.data(for: request)
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
    }
    let sourceBytes = try await request("books/files/2/serve", token: token)
    let app = launchAndSignIn(username, serverURL: proxy)
    openEPUB(app)
    tap("epubFixtureSelectPassage", app)
    tap("epubMarkPassage", app)
    tap("Handwriting", app)
    tap("passageFixtureBlueStroke", app)
    XCTAssertTrue(app.staticTexts["1 retained strokes"].waitForExistence(timeout: 5))
    tap("passageSave", app)
    XCTAssertTrue(
      app.staticTexts["passageSelectionPreview"].wait(for: \.exists, toEqual: false, timeout: 10))
    let initial = try await waitForAnnotations(token) { $0.count == 1 }
    let handwriting = try XCTUnwrap(initial.first)
    let handwritingID = try XCTUnwrap(handwriting["id"] as? Int)
    let cfi = try XCTUnwrap(handwriting["cfi"] as? String)
    let passage = try XCTUnwrap(handwriting["text"] as? String)
    let drawing = try XCTUnwrap(handwriting["drawing"] as? [String: Any])
    let position = app.staticTexts["epubReadingPosition"]
    XCTAssertTrue(position.waitForExistence(timeout: 10))
    let originalPosition = position.label
    let syncState = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", "0 pending changes"),
      object: app.staticTexts["passageSyncState"])
    XCTAssertEqual(XCTWaiter.wait(for: [syncState], timeout: 20), .completed)
    let writesBefore = try await nativeWriteCount()
    var cursor = try await completedPullCount()
    let remote = try await operation(
      token, action: "create",
      payload: [
        "bookFileId": 2, "cfi": cfi, "text": passage, "kind": "text_note",
        "note": "Private automatic discovery", "color": "#FACC15", "style": "highlight",
      ])
    let remoteID = try XCTUnwrap(remote["id"] as? Int)
    try await waitForPull(after: cursor)
    openNote(remoteID, app)
    XCTAssertEqual(app.textViews["passageNoteText"].value as? String, "Private automatic discovery")
    capture("IPAD-E02-A05-private-automatic-idle-create")
    tap("passageCancel", app)
    cursor = try await completedPullCount()
    let updated = try await operation(
      token, action: "update", item: remote, payload: ["note": "Private automatic update"])
    try await waitForPull(after: cursor)
    openNote(remoteID, app)
    XCTAssertEqual(app.textViews["passageNoteText"].value as? String, "Private automatic update")
    capture("IPAD-E02-A05-private-automatic-idle-update")
    tap("passageCancel", app)
    let idleWrites = try await nativeWriteCount()
    XCTAssertEqual(
      idleWrites, writesBefore, "Idle discovery must not require a local annotation write")
    openNote(handwritingID, app)
    try await fault("offline")
    tap("passageFixtureStroke", app)
    XCTAssertTrue(app.staticTexts["2 retained strokes"].waitForExistence(timeout: 5))
    let failedBefore = try await pullAttemptCount()
    try await waitForPullAttempt(after: failedBefore)
    XCTAssertTrue(app.staticTexts["2 retained strokes"].exists)
    let native = try PKDrawing(
      data: XCTUnwrap(Data(base64Encoded: XCTUnwrap(drawing["nativeData"] as? String))))
    let stroke = try XCTUnwrap(native.strokes.first)
    let replacement = PKDrawing(
      strokes: (0..<3).map { _ in
        PKStroke(ink: stroke.ink, path: stroke.path, transform: stroke.transform)
      })
    let vector = try XCTUnwrap((drawing["strokes"] as? [[String: Any]])?.first)
    let replacementVectors = (0..<3).map { _ -> [String: Any] in
      var value = vector
      value["id"] = UUID().uuidString
      return value
    }
    let canonical = try await operation(
      token, action: "update", item: handwriting,
      payload: [
        "drawing": [
          "format": "bookorbit-ink-v1", "strokes": replacementVectors,
          "nativeData": replacement.dataRepresentation().base64EncodedString(),
        ]
      ])
    _ = try await operation(token, action: "delete", item: updated)
    let foreign = try await operation(
      administrator, action: "create",
      payload: [
        "bookFileId": 2, "cfi": cfi, "text": passage, "kind": "text_note",
        "note": "Other owner private note", "color": "#FACC15", "style": "highlight",
      ])
    let foreignID = try XCTUnwrap(foreign["id"] as? Int)
    let foreignCleanup = try JSONSerialization.data(withJSONObject: [
      "deviceId": "Private sync teardown client",
      "operations": [
        [
          "operationId": UUID().uuidString,
          "clientId": try XCTUnwrap(foreign["clientId"] as? String),
          "annotationId": foreignID, "bookId": 2,
          "baseVersion": try XCTUnwrap(foreign["version"] as? Int), "action": "delete",
        ]
      ],
    ])
    let cleanupEndpoint = try XCTUnwrap(
      URL(string: "\(Self.serverURL)/api/v1/annotations/native/operations"))
    addTeardownBlock {
      var request = URLRequest(url: cleanupEndpoint)
      request.httpMethod = "POST"
      request.timeoutInterval = 5
      request.setValue("Bearer \(administrator)", forHTTPHeaderField: "Authorization")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = foreignCleanup
      let (_, response) = try await Self.network.data(for: request)
      XCTAssertTrue((200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0))
    }
    let ownRows = try await annotations(token)
    XCTAssertFalse(ownRows.contains { $0["id"] as? Int == foreignID })
    _ = try await request(
      "annotations/native/operations", method: "POST", token: token,
      body: [
        "deviceId": UUID().uuidString,
        "operations": [
          [
            "operationId": UUID().uuidString,
            "clientId": try XCTUnwrap(foreign["clientId"] as? String), "annotationId": foreignID,
            "bookId": 2, "baseVersion": try XCTUnwrap(foreign["version"] as? Int),
            "action": "delete",
          ]
        ],
      ], expected: 403)
    cursor = try await completedPullCount()
    try await fault("online")
    try await waitForPull(after: cursor)
    XCTAssertTrue(app.staticTexts["passageSelectionPreview"].exists)
    XCTAssertTrue(
      app.staticTexts["2 retained strokes"].exists,
      "Automatic pulls must preserve the dirty retained PKDrawing")
    capture("IPAD-E02-A05-private-reconnect-preserves-dirty-PKDrawing")
    tap("passageCancel", app)
    XCTAssertEqual(position.label, originalPosition)
    tap("epubPassageNotes", app)
    XCTAssertFalse(app.buttons["passageEdit\(remoteID)"].exists)
    XCTAssertFalse(app.buttons["passageEdit\(foreignID)"].exists)
    let retained = app.buttons["passageEdit\(handwritingID)"]
    XCTAssertTrue(retained.waitForExistence(timeout: 5))
    retained.tap()
    XCTAssertTrue(app.staticTexts["3 retained strokes"].waitForExistence(timeout: 10))
    XCTAssertEqual(try XCTUnwrap(canonical["version"] as? Int), 2)
    capture("IPAD-E02-A05-private-canonical-update-and-delete-applied-without-reader-reopen")
    tap("passageCancel", app)
    let finalWrites = try await nativeWriteCount()
    XCTAssertEqual(finalWrites, writesBefore)
    let finalBytes = try await request("books/files/2/serve", token: token)
    XCTAssertEqual(finalBytes, sourceBytes)
    attach(sourceBytes, name: "IPAD-E02-A05-unchanged-source-EPUB", type: "org.idpf.epub-container")
  }

  private nonisolated static var faultURL: String {
    var components = URLComponents(
      string: ProcessInfo.processInfo.environment["IPAD_ANNOTATION_FAULT_URL"]
        ?? "http://127.0.0.1:16485")!
    if components.host == "localhost" { components.host = "127.0.0.1" }
    if components.path == "/api/v1" { components.path = "" }
    return components.string!.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }

  @MainActor private func operation(
    _ token: String, action: String, item: [String: Any]? = nil, payload: [String: Any]? = nil
  ) async throws -> [String: Any] {
    var operation: [String: Any] = [
      "operationId": UUID().uuidString,
      "clientId": item?["clientId"] as? String ?? UUID().uuidString, "bookId": 2,
      "baseVersion": item?["version"] as? Int ?? 0, "action": action,
    ]
    if let id = item?["id"] as? Int { operation["annotationId"] = id }
    if let payload { operation["payload"] = payload }
    let response = try await object(
      "annotations/native/operations", method: "POST", token: token,
      body: ["deviceId": "Private sync public client", "operations": [operation]])
    let result = try XCTUnwrap((response["results"] as? [[String: Any]])?.first)
    XCTAssertEqual(result["status"] as? String, "applied")
    return try XCTUnwrap(result["annotation"] as? [String: Any])
  }

  @MainActor private func openNote(_ id: Int, _ app: XCUIApplication) {
    tap("epubPassageNotes", app)
    tap("passageEdit\(id)", app)
    XCTAssertTrue(app.staticTexts["passageSelectionPreview"].waitForExistence(timeout: 10))
  }

  @MainActor private func fault(_ action: String) async throws {
    var request = URLRequest(
      url: try XCTUnwrap(URL(string: "\(Self.faultURL)/__faults/annotations/\(action)")))
    request.httpMethod = "POST"
    request.timeoutInterval = 5
    let (_, response) = try await Self.network.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
  }

  @MainActor private func traffic() async throws -> [[String: Any]] {
    var request = URLRequest(
      url: try XCTUnwrap(URL(string: "\(Self.faultURL)/__faults/annotations/traffic")))
    request.timeoutInterval = 5
    let (data, response) = try await Self.network.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(value["truncated"] as? Bool, false)
    return try XCTUnwrap(value["items"] as? [[String: Any]])
  }

  @MainActor private func nativeWriteCount() async throws -> Int {
    try await traffic().filter {
      $0["path"] as? String == "/api/v1/annotations/native/operations"
        && $0["method"] as? String == "POST"
    }.count
  }

  @MainActor private func completedPullCount() async throws -> Int {
    try await traffic().filter {
      $0["path"] as? String == "/api/v1/annotations/native/delta" && $0["status"] as? Int == 200
        && $0["complete"] as? Bool == true
    }.count
  }

  @MainActor private func pullAttemptCount() async throws -> Int {
    try await traffic().filter { $0["path"] as? String == "/api/v1/annotations/native/delta" }.count
  }

  @MainActor private func waitForPull(after previous: Int) async throws {
    let deadline = Date().addingTimeInterval(20)
    var count = try await completedPullCount()
    while count < previous + 2 && Date() < deadline {
      try await Task.sleep(for: .milliseconds(250))
      count = try await completedPullCount()
    }
    XCTAssertGreaterThanOrEqual(
      count, previous + 2, "Two bounded foreground ticks must discover server changes without Retry"
    )
  }

  @MainActor private func waitForPullAttempt(after previous: Int) async throws {
    let deadline = Date().addingTimeInterval(20)
    var count = try await pullAttemptCount()
    while count <= previous && Date() < deadline {
      try await Task.sleep(for: .milliseconds(250))
      count = try await pullAttemptCount()
    }
    XCTAssertGreaterThan(
      count, previous, "Foreground reader must attempt automatic private pulls while disconnected")
  }

  @MainActor private func launchAndSignIn(_ username: String, serverURL: String? = nil)
    -> XCUIApplication
  {
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
    replaceText(server, serverURL ?? Self.serverURL)
    tap("connectServer", app)
    guard E02ProfileSupport.ensureSignInForm(app: app, serverURL: serverURL ?? Self.serverURL)
    else {
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
