import Foundation
import PencilKit
import XCTest

final class RecoveryDraftJourneyTests: XCTestCase {
  private nonisolated static let serverURL =
    ProcessInfo.processInfo.environment["IPAD_ANNOTATION_SERVER_URL"]
    ?? "http://127.0.0.1:16482"
  private nonisolated static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 8
    configuration.timeoutIntervalForResource = 12
    configuration.waitsForConnectivity = false
    return URLSession(configuration: configuration)
  }()

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
  }

  override func tearDown() async throws {
    if let testRun, testRun.failureCount > 0 {
      let screenshot = await MainActor.run { XCUIScreen.main.screenshot().pngRepresentation }
      attach(screenshot, name: "IPAD-E02-A06-recovery-failure", type: "public.png")
    }
    try await super.tearDown()
  }

  @MainActor
  func testIPADE02A06RecoveryDraftExportAndExplicitReattachmentPreserveDeletedOriginal()
    async throws
  {
    let directory = try XCTUnwrap(
      ProcessInfo.processInfo.environment["IPAD_E02_EXPORTED_ARTIFACT_DIRECTORY"],
      "Supply the installed app's public Documents directory from simctl get_app_container.")
    XCTAssertEqual(URL(fileURLWithPath: directory).lastPathComponent, "Documents")
    let token = try await login()
    let marker = "RecoveryUI-\(UUID().uuidString)"
    let clientID = UUID().uuidString
    let drawing = retainedDrawing()
    let created = try await apply(
      token: token,
      operation: [
        "operationId": UUID().uuidString, "clientId": clientID, "bookId": 2,
        "baseVersion": 0, "action": "create",
        "payload": [
          "bookFileId": 2, "cfi": "epubcfi(/6/2[c1ref]!/4/2[p1],/1:0,/1:5)",
          "kind": "handwriting", "text": "Alpha", "note": marker, "drawing": drawing,
        ],
      ])
    XCTAssertEqual(created["status"] as? String, "applied")
    addTeardownBlock { try await Self.cleanUpActiveFixture(marker: marker, token: token) }
    let original = try XCTUnwrap(created["annotation"] as? [String: Any])
    let originalID = try XCTUnwrap(original["id"] as? Int)
    let originalVersion = try XCTUnwrap(original["version"] as? Int)
    let deleted = try await apply(
      token: token,
      operation: [
        "operationId": UUID().uuidString, "clientId": clientID, "annotationId": originalID,
        "bookId": 2, "baseVersion": originalVersion, "action": "delete",
      ])
    XCTAssertEqual(deleted["status"] as? String, "applied")
    let tombstone = try XCTUnwrap(deleted["annotation"] as? [String: Any])
    let deletedAt = try XCTUnwrap(tombstone["deletedAt"] as? String)
    let deletedVersion = try XCTUnwrap(tombstone["version"] as? Int)
    let operationID = UUID().uuidString
    let recoveredNote = "\(marker) offline intended note"
    let recovered = try await apply(
      token: token,
      operation: [
        "operationId": operationID, "clientId": clientID, "annotationId": originalID,
        "bookId": 2, "baseVersion": originalVersion, "action": "update",
        "payload": ["note": recoveredNote],
      ])
    XCTAssertEqual(recovered["status"] as? String, "recovery")
    let draftID = try XCTUnwrap(recovered["draftId"] as? Int)
    let identity = "server-\(draftID)"
    let draftsBefore = try await drafts(token: token)
    let draftBefore = try XCTUnwrap(draftsBefore.first { $0["id"] as? Int == draftID })

    let app = launchAndSignIn()
    openRecovery(app)
    let export = app.buttons["annotationHubExportDraft\(identity)"]
    reveal(export, app: app)
    XCTAssertTrue(app.staticTexts["Original drawing retained"].exists)
    XCTAssertTrue(app.staticTexts[recoveredNote].exists)
    capture("IPAD-E02-A05-A06-deleted-original-retained-recovery")
    try app.performAccessibilityAudit()
    export.tap()
    let filename = "\(marker)-recovery.json"
    saveToPublicDocuments(filename: filename, app: app)
    let exported = try await readExport(
      URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(filename))
    attach(exported, name: "\(marker)-actual-native-Files-recovery", type: "public.json")
    let artifact = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
    XCTAssertEqual(artifact["id"] as? String, identity)
    XCTAssertEqual(artifact["bookId"] as? Int, 2)
    let exportedOperation = try XCTUnwrap(artifact["operation"] as? [String: Any])
    XCTAssertEqual(exportedOperation["operationId"] as? String, operationID)
    XCTAssertEqual(exportedOperation["annotationId"] as? Int, originalID)
    XCTAssertEqual(exportedOperation["baseVersion"] as? Int, originalVersion)
    let exportedItem = try XCTUnwrap(artifact["item"] as? [String: Any])
    XCTAssertEqual(exportedItem["id"] as? Int, originalID)
    XCTAssertEqual(exportedItem["note"] as? String, recoveredNote)
    XCTAssertEqual(exportedItem["kind"] as? String, "handwriting")
    let exportedDrawing = try XCTUnwrap(exportedItem["drawing"] as? [String: Any])
    XCTAssertEqual(exportedDrawing as NSDictionary, drawing as NSDictionary)
    let retained = try XCTUnwrap(exportedDrawing["nativeData"] as? String)
    let decodedDrawing = try PKDrawing(data: XCTUnwrap(Data(base64Encoded: retained)))
    XCTAssertEqual(decodedDrawing.strokes.count, 1)
    XCTAssertFalse(decodedDrawing.bounds.isEmpty)
    capture("IPAD-E02-A06-native-recovery-export-saved")

    let reattach = app.buttons["annotationHubReattachDraft\(identity)"]
    reveal(reattach, app: app)
    reattach.tap()
    let edition = app.buttons["annotationHubRepairFile2"]
    XCTAssertTrue(edition.wait(for: \.isHittable, toEqual: true, timeout: 15))
    capture("IPAD-E02-A06-explicit-reattachment-edition-choice")
    let beforeChoosing = try await activeItems(marker: marker, token: token)
    XCTAssertEqual(beforeChoosing.count, 0)
    app.buttons["Cancel"].tap()
    XCTAssertTrue(reattach.waitForExistence(timeout: 10))
    let afterCancelling = try await activeItems(marker: marker, token: token)
    XCTAssertEqual(afterCancelling.count, 0)
    reattach.tap()
    XCTAssertTrue(edition.wait(for: \.isHittable, toEqual: true, timeout: 10))
    edition.tap()
    goToSecondChapter(app)
    let select = app.buttons["epubFixtureSelectPassage"]
    XCTAssertTrue(select.wait(for: \.isHittable, toEqual: true, timeout: 15))
    select.tap()
    let confirmation = app.buttons["passageRepairHere"]
    XCTAssertTrue(confirmation.wait(for: \.isHittable, toEqual: true, timeout: 10))
    let beforeConfirming = try await activeItems(marker: marker, token: token)
    XCTAssertEqual(beforeConfirming.count, 0)
    capture("IPAD-E02-A06-new-passage-awaits-explicit-confirmation")
    confirmation.tap()
    XCTAssertTrue(reattach.waitForExistence(timeout: 15))
    app.buttons["Done"].tap()
    tapHubControl("annotationHubSynchronize", app: app)
    let attached = try await waitForAttached(marker: marker, token: token)
    let newID = try XCTUnwrap(attached["id"] as? Int)
    XCTAssertNotEqual(newID, originalID)
    XCTAssertNotEqual(attached["clientId"] as? String, clientID)
    XCTAssertEqual(attached["jumpFileId"] as? Int, 2)
    XCTAssertEqual(attached["text"] as? String, "Second chapter begins here.")
    XCTAssertNotEqual(attached["cfi"] as? String, original["cfi"] as? String)
    XCTAssertEqual(attached["kind"] as? String, "handwriting")
    XCTAssertEqual(attached["note"] as? String, recoveredNote)
    XCTAssertEqual(try XCTUnwrap(attached["drawing"] as? NSDictionary), drawing as NSDictionary)
    let trashed = try await items(marker: marker, status: "trashed", token: token)
    let preserved = try XCTUnwrap(trashed.first { $0["id"] as? Int == originalID })
    XCTAssertEqual(preserved["deletedAt"] as? String, deletedAt)
    XCTAssertEqual(preserved["version"] as? Int, deletedVersion)
    let draftsAfter = try await drafts(token: token)
    let draftAfter = try XCTUnwrap(draftsAfter.first { $0["id"] as? Int == draftID })
    XCTAssertEqual(draftAfter as NSDictionary, draftBefore as NSDictionary)
    attach(
      try JSONSerialization.data(withJSONObject: ["new": attached, "deleted": preserved]),
      name: "IPAD-E02-A06-new-identity-and-preserved-tombstone", type: "public.json")
    openRecovery(app)
    reveal(reattach, app: app)
    capture("IPAD-E02-A06-recovery-draft-retained-after-explicit-attachment")
    app.buttons["Done"].tap()
  }

  @MainActor
  private func goToSecondChapter(_ app: XCUIApplication) {
    let tools = app.descendants(matching: .any).matching(identifier: "epubReaderTools")
    let previous = app.descendants(matching: .any).matching(identifier: "epubPreviousSection")
    let next = app.descendants(matching: .any).matching(identifier: "epubNextSection")
    let firstChapter = app.webViews.staticTexts.matching(
      NSPredicate(format: "label == %@", "First chapter ends here."))
    let secondChapter = app.webViews.staticTexts.matching(
      NSPredicate(format: "label == %@", "Second chapter begins here."))
    XCTAssertTrue(tools.element.wait(for: \.isHittable, toEqual: true, timeout: 25))
    XCTAssertEqual(tools.count, 1)
    XCTAssertTrue(tools.element.isEnabled)
    tools.element.tap()
    XCTAssertTrue(previous.element.waitForExistence(timeout: 10))
    XCTAssertEqual(previous.count, 1)
    XCTAssertTrue(previous.element.isHittable)
    if previous.element.isEnabled {
      previous.element.tap()
      XCTAssertTrue(previous.element.wait(for: \.isHittable, toEqual: false, timeout: 10))
      XCTAssertTrue(firstChapter.element.wait(for: \.isHittable, toEqual: true, timeout: 15))
      XCTAssertEqual(firstChapter.count, 1)
      XCTAssertTrue(tools.element.wait(for: \.isHittable, toEqual: true, timeout: 10))
      XCTAssertEqual(tools.count, 1)
      XCTAssertTrue(tools.element.isEnabled)
      tools.element.tap()
      XCTAssertTrue(previous.element.waitForExistence(timeout: 10))
      XCTAssertEqual(previous.count, 1)
    }
    XCTAssertFalse(previous.element.isEnabled, "The fixture has two chapters; begin from the first")
    XCTAssertTrue(next.element.wait(for: \.isHittable, toEqual: true, timeout: 10))
    XCTAssertEqual(next.count, 1)
    XCTAssertTrue(next.element.isEnabled)
    next.element.tap()
    XCTAssertTrue(next.element.wait(for: \.isHittable, toEqual: false, timeout: 10))
    XCTAssertTrue(secondChapter.element.wait(for: \.isHittable, toEqual: true, timeout: 15))
    XCTAssertEqual(secondChapter.count, 1)
  }

  @MainActor
  private func retainedDrawing() -> [String: Any] {
    let points = [CGPoint(x: 12, y: 18), CGPoint(x: 22, y: 30)].enumerated().map {
      PKStrokePoint(
        location: $0.element, timeOffset: Double($0.offset) / 10, size: CGSize(width: 2, height: 2),
        opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
    }
    let stroke = PKStroke(
      ink: PKInk(.pen, color: .black),
      path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0)))
    return [
      "format": "bookorbit-ink-v1",
      "nativeData": PKDrawing(strokes: [stroke]).dataRepresentation().base64EncodedString(),
      "strokes": [
        [
          "id": "tagged-Pencil-boundary-recovery-stroke", "color": "#000000", "width": 2,
          "points": [["x": 12, "y": 18], ["x": 22, "y": 30]],
        ]
      ],
    ]
  }

  @MainActor
  private func launchAndSignIn() -> XCUIApplication {
    let profile = ProcessInfo.processInfo.environment["IPAD_E02_PROFILE"] ?? "pro13-portrait-light"
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
    for _ in 0..<8 where !app.textFields["serverURL"].exists {
      if app.buttons["signOut"].exists {
        app.buttons["signOut"].tap()
      } else if app.buttons["Change server"].exists {
        app.buttons["Change server"].tap()
      } else if app.buttons["epubCloseReader"].exists {
        app.buttons["epubCloseReader"].tap()
      } else if app.buttons["Close reader"].exists {
        app.buttons["Close reader"].tap()
      } else if app.buttons["annotationHubDone"].exists {
        app.buttons["annotationHubDone"].tap()
      } else if app.buttons["Done"].exists {
        app.buttons["Done"].tap()
      } else {
        _ = app.buttons["signOut"].waitForExistence(timeout: 3)
      }
    }
    let server = app.textFields["serverURL"]
    XCTAssertTrue(server.waitForExistence(timeout: 10))
    replaceText(server, with: Self.serverURL)
    app.buttons["connectServer"].tap()
    let username = app.textFields["username"]
    XCTAssertTrue(username.wait(for: \.isHittable, toEqual: true, timeout: 10))
    username.tap()
    username.typeText("ipad-reader")
    app.secureTextFields["password"].tap()
    app.secureTextFields["password"].typeText("IpadFixture123")
    app.buttons["signIn"].tap()
    XCTAssertTrue(app.buttons["openAnnotationHub"].waitForExistence(timeout: 25))
    return app
  }

  @MainActor
  private func openRecovery(_ app: XCUIApplication) {
    if app.buttons["openAnnotationHub"].exists {
      app.buttons["openAnnotationHub"].tap()
      XCTAssertTrue(app.searchFields["annotationHubSearch"].waitForExistence(timeout: 15))
    }
    tapHubControl("annotationHubRecovery", app: app)
    let storage = app.segmentedControls["annotationHubRecoveryStorage"]
    XCTAssertTrue(storage.waitForExistence(timeout: 10))
    storage.buttons["Server"].tap()
  }

  @MainActor
  private func saveToPublicDocuments(filename: String, app: XCUIApplication) {
    let save = app.buttons["Save"].firstMatch
    XCTAssertTrue(save.wait(for: \.isHittable, toEqual: true, timeout: 15))
    let browse = app.buttons["Browse"]
    if browse.isHittable { browse.tap() }
    let local = app.cells.containing(.staticText, identifier: "On My iPad").firstMatch
    if local.isHittable {
      local.tap()
    } else if app.buttons["On My iPad"].isHittable {
      app.buttons["On My iPad"].tap()
    }
    let folder = app.cells.containing(.staticText, identifier: "BookOrbit").firstMatch
    if folder.isHittable {
      folder.tap()
    } else if app.buttons["BookOrbit"].isHittable {
      app.buttons["BookOrbit"].tap()
    }
    let fields = app.textFields.matching(
      NSPredicate(format: "value CONTAINS %@", "BookOrbit recovery draft"))
    XCTAssertEqual(fields.count, 1, "Expected the actual native export filename field")
    replaceText(
      fields.element, with: URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
    )
    capture("IPAD-E02-A06-native-Files-recovery-export-destination")
    save.tap()
    XCTAssertTrue(save.wait(for: \.exists, toEqual: false, timeout: 15))
  }

  @MainActor
  private func reveal(_ element: XCUIElement, app: XCUIApplication) {
    for _ in 0..<8 where !element.isHittable {
      let lists = app.tables.allElementsBoundByIndex + app.collectionViews.allElementsBoundByIndex
      guard let list = lists.first(where: { $0.isHittable }) else {
        XCTFail("The native recovery list is not reachable")
        return
      }
      list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        .press(
          forDuration: 0.05,
          thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)),
          withVelocity: .slow, thenHoldForDuration: 0.1)
    }
    XCTAssertTrue(element.wait(for: \.isHittable, toEqual: true, timeout: 5), app.debugDescription)
  }

  @MainActor
  private func tapHubControl(_ identifier: String, app: XCUIApplication) {
    let element = app.buttons[identifier]
    XCTAssertTrue(element.waitForExistence(timeout: 10))
    let toolbar = app.scrollViews.containing(.button, identifier: identifier).firstMatch
    for _ in 0..<6 where !element.isHittable { toolbar.swipeLeft() }
    XCTAssertTrue(element.wait(for: \.isHittable, toEqual: true, timeout: 5))
    XCTAssertTrue(element.wait(for: \.isEnabled, toEqual: true, timeout: 15))
    element.tap()
  }

  @MainActor
  private func replaceText(_ field: XCUIElement, with value: String) {
    field.tap()
    let existing = field.value as? String ?? ""
    if !existing.isEmpty && existing != field.placeholderValue {
      field.typeText(
        String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.utf16.count))
    }
    field.typeText(value)
  }

  @MainActor
  private func readExport(_ url: URL) async throws -> Data {
    let deadline = Date().addingTimeInterval(15)
    while !FileManager.default.fileExists(atPath: url.path) && Date() < deadline {
      try await Task.sleep(for: .milliseconds(250))
    }
    let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
    XCTAssertGreaterThan(size, 0, "Read the file saved by native Files, not an HTTP export")
    XCTAssertLessThanOrEqual(size, 32 * 1024 * 1024)
    return try Data(contentsOf: url)
  }

  @MainActor
  private func login() async throws -> String {
    let credentials = try await json(
      "auth/login", method: "POST",
      body: [
        "username": "ipad-reader", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "Recovery UI assertion fixture",
      ])
    let refresh = try XCTUnwrap(credentials["refreshToken"] as? String)
    addTeardownBlock {
      _ = try await Self.request("auth/logout", method: "POST", body: ["refreshToken": refresh])
    }
    return try XCTUnwrap(credentials["accessToken"] as? String)
  }

  @MainActor
  private func apply(token: String, operation: [String: Any]) async throws -> [String: Any] {
    let response = try await json(
      "annotations/native/operations", method: "POST", token: token,
      body: ["deviceId": "Recovery UI seeded input boundary", "operations": [operation]])
    let results = try XCTUnwrap(response["results"] as? [[String: Any]])
    XCTAssertEqual(results.count, 1)
    return try XCTUnwrap(results.first)
  }

  @MainActor
  private func items(marker: String, status: String, token: String) async throws -> [[String: Any]]
  {
    let response = try await json(
      "annotations/native/hub?bookId=2&limit=10&status=\(status)&search=\(marker)", token: token)
    XCTAssertTrue(response["nextCursor"] is NSNull)
    return try XCTUnwrap(response["items"] as? [[String: Any]])
  }

  @MainActor
  private func activeItems(marker: String, token: String) async throws -> [[String: Any]] {
    try await items(marker: marker, status: "active", token: token)
  }

  @MainActor
  private func drafts(token: String) async throws -> [[String: Any]] {
    let response = try await json("annotations/native/hub/drafts?bookId=2&limit=40", token: token)
    XCTAssertTrue(response["nextCursor"] is NSNull, "Keep this reader's recovery fixture bounded")
    return try XCTUnwrap(response["items"] as? [[String: Any]])
  }

  @MainActor
  private func waitForAttached(marker: String, token: String) async throws -> [String: Any] {
    let deadline = Date().addingTimeInterval(25)
    var found = try await activeItems(marker: marker, token: token)
    while found.isEmpty && Date() < deadline {
      try await Task.sleep(for: .milliseconds(250))
      found = try await activeItems(marker: marker, token: token)
    }
    XCTAssertEqual(found.count, 1)
    return try XCTUnwrap(found.first)
  }

  @MainActor
  private func json(
    _ path: String, method: String = "GET", token: String? = nil, body: [String: Any]? = nil
  ) async throws -> [String: Any] {
    let data = try await Self.request(path, method: method, token: token, body: body)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private nonisolated static func request(
    _ path: String, method: String = "GET", token: String? = nil, body: [String: Any]? = nil
  ) async throws -> Data {
    var request = URLRequest(url: try XCTUnwrap(URL(string: "\(serverURL)/api/v1/\(path)")))
    request.httpMethod = method
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await session.data(for: request)
    XCTAssertTrue((200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0), path)
    return data
  }

  private nonisolated static func cleanUpActiveFixture(marker: String, token: String) async throws {
    let data = try await request(
      "annotations/native/hub?bookId=2&limit=10&status=active&search=\(marker)", token: token)
    let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertTrue(response["nextCursor"] is NSNull)
    let items = try XCTUnwrap(response["items"] as? [[String: Any]])
    for item in items {
      _ = try await request(
        "annotations/native/operations", method: "POST", token: token,
        body: [
          "deviceId": "Recovery UI fixture cleanup",
          "operations": [
            [
              "operationId": UUID().uuidString,
              "clientId": try XCTUnwrap(item["clientId"] as? String),
              "annotationId": try XCTUnwrap(item["id"] as? Int), "bookId": 2,
              "baseVersion": try XCTUnwrap(item["version"] as? Int), "action": "delete",
            ]
          ],
        ])
    }
  }

  private func attach(_ data: Data, name: String, type: String) {
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: type)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor
  private func capture(_ name: String) {
    let profile = ProcessInfo.processInfo.environment["IPAD_E02_PROFILE"] ?? "pro13-portrait-light"
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "\(name)-\(profile)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
