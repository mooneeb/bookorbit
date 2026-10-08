import CryptoKit
import PDFKit
import XCTest

final class ActivePDFSyncJourneyTests: XCTestCase {
  private let transport: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 5
    configuration.timeoutIntervalForResource = 8
    return URLSession(configuration: configuration)
  }()

  @MainActor
  func testIPADE02ActivePDFRemoteMoveAndDeleteWithoutRetry() async throws {
    let owner = try await login("ipad-owner")
    let editor = try await login("ipad-editor")
    let original = try await request("books/files/1/serve", token: owner)
    let created = try await createInk(token: owner)
    let identity = try XCTUnwrap(created["clientId"] as? String)
    let id = try XCTUnwrap(created["id"] as? Int)
    try await resetFaults()
    let app = openPDF()
    let image = app.images["pdfInkItem\(identity)"]
    XCTAssertTrue(image.waitForExistence(timeout: 20))
    let initialFrame = image.frame
    let payload = try XCTUnwrap(created["drawing"] as? [String: Any])
    var movedDrawing = payload
    var strokes = try XCTUnwrap(payload["strokes"] as? [[String: Any]])
    var stroke = try XCTUnwrap(strokes.first)
    stroke["color"] = "#0000ff"
    stroke["points"] = [["x": 300, "y": 240], ["x": 400, "y": 240]]
    strokes[0] = stroke
    movedDrawing["strokes"] = strokes
    var position = try XCTUnwrap(created["pdf"] as? [String: Any])
    // The immutable page fingerprint remains valid across a proved source publication.
    let descriptor = try await source(token: editor)
    position["rect"] = ["x": 296, "y": 236, "width": 108, "height": 8]
    _ = try await mutate(
      id: id, clientID: identity, version: 1, action: "update",
      payload: [
        "pdf": position, "drawing": movedDrawing,
        "sourceRevision": try XCTUnwrap(descriptor["sourceRevision"]),
        "pageFingerprint": try XCTUnwrap(descriptor["pageFingerprint"]),
      ], token: editor)
    XCUIDevice.shared.press(.home)
    app.activate()
    let moved = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in image.exists && image.frame != initialFrame }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 25), .completed)
    XCTAssertTrue(app.staticTexts["Page 1 of 3"].exists)
    let afterMove = try await request("books/files/1/serve", token: owner)
    assertArtifact(afterMove, differsFrom: original, name: "remote-move-blue-current-source")
    _ = try await mutate(id: id, clientID: identity, version: 2, action: "delete", token: editor)
    try await fault("offline")
    try await fault("online")
    XCTAssertTrue(image.wait(for: \.exists, toEqual: false, timeout: 25))
    XCTAssertTrue(app.staticTexts["Page 1 of 3"].exists)
    let deleted = try await request("books/files/1/serve", token: owner)
    let movedPDF = try XCTUnwrap(PDFDocument(data: afterMove))
    let blueInk = movedPDF.page(at: 0)?.annotations.filter { $0.type == "Ink" }.first {
      $0.color == UIColor.blue
    }
    XCTAssertNotNil(blueInk, "The delivered ordinary PDF must contain the remote blue artwork")
    let deletedPDF = try XCTUnwrap(PDFDocument(data: deleted))
    XCTAssertEqual(
      deletedPDF.page(at: 0)?.annotations.filter { $0.type == "Ink" }.count,
      (movedPDF.page(at: 0)?.annotations.filter { $0.type == "Ink" }.count ?? 0) - 1)
    assertArtifact(deleted, differsFrom: afterMove, name: "remote-delete-current-source")
    capture("active-reader-automatic-move-delete-no-retry")
  }

  @MainActor
  func testIPADE02ActivePDFQueuedPencilDraftAndPageSurviveKnownPublication() async throws {
    let editor = try await login("ipad-editor")
    try await resetFaults()
    let app = openPDF()
    try await fault("offline")
    let fixture = app.buttons["pdfInkFixtureStroke"]
    XCTAssertTrue(fixture.wait(for: \.isHittable, toEqual: true, timeout: 10))
    fixture.tap()
    XCTAssertTrue(app.staticTexts["Ink saved locally"].waitForExistence(timeout: 15))
    let groups = app.images.matching(NSPredicate(format: "identifier BEGINSWITH %@", "pdfInkItem"))
    let retainedIdentities = groups.allElementsBoundByIndex.map(\.identifier)
    XCTAssertFalse(retainedIdentities.isEmpty)
    app.buttons["pdfNextPage"].tap()
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 10))
    let before = try await request("books/files/1/serve", token: editor)
    let remote = try await createInk(token: editor)
    let remoteIdentity = try XCTUnwrap(remote["clientId"] as? String)
    let after = try await request("books/files/1/serve", token: editor)
    assertArtifact(after, differsFrom: before, name: "known-publication-with-offline-pencil-draft")
    try await fault("online")
    XCUIDevice.shared.press(.home)
    app.activate()
    XCTAssertTrue(app.staticTexts["Ink synchronized"].waitForExistence(timeout: 30))
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].exists)
    app.buttons["pdfPreviousPage"].tap()
    XCTAssertTrue(app.images["pdfInkItem\(remoteIdentity)"].waitForExistence(timeout: 20))
    for identity in retainedIdentities { XCTAssertTrue(app.images[identity].exists) }
    let delivered = try await request("books/files/1/serve", token: editor)
    XCTAssertGreaterThanOrEqual(
      PDFDocument(data: delivered)?.page(at: 0)?.annotations.filter {
        $0.type == "Ink"
      }.count ?? 0, 2)
    capture("active-reader-retained-tagged-pencil-input-and-page")
  }

  @MainActor
  func testIPADE02ActivePDFUnknownDeletionRetainsCompleteOriginal() async throws {
    let owner = try await login("ipad-owner")
    _ = try await request("__faults/source-pdf/source/1/snapshot", method: "POST", token: owner)
    let original = try await request("books/files/1/serve", token: owner)
    let restoreURL = apiBase.appendingPathComponent("__faults/source-pdf/source/1/restore")
    addTeardownBlock { [transport, owner] in
      var restore = URLRequest(url: restoreURL)
      restore.httpMethod = "POST"
      restore.timeoutInterval = 5
      restore.setValue("Bearer \(owner)", forHTTPHeaderField: "Authorization")
      let (_, response) = try await transport.data(for: restore)
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
    }
    try await resetFaults()
    let app = openPDF()
    _ = try await request("__faults/source-pdf/source/1/delete", method: "POST", token: owner)
    XCTAssertTrue(app.buttons["pdfInkDraw"].wait(for: \.exists, toEqual: false, timeout: 25))
    XCTAssertTrue(app.staticTexts["Page 1 of 3"].exists)
    XCTAssertFalse(app.buttons["pdfInkDraw"].exists)
    capture("active-reader-unknown-deletion-keeps-old-visible-pdf")
    app.buttons["Close reader"].tap()
    app.buttons["offlineLibrary"].tap()
    app.buttons["offlineSourceRecovery"].tap()
    XCTAssertTrue(app.staticTexts["Source deleted"].waitForExistence(timeout: 20))
    let digest = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
    XCTAssertTrue(app.staticTexts["Revision \(digest)"].exists)
    let prepare = app.buttons.matching(
      NSPredicate(
        format: "identifier BEGINSWITH %@", "sourceRecoveryPrepareExport")
    ).firstMatch
    XCTAssertTrue(prepare.wait(for: \.isHittable, toEqual: true, timeout: 10))
    prepare.tap()
    XCTAssertTrue(app.staticTexts["sourceRecoveryExportReady"].waitForExistence(timeout: 15))
    attach(original, name: "unknown-deletion-original-complete-pdf", type: "com.adobe.pdf")
    capture("unknown-deletion-verified-complete-original-export")
  }

  private var apiBase: URL {
    URL(
      string: ProcessInfo.processInfo.environment["IPAD_ANNOTATION_SERVER_URL"]
        ?? "http://127.0.0.1:16482")!.appendingPathComponent("api/v1")
  }

  private var proxyBase: URL {
    URL(
      string: ProcessInfo.processInfo.environment["IPAD_ANNOTATION_PROXY_URL"]
        ?? "http://127.0.0.1:16485")!
  }

  @MainActor
  private func login(_ username: String) async throws -> String {
    let data = try await request(
      "auth/login", method: "POST",
      body: [
        "username": username, "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "Active PDF public UI regression",
      ])
    let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let refresh = try XCTUnwrap(value["refreshToken"] as? String)
    let logoutURL = apiBase.appendingPathComponent("auth/logout")
    addTeardownBlock { [transport, refresh] in
      var logout = URLRequest(url: logoutURL)
      logout.httpMethod = "POST"
      logout.timeoutInterval = 5
      logout.setValue("application/json", forHTTPHeaderField: "Content-Type")
      logout.httpBody = try JSONSerialization.data(withJSONObject: ["refreshToken": refresh])
      let (_, response) = try await transport.data(for: logout)
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }
    return try XCTUnwrap(value["accessToken"] as? String)
  }

  @MainActor
  private func request(
    _ path: String, method: String = "GET", token: String? = nil,
    body: [String: Any]? = nil
  ) async throws -> Data {
    var request = URLRequest(url: apiBase.appendingPathComponent(path))
    request.httpMethod = method
    request.timeoutInterval = 5
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await transport.data(for: request)
    XCTAssertTrue((200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0), path)
    return data
  }

  @MainActor
  private func source(token: String) async throws -> [String: Any] {
    var components = URLComponents(
      url: apiBase.appendingPathComponent("annotations/native/files/1/source"),
      resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "bookId", value: "1"), URLQueryItem(name: "page", value: "0"),
    ]
    var request = URLRequest(url: components.url!)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await transport.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @MainActor
  private func createInk(token: String) async throws -> [String: Any] {
    let descriptor = try await source(token: token)
    return try await mutate(
      id: nil, clientID: UUID().uuidString.lowercased(), version: 0,
      action: "create",
      payload: [
        "kind": "pdf_ink", "bookFileId": 1, "text": "",
        "pdf": ["page": 0, "rect": ["x": 76, "y": 196, "width": 108, "height": 8], "rects": []],
        "sourceRevision": try XCTUnwrap(descriptor["sourceRevision"]),
        "pageFingerprint": try XCTUnwrap(descriptor["pageFingerprint"]),
        "drawing": [
          "format": "bookorbit-ink-v1",
          "strokes": [
            [
              "id": UUID().uuidString,
              "width": 5, "color": "#ff0000",
              "points": [["x": 80, "y": 200], ["x": 180, "y": 200]],
            ]
          ],
        ],
      ],
      token: token)
  }

  @MainActor
  private func mutate(
    id: Int?, clientID: String, version: Int, action: String,
    payload: [String: Any]? = nil, token: String
  ) async throws -> [String: Any] {
    var body: [String: Any] = [
      "operationId": UUID().uuidString, "clientId": clientID,
      "bookId": 1, "baseVersion": version, "action": action,
    ]
    if let id { body["annotationId"] = id }
    if let payload {
      body["payload"] = payload
    } else if action == "delete" {
      let descriptor = try await source(token: token)
      body["payload"] = [
        "sourceRevision": try XCTUnwrap(descriptor["sourceRevision"]),
        "pageFingerprint": try XCTUnwrap(descriptor["pageFingerprint"]),
      ]
    }
    let data = try await request(
      "annotations/native/source-ink/1/1/operations", method: "POST", token: token,
      body: ["deviceId": "active-pdf-public-ui", "operations": [body]])
    let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let result = try XCTUnwrap((envelope["results"] as? [[String: Any]])?.first)
    XCTAssertEqual(result["status"] as? String, "applied")
    let publication = try XCTUnwrap(result["publication"] as? [String: Any])
    XCTAssertEqual(publication["status"] as? String, "published")
    return try XCTUnwrap(result["annotation"] as? [String: Any])
  }

  @MainActor
  private func resetFaults() async throws {
    try await fault("reset")
    let resetURL = proxyBase.appendingPathComponent("__faults/annotations/reset")
    addTeardownBlock { [transport] in
      var request = URLRequest(url: resetURL)
      request.httpMethod = "POST"
      request.timeoutInterval = 5
      let (_, response) = try await transport.data(for: request)
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
    }
  }

  @MainActor
  private func fault(_ action: String) async throws {
    var request = URLRequest(
      url: proxyBase.appendingPathComponent("__faults/annotations/\(action)"))
    request.httpMethod = "POST"
    request.timeoutInterval = 5
    let (_, response) = try await transport.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
  }

  @MainActor
  private func openPDF() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "--annotation-input-driver",
    ]
    app.launchEnvironment["BOOKORBIT_ANNOTATION_INPUT_FIXTURE"] = "1"
    E02ProfileSupport.configure(app)
    app.launch()
    if app.buttons["Close reader"].exists { app.buttons["Close reader"].tap() }
    if app.buttons["signOut"].exists { app.buttons["signOut"].tap() }
    if app.buttons["Change server"].exists { app.buttons["Change server"].tap() }
    let server = app.textFields["serverURL"]
    XCTAssertTrue(server.waitForExistence(timeout: 10))
    server.tap()
    server.typeText(
      String(
        repeating: XCUIKeyboardKey.delete.rawValue, count: (server.value as? String ?? "").count))
    server.typeText(proxyBase.absoluteString)
    app.buttons["connectServer"].tap()
    XCTAssertTrue(app.textFields["username"].waitForExistence(timeout: 10))
    app.textFields["username"].tap()
    app.textFields["username"].typeText("ipad-owner")
    app.secureTextFields["password"].tap()
    app.secureTextFields["password"].typeText("IpadFixture123")
    app.buttons["signIn"].tap()
    XCTAssertTrue(app.buttons["Table"].waitForExistence(timeout: 25))
    app.buttons["Table"].tap()
    let search = app.textViews["librarySearch"]
    XCTAssertTrue(search.wait(for: \.isHittable, toEqual: true, timeout: 10))
    search.tap()
    search.typeText("Orbit fixture\n")
    XCTAssertTrue(app.buttons["tableOpen1_title"].waitForExistence(timeout: 15))
    app.buttons["tableOpen1_title"].tap()
    app.buttons["Book details"].tap()
    let containers = app.descendants(matching: .any).matching(identifier: "bookDetailContent")
    let content = containers.element
    XCTAssertTrue(content.wait(for: \.isHittable, toEqual: true, timeout: 10))
    XCTAssertEqual(containers.count, 1)
    let read = content.buttons["readFile1"]
    for _ in 0..<6 where !read.isHittable { content.swipeUp() }
    XCTAssertTrue(read.wait(for: \.isHittable, toEqual: true, timeout: 10))
    read.tap()
    XCTAssertTrue(app.staticTexts["Page 1 of 3"].waitForExistence(timeout: 20))
    return app
  }

  @MainActor
  private func assertArtifact(_ data: Data, differsFrom old: Data, name: String) {
    XCTAssertNotEqual(data, old)
    let pdf = PDFDocument(data: data)
    XCTAssertEqual(pdf?.pageCount, 3)
    XCTAssertTrue(pdf?.page(at: 0)?.string?.contains("Orbit fixture") == true)
    attach(data, name: name, type: "com.adobe.pdf")
    if let page = pdf?.page(at: 0) {
      let attachment = XCTAttachment(
        image: page.thumbnail(of: CGSize(width: 600, height: 800), for: .mediaBox))
      attachment.name = "\(name)-independent-PDFKit-render"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
  }

  @MainActor
  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
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
