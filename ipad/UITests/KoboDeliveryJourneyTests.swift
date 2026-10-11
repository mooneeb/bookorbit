import Foundation
import PDFKit
import XCTest

final class KoboDeliveryJourneyTests: XCTestCase {
  private let accessibilityAudit = E04AccessibilityAudit()
  private let base = "http://127.0.0.1:16502/api/v1"
  private static let retainedUsername = "ipad-e04-kobo-b5bd0940"
  private static let retainedUserID = 94
  private static let retainedCollectionID = 16
  private static let retainedEntitlementID = "3fd74524-4dc8-4c89-bea3-986aca39c675"
  private static let retainedPDFRevision =
    "sha256:7baeacd1115ba6ae7b01914937e78eb1281ccb7da9888ff857177f04b539e541"
  override func setUpWithError() throws { continueAfterFailure = false }

  override func tearDownWithError() throws {
    accessibilityAudit.reportFailures(testCase: self)
    try super.tearDownWithError()
  }

  @MainActor
  func testIPADE04A03KoboCredentialsSubscriptionsSelectedDeliveryAndRetry() async throws {
    let ownerToken = try await login()
    let book = try await json("books/1", token: ownerToken)
    XCTAssertEqual(book["id"] as? Int, 1)
    let sourceFile = try XCTUnwrap(
      (book["files"] as? [[String: Any]])?.first { $0["id"] as? Int == 1 })
    XCTAssertEqual(sourceFile["format"] as? String, "pdf")
    XCTAssertEqual(sourceFile["role"] as? String, "primary")
    let libraryID = try XCTUnwrap(book["libraryId"] as? Int)
    let bookTitle = try XCTUnwrap(book["title"] as? String)
    let username = "ipad-e04-kobo-\(UUID().uuidString.prefix(8).lowercased())"
    let reader = try await json(
      "users", token: ownerToken, method: "POST",
      body: [
        "username": username, "name": username, "email": "\(username)@example.test",
        "permissionNames": [
          "kobo_sync", "library_download", "library_edit_metadata", "annotation_manage_own",
        ],
        "libraryIds": [libraryID],
      ])
    let userID = try XCTUnwrap(reader["id"] as? Int)
    let resetURL = try XCTUnwrap(reader["resetUrl"] as? String)
    let resetToken = try XCTUnwrap(
      URLComponents(string: resetURL)?.queryItems?.first { $0.name == "token" }?.value)
    _ = try await request(
      "auth/reset-password", method: "POST",
      body: ["token": resetToken, "newPassword": "IpadFixture123"], expected: 204)
    let token = try await login(username: username)
    let collection = try await json(
      "collections", token: token, method: "POST",
      body: ["name": "IPAD-E04 Kobo native selected book", "icon": "Folder"])
    let collectionID = try XCTUnwrap(collection["id"] as? Int)
    let app = launch(username: username)
    openKoboSettings(app)
    try await saveKoboSettings(app: app, token: token)
    try await runKoboDelivery(
      app: app, username: username, userID: userID, collectionID: collectionID,
      token: token, ownerToken: ownerToken, bookTitle: bookTitle)
  }

  @MainActor
  func testIPADE04A03NativeRetainedKoboSettingsSaveCheckpoint() async throws {
    let token = try await login(username: Self.retainedUsername)
    _ = try await assertRetainedFixture(token: token, settingsEnabled: false)
    let app = launch(username: Self.retainedUsername)
    openKoboSettings(app)
    try await saveKoboSettings(app: app, token: token)
    _ = try await assertRetainedFixture(token: token, settingsEnabled: true)
  }

  @MainActor
  func testIPADE04A03NativeRetainedKoboCredentialsSelectedDeliveryAndRetry() async throws {
    let token = try await login(username: Self.retainedUsername)
    let bookTitle = try await assertRetainedFixture(token: token, settingsEnabled: true)
    let ownerToken = try await login()
    let app = launch(username: Self.retainedUsername)
    openKoboSettings(app)
    let form = app.collectionViews["koboSettingsContent"]
    for identifier in ["koboTwoWayProgress", "koboAnnotationSync"] {
      let toggle = app.switches[identifier]
      XCTAssertTrue(reveal(toggle, in: form, app: app))
      XCTAssertEqual(toggle.value as? String, "1")
    }
    try await runKoboDelivery(
      app: app, username: Self.retainedUsername, userID: Self.retainedUserID,
      collectionID: Self.retainedCollectionID, token: token, ownerToken: ownerToken,
      bookTitle: bookTitle)
  }

  @MainActor
  func testIPADE04A03NativeRetainedKoboHistoryAndHandoffCheckpoint() async throws {
    let session = try await json(
      "auth/login", method: "POST",
      body: [
        "username": Self.retainedUsername, "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "Kobo retained history checkpoint",
      ])
    let token = try XCTUnwrap(session["accessToken"] as? String)
    let refreshToken = try XCTUnwrap(session["refreshToken"] as? String)
    var logout = URLRequest(url: try XCTUnwrap(URL(string: "\(base)/auth/logout")))
    logout.httpMethod = "POST"
    logout.setValue("application/json", forHTTPHeaderField: "Content-Type")
    logout.httpBody = try JSONSerialization.data(withJSONObject: ["refreshToken": refreshToken])
    logout.timeoutInterval = 10
    let logoutRequest = logout
    addTeardownBlock {
      let (_, response) = try await E04FixtureHTTP.data(for: logoutRequest)
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }
    let before = try await retainedHistoryFixture(token: token)
    attach(before.canonical, name: "IPAD-E04-A03-retained-kobo-before", type: "public.json")
    let app = launch(username: Self.retainedUsername)
    openKoboSettings(app)
    let historyLink = app.buttons["koboHistory"]
    XCTAssertTrue(reveal(historyLink, in: app.collectionViews["koboSettingsContent"], app: app))
    historyLink.tap()
    try assertDownloadHistory(
      app: app, history: before.history, deviceID: before.deviceID, bookTitle: before.bookTitle,
      completedID: 1170, failedID: 1169)
    let after = try await retainedHistoryFixture(token: token)
    XCTAssertEqual(after.canonical, before.canonical)
    attach(after.canonical, name: "IPAD-E04-A03-retained-kobo-after", type: "public.json")
    try await handoff(
      "A03",
      data: [
        "username": Self.retainedUsername, "userId": Self.retainedUserID,
        "deviceId": before.deviceID, "deviceName": "IPAD-E04 Kobo native receiver",
        "collectionName": "IPAD-E04 Kobo native selected book",
        "collectionId": Self.retainedCollectionID, "bookId": 1, "fileId": 1,
        "entitlementId": Self.retainedEntitlementID, "tagId": "col-16",
        "acknowledgedCatalogPages": 1, "expectedActivity": ["book_download", "library_sync"],
        "twoWayProgressSync": true, "syncBookOrbitAnnotationsToKobo": true,
        "completedHistoryId": 1170, "failedHistoryId": 1169,
        "sourceRevision": Self.retainedPDFRevision, "historyCheckpointOnly": true,
        "retainedCatalogReceipt":
          "run-72126-1791726492846/native-attachments/6B3D6B61-F81A-4875-9823-FC035B2884AD.json",
        "retainedPDFReceipt":
          "run-72126-1791726492846/native-attachments/53C3909C-154C-454F-82B5-9B733C5BD5FD.pdf",
      ])
  }

  @MainActor
  private func retainedHistoryFixture(token: String) async throws -> (
    canonical: Data, deviceID: Int, bookTitle: String, history: [[String: Any]]
  ) {
    let user = try await json("auth/me", token: token)
    XCTAssertEqual(user["id"] as? Int, Self.retainedUserID)
    XCTAssertEqual(user["username"] as? String, Self.retainedUsername)
    XCTAssertEqual(user["isSuperuser"] as? Bool, false)
    XCTAssertTrue((user["permissions"] as? [String] ?? []).contains("kobo_sync"))
    let collection = try await json("collections/16", token: token)
    XCTAssertEqual(collection["id"] as? Int, Self.retainedCollectionID)
    XCTAssertEqual(collection["userId"] as? Int, Self.retainedUserID)
    XCTAssertEqual(collection["isOwner"] as? Bool, true)
    XCTAssertEqual(collection["name"] as? String, "IPAD-E04 Kobo native selected book")
    XCTAssertEqual(collection["syncToKobo"] as? Bool, true)
    XCTAssertEqual(collection["bookCount"] as? Int, 1)
    let devicesData = try await request("kobo/devices", token: token)
    let devices = try XCTUnwrap(JSONSerialization.jsonObject(with: devicesData) as? [[String: Any]])
    XCTAssertEqual(devices.count, 1)
    let device = try XCTUnwrap(devices.first)
    XCTAssertEqual(device["name"] as? String, "IPAD-E04 Kobo native receiver")
    XCTAssertNil(device["token"])
    let deviceID = try XCTUnwrap(device["id"] as? Int)
    let settings = try await json("kobo/settings", token: token)
    XCTAssertEqual(settings["twoWayProgressSync"] as? Bool, true)
    XCTAssertEqual(settings["syncBookOrbitAnnotationsToKobo"] as? Bool, true)
    XCTAssertEqual(settings["convertToKepub"] as? Bool, true)
    let book = try await json("books/1", token: token)
    XCTAssertEqual(book["id"] as? Int, 1)
    XCTAssertEqual(book["libraryId"] as? Int, 1)
    let file = try XCTUnwrap((book["files"] as? [[String: Any]])?.first { $0["id"] as? Int == 1 })
    XCTAssertEqual(file["format"] as? String, "pdf")
    XCTAssertEqual(file["role"] as? String, "primary")
    let bookTitle = try XCTUnwrap(book["title"] as? String)
    let state = try await json("books/1/kobo-state", token: token)
    XCTAssertEqual(state["eligibleForKoboSync"] as? Bool, true)
    XCTAssertEqual(state["syncCollections"] as? [String], ["IPAD-E04 Kobo native selected book"])
    let snapshots = try XCTUnwrap(state["snapshots"] as? [[String: Any]])
    XCTAssertEqual(snapshots.count, 1)
    let snapshot = try XCTUnwrap(snapshots.first)
    XCTAssertEqual(snapshot["deviceId"] as? Int, deviceID)
    XCTAssertEqual(snapshot["deviceName"] as? String, "IPAD-E04 Kobo native receiver")
    XCTAssertEqual(snapshot["inSnapshot"] as? Bool, true)
    XCTAssertEqual(snapshot["synced"] as? Bool, true)
    XCTAssertEqual(snapshot["pendingDelete"] as? Bool, false)
    let source = try await json("annotations/native/files/1/source?bookId=1&page=0", token: token)
    XCTAssertEqual(source["sourceRevision"] as? String, Self.retainedPDFRevision)
    let history = try await downloadHistory(token: token)
    XCTAssertTrue(history.allSatisfy {
      $0["deviceId"] as? Int == deviceID
        && $0["deviceName"] as? String == "IPAD-E04 Kobo native receiver"
    })
    XCTAssertEqual(history.filter { $0["event"] as? String == "book_download" }.count, 2)
    XCTAssertTrue(history.contains {
      $0["event"] as? String == "library_sync" && $0["status"] as? String == "success"
    })
    let canonical = try JSONSerialization.data(
      withJSONObject: [
        "userId": Self.retainedUserID, "collection": collection, "devices": devices,
        "settings": settings, "file": file, "state": state, "source": source, "history": history,
      ], options: [.prettyPrinted, .sortedKeys])
    return (canonical, deviceID, bookTitle, history)
  }

  @MainActor
  private func downloadHistory(token: String) async throws -> [[String: Any]] {
    let data = try await request("kobo/history?limit=40", token: token)
    let history = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    XCTAssertLessThanOrEqual(history.count, 40)
    return history
  }

  @MainActor
  private func assertDownloadHistory(
    app: XCUIApplication, history: [[String: Any]], deviceID: Int, bookTitle: String,
    completedID: Int? = nil, failedID: Int? = nil
  ) throws {
    XCTAssertTrue(app.navigationBars["Kobo sync history"].waitForExistence(timeout: 10))
    let completed = try XCTUnwrap(history.first {
      $0["deviceId"] as? Int == deviceID && $0["event"] as? String == "book_download"
        && $0["status"] as? String == "success"
    })
    let failed = try XCTUnwrap(history.first {
      $0["deviceId"] as? Int == deviceID && $0["event"] as? String == "book_download"
        && $0["status"] as? String == "failed"
    })
    if let completedID { XCTAssertEqual(completed["id"] as? Int, completedID) }
    if let failedID { XCTAssertEqual(failed["id"] as? Int, failedID) }
    let counts = try XCTUnwrap(completed["counts"] as? [String: Any])
    XCTAssertEqual(counts["bookId"] as? Int, 1)
    XCTAssertEqual(counts["bookTitle"] as? String, bookTitle)
    XCTAssertEqual(counts["downloads"] as? Int, 1)
    XCTAssertTrue(try XCTUnwrap(failed["counts"] as? [String: Any]).isEmpty)
    XCTAssertEqual(failed["error"] as? String, "File not found on disk")
    let form = app.collectionViews["koboHistoryContent"]
    XCTAssertTrue(form.waitForExistence(timeout: 10))
    for (entry, outcome) in [(completed, "Completed"), (failed, "Failed")] {
      let id = try XCTUnwrap(entry["id"] as? Int)
      XCTAssertEqual(entry["deviceName"] as? String, "IPAD-E04 Kobo native receiver")
      let duration = try XCTUnwrap(entry["durationMs"] as? Int)
      XCTAssertGreaterThanOrEqual(duration, 0)
      var labels = [
        "Book download", "Device, IPAD-E04 Kobo native receiver", "Outcome, \(outcome)",
        "Duration, \(duration) ms",
      ]
      if outcome == "Completed" {
        labels += ["bookId, 1", "bookTitle, \(bookTitle)", "downloads, 1"]
      } else {
        labels.append("File not found on disk")
      }
      for label in labels {
        let predicate = NSPredicate(
          format: "identifier == %@ AND label == %@", "koboHistoryEntry\(id)", label)
        if outcome == "Completed", label == "Book download" {
          XCTAssertTrue(form.staticTexts.matching(predicate).element.waitForExistence(timeout: 10))
        }
        for _ in 0..<8 {
          let rows = form.staticTexts.matching(predicate)
          let viewport = form.frame.intersection(app.frame)
          if rows.count == 1, rows.element.isHittable,
            viewport.contains(rows.element.frame) { break }
          if rows.count == 1, rows.element.frame.minY < viewport.minY {
            form.swipeDown()
          } else {
            form.swipeUp()
          }
        }
        let rows = form.staticTexts.matching(predicate)
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows.element.isHittable)
        XCTAssertTrue(form.frame.intersection(app.frame).contains(rows.element.frame))
        let cells = form.cells.containing(predicate)
        XCTAssertEqual(cells.count, 1)
        XCTAssertEqual(cells.element.staticTexts.matching(predicate).count, 1)
        if label == "Outcome, \(outcome)" {
          capture("IPAD-E04-A03-kobo-\(outcome.lowercased())-owned-row")
          attach(
            Data(app.debugDescription.utf8),
            name: "IPAD-E04-A03-kobo-\(outcome.lowercased())-owned-row-hierarchy", type: "public.text")
        }
      }
      capture("IPAD-E04-A03-kobo-\(outcome.lowercased())-retained-history")
      accessibilityAudit.collect(
        app, screen: "IPAD-E04-A03-kobo-\(outcome.lowercased())-retained-history", testCase: self)
    }
  }

  @MainActor
  func testIPADE04A04NativeSourceInkCreateDeleteKoboRedelivery() async throws {
    let token = try await login()
    let device = try await json(
      "kobo/devices", token: token, method: "POST",
      body: ["name": "IPAD-E04 Kobo native ink receiver"])
    let deviceToken = try XCTUnwrap(device["token"] as? String)
    let app = launch(inkFixture: true)
    openDetails(app)
    XCTAssertTrue(E02ProfileSupport.openBookFile(app: app, fileID: 1))
    XCTAssertTrue(app.staticTexts["Page 1 of 3"].waitForExistence(timeout: 20))
    let before = try await request("kobo/\(deviceToken)/v1/books/1/download")
    let beforeInk =
      PDFDocument(data: before)?.page(at: 0)?.annotations.filter { $0.type == "Ink" }.count ?? 0
    let initialSource = try await json(
      "annotations/native/files/1/source?bookId=1&page=0", token: token)
    let initialRevision = try XCTUnwrap(initialSource["sourceRevision"] as? String)
    tapInk("pdfInkFixtureStroke", app: app)
    try await waitForSourceChange(from: initialRevision, token: token)
    let published = app.staticTexts["pdfInkStatus"]
    XCTAssertTrue(published.wait(for: \.label, toEqual: "Ink synchronized", timeout: 25))
    capture("IPAD-E04-A04-native-source-ink-published")
    let marked = try await request("kobo/\(deviceToken)/v1/books/1/download")
    XCTAssertEqual(
      PDFDocument(data: marked)?.page(at: 0)?.annotations.filter { $0.type == "Ink" }.count,
      beforeInk + 1)
    XCTAssertNotEqual(marked, before)
    attach(marked, name: "IPAD-E04-A04-kobo-native-ink-current-PDF", type: "com.adobe.pdf")
    tapInk("pdfInkSelect", app: app)
    let groups = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "pdfInkSelectItem"))
    XCTAssertGreaterThan(groups.count, 0)
    let selected = groups.allElementsBoundByIndex.last!
    XCTAssertTrue(revealHorizontal(selected, in: app.scrollViews["pdfInkGroups"]))
    selected.tap()
    let markedSource = try await json(
      "annotations/native/files/1/source?bookId=1&page=0", token: token)
    let markedRevision = try XCTUnwrap(markedSource["sourceRevision"] as? String)
    tapInk("pdfInkDelete", app: app)
    try await waitForSourceChange(from: markedRevision, token: token)
    XCTAssertTrue(published.wait(for: \.label, toEqual: "Ink synchronized", timeout: 25))
    capture("IPAD-E04-A04-native-source-ink-deletion-published")
    let deleted = try await request("kobo/\(deviceToken)/v1/books/1/download")
    XCTAssertEqual(
      PDFDocument(data: deleted)?.page(at: 0)?.annotations.filter { $0.type == "Ink" }.count,
      beforeInk)
    XCTAssertNotEqual(deleted, marked)
    attach(deleted, name: "IPAD-E04-A04-kobo-native-ink-deleted-PDF", type: "com.adobe.pdf")
    try await handoff(
      "A04",
      data: [
        "bookId": 1, "fileId": 1, "deviceName": "IPAD-E04 Kobo native ink receiver",
        "inkDeleted": true,
      ])
  }

  @MainActor
  private func openKoboSettings(_ app: XCUIApplication) {
    app.buttons["koboSettings"].tap()
    XCTAssertTrue(app.navigationBars["Kobo"].waitForExistence(timeout: 10))
  }

  @MainActor
  private func saveKoboSettings(app: XCUIApplication, token: String) async throws {
    let form = app.collectionViews["koboSettingsContent"]
    let progress = app.switches["koboTwoWayProgress"]
    XCTAssertTrue(reveal(progress, in: form, app: app))
    setSwitch(progress, enabled: true)
    let annotations = app.switches["koboAnnotationSync"]
    XCTAssertTrue(reveal(annotations, in: form, app: app))
    setSwitch(annotations, enabled: true)
    XCTAssertEqual(progress.value as? String, "1")
    XCTAssertEqual(annotations.value as? String, "1")
    capture("IPAD-E04-A03-kobo-both-sync-switches-enabled")
    let save = app.buttons["koboSaveSettings"]
    XCTAssertTrue(reveal(save, in: form, app: app))
    XCTAssertTrue(save.wait(for: \.isEnabled, toEqual: true, timeout: 10))
    save.tap()
    let notice = app.staticTexts["koboNotice"]
    let error = app.staticTexts["koboError"]
    let finished = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in notice.isHittable || error.isHittable }, object: nil)
    let result = await XCTWaiter.fulfillment(of: [finished], timeout: 15)
    capture("IPAD-E04-A03-kobo-save-actual-outcome")
    let settingsData = try await request("kobo/settings", token: token)
    attach(settingsData, name: "IPAD-E04-A03-kobo-saved-public-settings", type: "public.json")
    let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: settingsData) as? [String: Any])
    XCTAssertEqual(settings["twoWayProgressSync"] as? Bool, true)
    XCTAssertEqual(settings["syncBookOrbitAnnotationsToKobo"] as? Bool, true)
    XCTAssertEqual(settings["convertToKepub"] as? Bool, true)
    XCTAssertEqual(result, .completed)
    XCTAssertFalse(error.exists)
    XCTAssertTrue(notice.isHittable)
    XCTAssertEqual(notice.label, "Kobo settings saved. Sync your Kobo to apply them.")
    XCTAssertTrue(save.isEnabled)
    capture("IPAD-E04-A03-kobo-settings-saved")
  }

  @MainActor
  private func setSwitch(_ toggle: XCUIElement, enabled: Bool) {
    XCTAssertTrue(toggle.wait(for: \.isHittable, toEqual: true, timeout: 10))
    XCTAssertTrue(toggle.wait(for: \.isEnabled, toEqual: true, timeout: 10))
    let target = enabled ? "1" : "0"
    guard let value = toggle.value as? String, ["0", "1"].contains(value) else {
      XCTFail("Native toggle must expose an actual boolean value.")
      return
    }
    if value != target {
      toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    }
    let changed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", target), object: toggle)
    XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
  }

  @MainActor
  private func assertRetainedFixture(token: String, settingsEnabled: Bool) async throws -> String {
    let user = try await json("auth/me", token: token)
    XCTAssertEqual(user["id"] as? Int, Self.retainedUserID)
    XCTAssertEqual(user["username"] as? String, Self.retainedUsername)
    XCTAssertEqual(user["isSuperuser"] as? Bool, false)
    XCTAssertTrue((user["permissions"] as? [String] ?? []).contains("kobo_sync"))
    let collection = try await json("collections/\(Self.retainedCollectionID)", token: token)
    XCTAssertEqual(collection["id"] as? Int, Self.retainedCollectionID)
    XCTAssertEqual(collection["userId"] as? Int, Self.retainedUserID)
    XCTAssertEqual(collection["isOwner"] as? Bool, true)
    XCTAssertEqual(collection["name"] as? String, "IPAD-E04 Kobo native selected book")
    XCTAssertEqual(collection["syncToKobo"] as? Bool, false)
    XCTAssertEqual(collection["bookCount"] as? Int, 0)
    let devices = try await request("kobo/devices", token: token)
    XCTAssertEqual((try JSONSerialization.jsonObject(with: devices) as? [[String: Any]])?.count, 0)
    let history = try await request("kobo/history?limit=1", token: token)
    XCTAssertEqual((try JSONSerialization.jsonObject(with: history) as? [[String: Any]])?.count, 0)
    let settings = try await json("kobo/settings", token: token)
    XCTAssertEqual(settings["twoWayProgressSync"] as? Bool, settingsEnabled)
    XCTAssertEqual(settings["syncBookOrbitAnnotationsToKobo"] as? Bool, settingsEnabled)
    if settingsEnabled { XCTAssertEqual(settings["convertToKepub"] as? Bool, true) }
    let book = try await json("books/1", token: token)
    XCTAssertEqual(book["id"] as? Int, 1)
    XCTAssertEqual(book["libraryId"] as? Int, 1)
    let file = try XCTUnwrap((book["files"] as? [[String: Any]])?.first { $0["id"] as? Int == 1 })
    XCTAssertEqual(file["format"] as? String, "pdf")
    XCTAssertEqual(file["role"] as? String, "primary")
    return try XCTUnwrap(book["title"] as? String)
  }

  @MainActor
  private func runKoboDelivery(
    app: XCUIApplication, username: String, userID: Int, collectionID: Int,
    token: String, ownerToken: String, bookTitle: String
  ) async throws {
    let form = app.collectionViews["koboSettingsContent"]
    let name = app.textFields["koboDeviceName"]
    XCTAssertTrue(reveal(name, in: form, app: app))
    name.tap()
    name.typeText("IPAD-E04 Kobo native receiver")
    app.buttons["koboRegister"].tap()
    let credential = app.staticTexts["koboCredentialURL"]
    XCTAssertTrue(credential.waitForExistence(timeout: 10))
    let credentialURL = try XCTUnwrap(URL(string: credential.label))
    XCTAssertEqual(credentialURL.host, "127.0.0.1")
    XCTAssertEqual(credentialURL.port, 16502)
    XCTAssertTrue(app.buttons["Share device setup URL"].exists)
    capture("IPAD-E04-A03-kobo-one-time-credential")
    app.navigationBars["Kobo credential"].buttons["Done"].tap()
    XCTAssertFalse(app.staticTexts["koboCredentialURL"].exists)
    app.navigationBars["Kobo"].buttons["Done"].tap()
    openDetails(app)
    let deliver = app.buttons["deliverToKobo"]
    XCTAssertTrue(reveal(deliver, in: app.collectionViews["bookDetailContent"], app: app))
    deliver.tap()
    let selection = app.buttons["koboDeliverCollection\(collectionID)"]
    XCTAssertTrue(selection.waitForExistence(timeout: 10))
    selection.tap()
    let prepared = app.staticTexts["koboBookDeliveryNotice"]
    XCTAssertTrue(prepared.waitForExistence(timeout: 10))
    XCTAssertTrue(prepared.label.contains("Prepared for Kobo sync"))
    capture("IPAD-E04-A03-kobo-selected-book-prepared")
    let deviceToken = credentialURL.lastPathComponent
    let catalog = try await receiveSelectedBookCatalog(
      deviceToken: deviceToken, collectionID: collectionID, bookTitle: bookTitle)
    let entitlement = catalog.entitlementID
    let state = try await json("books/1/kobo-state", token: token)
    XCTAssertEqual(state["eligibleForKoboSync"] as? Bool, true)
    XCTAssertTrue(
      (state["syncCollections"] as? [String] ?? []).contains("IPAD-E04 Kobo native selected book"))
    let snapshot = try XCTUnwrap(
      (state["snapshots"] as? [[String: Any]])?.first {
        $0["deviceName"] as? String == "IPAD-E04 Kobo native receiver"
      })
    XCTAssertEqual(snapshot["inSnapshot"] as? Bool, true)
    XCTAssertEqual(snapshot["synced"] as? Bool, true)
    XCTAssertEqual(snapshot["pendingDelete"] as? Bool, false)
    let receipt = try JSONSerialization.data(
      withJSONObject: [
        "username": username, "userId": userID, "bookId": 1, "fileId": 1,
        "entitlementId": entitlement, "collectionId": collectionID,
        "tagId": "col-\(collectionID)", "tagRevisionIds": [entitlement],
        "acknowledgedCatalogPages": catalog.acknowledgedPages, "synced": true,
      ] as [String: Any], options: [.prettyPrinted, .sortedKeys])
    attach(receipt, name: "IPAD-E04-A03-selected-book-catalog-receipt", type: "public.json")
    _ = try await request(
      "__faults/source-pdf/source/1/snapshot", token: ownerToken, method: "POST", expected: 204)
    _ = try await request(
      "__faults/source-pdf/source/1/delete", token: ownerToken, method: "POST", expected: 204)
    _ = try await request("kobo/\(deviceToken)/v1/books/\(entitlement)/download", expected: 404)
    _ = try await request(
      "__faults/source-pdf/source/1/restore", token: ownerToken, method: "POST", expected: 204)
    let pdf = try await request("kobo/\(deviceToken)/v1/books/\(entitlement)/download")
    XCTAssertEqual(PDFDocument(data: pdf)?.pageCount, 3)
    XCTAssertTrue(PDFDocument(data: pdf)?.page(at: 0)?.string?.contains("Orbit fixture") == true)
    attach(pdf, name: "IPAD-E04-A03-kobo-received-PDF", type: "com.adobe.pdf")
    app.navigationBars["Deliver to Kobo"].buttons["Done"].tap()
    app.navigationBars["Book details"].buttons.firstMatch.tap()
    app.buttons["koboSettings"].tap()
    let historyLink = app.buttons["koboHistory"]
    XCTAssertTrue(reveal(historyLink, in: app.collectionViews["koboSettingsContent"], app: app))
    historyLink.tap()
    let history = try await downloadHistory(token: token)
    let deviceID = try XCTUnwrap(history.first?["deviceId"] as? Int)
    try assertDownloadHistory(app: app, history: history, deviceID: deviceID, bookTitle: bookTitle)
    capture("IPAD-E04-A03-kobo-failure-and-completed-retry-history")
    accessibilityAudit.collect(
      app, screen: "IPAD-E04-A03-kobo-failure-and-completed-retry-history", testCase: self)
    try await handoff(
      "A03",
      data: [
        "username": username, "userId": userID,
        "deviceName": "IPAD-E04 Kobo native receiver",
        "collectionName": "IPAD-E04 Kobo native selected book", "collectionId": collectionID,
        "bookId": 1, "fileId": 1, "entitlementId": entitlement,
        "tagId": "col-\(collectionID)", "acknowledgedCatalogPages": catalog.acknowledgedPages,
        "expectedActivity": ["book_download", "library_sync"], "twoWayProgressSync": true,
        "syncBookOrbitAnnotationsToKobo": true,
      ])
  }

  @MainActor
  private func launch(username: String = "ipad-owner", inkFixture: Bool = false) -> XCUIApplication
  {
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    if inkFixture {
      app.launchArguments.append("--annotation-input-driver")
      app.launchEnvironment["BOOKORBIT_ANNOTATION_INPUT_FIXTURE"] = "1"
    }
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
    server.typeText("http://127.0.0.1:16502")
    app.buttons["connectServer"].tap()
    XCTAssertTrue(app.textFields["username"].waitForExistence(timeout: 10))
    app.textFields["username"].tap()
    app.textFields["username"].typeText(username)
    app.secureTextFields["password"].tap()
    app.secureTextFields["password"].typeText("IpadFixture123")
    app.buttons["signIn"].tap()
    XCTAssertTrue(app.buttons["Table"].waitForExistence(timeout: 25))
    return app
  }

  @MainActor private func openDetails(_ app: XCUIApplication) {
    app.buttons["Table"].tap()
    let search = app.textViews["librarySearch"]
    XCTAssertTrue(search.waitForExistence(timeout: 10))
    search.tap()
    search.typeText("Orbit fixture\n")
    XCTAssertTrue(app.buttons["tableOpen1_title"].waitForExistence(timeout: 15))
    app.buttons["tableOpen1_title"].tap()
    app.buttons["Book details"].tap()
    XCTAssertTrue(app.navigationBars["Book details"].waitForExistence(timeout: 10))
  }

  @MainActor private func reveal(_ element: XCUIElement, in list: XCUIElement, app: XCUIApplication)
    -> Bool
  {
    E02ProfileSupport.reveal(element, in: list, app: app)
  }
  @MainActor private func revealHorizontal(_ element: XCUIElement, in list: XCUIElement) -> Bool {
    for _ in 0..<8 {
      if element.isHittable && list.frame.contains(element.frame) { return true }
      if element.frame.minX < list.frame.minX { list.swipeRight() } else { list.swipeLeft() }
    }
    return element.isHittable && list.frame.contains(element.frame)
  }
  @MainActor private func tapInk(_ id: String, app: XCUIApplication) {
    let button = app.buttons[id]
    XCTAssertTrue(button.waitForExistence(timeout: 10))
    XCTAssertTrue(revealHorizontal(button, in: app.scrollViews["pdfInkToolbar"]))
    XCTAssertTrue(button.wait(for: \.isEnabled, toEqual: true, timeout: 10))
    button.tap()
  }
  @MainActor private func capture(_ state: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = state
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func attach(_ data: Data, name: String, type: String) {
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: type)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  @MainActor private func login(username: String = "ipad-owner") async throws -> String {
    let response = try await json(
      "auth/login", method: "POST", body: ["username": username, "password": "IpadFixture123"])
    return try XCTUnwrap(response["accessToken"] as? String)
  }
  @MainActor private func json(
    _ path: String, token: String? = nil, method: String = "GET", body: [String: Any]? = nil
  ) async throws -> [String: Any] {
    let data = try await request(path, token: token, method: method, body: body)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
  @MainActor private func receiveSelectedBookCatalog(
    deviceToken: String, collectionID: Int, bookTitle: String
  ) async throws -> (entitlementID: String, acknowledgedPages: Int) {
    let metadataData = try await request("kobo/\(deviceToken)/v1/library/1/metadata")
    let metadata = try XCTUnwrap(
      JSONSerialization.jsonObject(with: metadataData) as? [[String: Any]])
    XCTAssertEqual(metadata.count, 1)
    let selectedMetadata = try XCTUnwrap(metadata.first)
    XCTAssertEqual(selectedMetadata["Title"] as? String, bookTitle)
    let selectedID = try XCTUnwrap(selectedMetadata["EntitlementId"] as? String)
    XCTAssertNotNil(UUID(uuidString: selectedID))
    var cursor: String?
    var receivedSelectedBook = false
    for pageIndex in 0..<6 {
      let (data, response) = try await protocolResponse(
        "kobo/\(deviceToken)/v1/library/sync",
        headers: cursor.map { ["x-kobo-synctoken": $0] } ?? [:])
      let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
      let nextCursor = try XCTUnwrap(response.value(forHTTPHeaderField: "x-kobo-synctoken"))
      XCTAssertFalse(nextCursor.isEmpty)
      let continuation = try XCTUnwrap(response.value(forHTTPHeaderField: "x-kobo-sync"))
      XCTAssertTrue(continuation.isEmpty || continuation == "continue")
      for entry in entries {
        guard let newBook = entry["NewEntitlement"] as? [String: Any] else { continue }
        let entitlement = try XCTUnwrap(newBook["BookEntitlement"] as? [String: Any])
        XCTAssertEqual(entitlement["Id"] as? String, selectedID)
        XCTAssertFalse(receivedSelectedBook, "An acknowledged catalog page must not replay book 1.")
        let receivedMetadata = try XCTUnwrap(newBook["BookMetadata"] as? [String: Any])
        XCTAssertEqual(receivedMetadata["EntitlementId"] as? String, selectedID)
        XCTAssertEqual(receivedMetadata["Title"] as? String, bookTitle)
        let download = try XCTUnwrap(
          (receivedMetadata["DownloadUrls"] as? [[String: Any]])?.first {
            $0["Format"] as? String == "PDF"
          })
        let downloadURL = try XCTUnwrap(URL(string: try XCTUnwrap(download["Url"] as? String)))
        XCTAssertEqual(downloadURL.host, "127.0.0.1")
        XCTAssertEqual(downloadURL.port, 16502)
        XCTAssertEqual(
          downloadURL.path, "/api/v1/kobo/\(deviceToken)/v1/books/\(selectedID)/download")
        receivedSelectedBook = true
      }
      if continuation.isEmpty {
        XCTAssertFalse(entries.contains { $0["NewEntitlement"] != nil })
        XCTAssertTrue(
          receivedSelectedBook, "The selected book 1 PDF must arrive before final tags.")
        let tag = try XCTUnwrap(
          entries.compactMap { ($0["ChangedTag"] as? [String: Any])?["Tag"] as? [String: Any] }
            .first { $0["Id"] as? String == "col-\(collectionID)" })
        XCTAssertEqual(tag["Name"] as? String, "IPAD-E04 Kobo native selected book")
        let items = try XCTUnwrap(tag["Items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?["RevisionId"] as? String, selectedID)
        XCTAssertEqual(items.first?["Type"] as? String, "ProductRevisionTagItem")
        return (selectedID, pageIndex)
      }
      cursor = nextCursor
    }
    XCTFail("The fresh one-book catalog must complete within six acknowledged requests.")
    throw NSError(domain: "KoboDeliveryJourneyTests", code: 1)
  }
  @MainActor private func waitForSourceChange(from revision: String, token: String) async throws {
    let deadline = Date().addingTimeInterval(25)
    while Date() < deadline {
      let source = try await json("annotations/native/files/1/source?bookId=1&page=0", token: token)
      if let current = source["sourceRevision"] as? String, current != revision { return }
      try await Task.sleep(for: .milliseconds(200))
    }
    XCTFail("The native ink change must publish a new source revision before redelivery.")
  }
  @MainActor private func request(
    _ path: String, token: String? = nil, method: String = "GET", body: [String: Any]? = nil,
    expected: Int? = nil
  ) async throws -> Data {
    try await protocolResponse(path, token: token, method: method, body: body, expected: expected).0
  }
  @MainActor private func protocolResponse(
    _ path: String, token: String? = nil, method: String = "GET", body: [String: Any]? = nil,
    expected: Int? = nil, headers: [String: String] = [:]
  ) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: try XCTUnwrap(URL(string: "\(base)/\(path)")))
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    request.httpMethod = method
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let body {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, response) = try await E04FixtureHTTP.data(for: request)
    let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
    let status = httpResponse.statusCode
    if let expected {
      XCTAssertEqual(status, expected)
    } else {
      XCTAssertTrue(
        (200..<300).contains(status), String(data: data, encoding: .utf8) ?? "Binary response")
    }
    return (data, httpResponse)
  }
  @MainActor private func handoff(_ scenario: String, data: [String: Any]) async throws {
    let receiver = try XCTUnwrap(ProcessInfo.processInfo.environment["IPAD_E04_RECEIVER_URL"])
    var request = URLRequest(url: try XCTUnwrap(URL(string: "\(receiver)/native-handoff")))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "testId": "IPAD-E04-\(scenario)", "case": scenario, "username": "ipad-owner", "kobo": data,
    ])
    let (_, response) = try await E04FixtureHTTP.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
  }
}
