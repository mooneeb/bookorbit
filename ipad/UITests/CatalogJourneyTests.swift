import Foundation
import XCTest

final class CatalogJourneyTests: XCTestCase {
  private let accessibilityAudit = E04AccessibilityAudit()
  private let base =
    ProcessInfo.processInfo.environment["IPAD_E04_BASE_URL"] ?? "http://127.0.0.1:16502"
  private let receiver = ProcessInfo.processInfo.environment["IPAD_E04_RECEIVER_URL"]
  private let password = "CatalogReader123"

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
  }

  override func tearDownWithError() throws {
    accessibilityAudit.reportFailures(testCase: self)
    try super.tearDownWithError()
  }

  @MainActor
  func testIPADE04A03NativeCatalogAccountsScopesAndSelectedBook() async throws {
    let receiver = try XCTUnwrap(
      receiver, "The E04 runner must provide the controlled receiver URL.")
    let token = try await loginAPI()
    let detail = try await json("books/1", token: token)
    let title = try XCTUnwrap(detail["title"] as? String)
    let scopes = try await catalogScopeFixture(token: token, title: title)
    let name = scopes.collectionName
    let collectionID = scopes.collectionID
    let scopeID = scopes.smartScopeID
    let app = try await launchAndSignIn(username: "ipad-owner", token: token)
    app.buttons["catalogSettings"].tap()
    XCTAssertTrue(app.textFields["catalogKOReaderUsername"].waitForExistence(timeout: 15))
    fill(app.textFields["catalogKOReaderUsername"], value: "ipad-catalog-koreader")
    fill(app.secureTextFields["catalogKOReaderPassword"], value: password)
    reveal(app.buttons["catalogKOReaderSave"], app: app)
    app.buttons["catalogKOReaderSave"].tap()
    XCTAssertTrue(app.staticTexts["KOReader credentials saved."].waitForExistence(timeout: 15))
    capture("IPAD-E04-A03-native-koreader-saved")
    fill(app.secureTextFields["catalogKOReaderPassword"], value: "WrongPassword123")
    reveal(app.buttons["catalogKOReaderTest"], app: app)
    app.buttons["catalogKOReaderTest"].tap()
    XCTAssertTrue(app.staticTexts["catalogError"].waitForExistence(timeout: 15))
    reveal(app.staticTexts["catalogError"], app: app)
    capture("IPAD-E04-A03-native-koreader-auth-failure")
    reveal(app.secureTextFields["catalogKOReaderPassword"], app: app)
    fill(app.secureTextFields["catalogKOReaderPassword"], value: password)
    reveal(app.buttons["catalogKOReaderTest"], app: app)
    app.buttons["catalogKOReaderTest"].tap()
    XCTAssertTrue(app.staticTexts["KOReader connection verified."].waitForExistence(timeout: 15))
    reveal(app.textFields["catalogOPDSUsername"], app: app)
    fill(app.textFields["catalogOPDSUsername"], value: "ipad-catalog-opds")
    fill(app.secureTextFields["catalogOPDSPassword"], value: password)
    reveal(app.buttons["catalogOPDSCreate"], app: app)
    app.buttons["catalogOPDSCreate"].tap()
    XCTAssertTrue(app.staticTexts["OPDS account created."].waitForExistence(timeout: 15))
    reveal(app.secureTextFields["catalogOPDSPassword"], app: app)
    fill(app.secureTextFields["catalogOPDSPassword"], value: password)
    reveal(app.buttons["catalogOPDSTest"], app: app)
    app.buttons["catalogOPDSTest"].tap()
    XCTAssertTrue(app.staticTexts["OPDS connection verified."].waitForExistence(timeout: 15))
    capture("IPAD-E04-A03-native-opds-verified")
    reveal(app.buttons["catalogChooseCollection"], app: app)
    app.buttons["catalogChooseCollection"].tap()
    XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10))
    app.searchFields.firstMatch.tap()
    app.searchFields.firstMatch.typeText(name + "\n")
    XCTAssertTrue(app.buttons["catalogCollection\(collectionID)"].waitForExistence(timeout: 10))
    XCTAssertLessThanOrEqual(
      app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "catalogCollection"))
        .count, 40)
    capture("IPAD-E04-A03-native-bounded-collection-selection")
    app.buttons["catalogCollection\(collectionID)"].tap()
    XCTAssertTrue(
      app.staticTexts.matching(
        NSPredicate(format: "label CONTAINS %@", "collectionId=\(collectionID)")
      ).firstMatch.waitForExistence(timeout: 10))
    capture("IPAD-E04-A03-native-collection-subscription")
    reveal(app.buttons["catalogChooseSmartScope"], app: app)
    app.buttons["catalogChooseSmartScope"].tap()
    XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10))
    app.searchFields.firstMatch.tap()
    app.searchFields.firstMatch.typeText(scopes.smartScopeName + "\n")
    XCTAssertTrue(app.buttons["catalogSmartScope\(scopeID)"].waitForExistence(timeout: 10))
    app.buttons["catalogSmartScope\(scopeID)"].tap()
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "smartScopeId=\(scopeID)"))
        .firstMatch.waitForExistence(timeout: 10))
    capture("IPAD-E04-A03-native-smart-scope-subscription")
    accessibilityAudit.collect(
      app, screen: "IPAD-E04-A03-native-smart-scope-subscription", testCase: self)
    let status = try await json("koreader/sync-status", token: token)
    let credentials = try XCTUnwrap(status["credentials"] as? [String: Any])
    XCTAssertEqual(credentials["username"] as? String, "ipad-catalog-koreader")
    let accounts = try await request("opds-users", token: token)
    let accountList = try XCTUnwrap(
      JSONSerialization.jsonObject(with: accounts) as? [[String: Any]])
    XCTAssertTrue(accountList.contains { $0["username"] as? String == "ipad-catalog-opds" })
    app.buttons["Done"].tap()
    if app.buttons["All books"].exists { app.buttons["All books"].tap() }
    app.buttons["Table"].tap()
    let search = app.textViews["librarySearch"]
    XCTAssertTrue(search.wait(for: \.isHittable, toEqual: true, timeout: 10))
    fill(search, value: title + "\n")
    let book = app.buttons["tableOpen1_title"]
    XCTAssertTrue(book.wait(for: \.isHittable, toEqual: true, timeout: 15))
    book.tap()
    XCTAssertTrue(app.buttons["Book details"].waitForExistence(timeout: 10))
    app.buttons["Book details"].tap()
    XCTAssertTrue(app.navigationBars["Book details"].waitForExistence(timeout: 10))
    XCTAssertTrue(
      app.collectionViews["bookDetailContent"].waitForExistence(timeout: 10)
        || app.tables["bookDetailContent"].exists)
    reveal(app.buttons["catalogBookDelivery"], app: app)
    app.buttons["catalogBookDelivery"].tap()
    reveal(app.descendants(matching: .any)["catalogBookFile1"], app: app)
    XCTAssertTrue(app.descendants(matching: .any)["catalogBookFile1"].exists)
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "/files/1/download"))
        .firstMatch.exists)
    capture("IPAD-E04-A03-native-selected-book-current-source-links")
    app.buttons["Done"].tap()
    app.buttons["Done"].tap()
    do {
      _ = try await requestURL(
        URL(string: receiver + "/native-handoff")!, method: "POST",
        body: [
          "testId": "IPAD-E04-A03", "case": "A03", "username": "ipad-owner",
          "catalog": [
            "koreaderUsername": "ipad-catalog-koreader", "koreaderPassword": password,
            "opdsUsername": "ipad-catalog-opds", "opdsPassword": password,
            "bookId": 1, "fileId": 1, "collectionId": collectionID, "smartScopeId": scopeID,
          ],
        ], expected: 204)
    }
    app.buttons["signOut"].tap()
    let restricted = try await launchAndSignIn(
      username: "ipad-restricted", minimumBookCount: 0, exactBookCount: 0)
    XCTAssertFalse(restricted.buttons["catalogSettings"].exists)
    capture("IPAD-E04-A03-native-catalog-permission-hidden")
    restricted.buttons["signOut"].tap()
  }

  @MainActor
  func testIPADE04A03KOReaderSetupAndMatching() async throws {
    executionTimeAllowance = 420
    let token = try await setupLogin()
    let username = "ipad-catalog-setup"
    let deviceID = "e04-setup-" + UUID().uuidString.lowercased()
    let hashes = (0..<2).map { _ in
      UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
    let initialUnmatched = try await setupList("koreader/unmatched-books", token: token)
    XCTAssertTrue(
      initialUnmatched.isEmpty,
      "Dedicated catalog account must be released by public catalog cleanup.")
    let primary = try await json("books/1", token: token)
    let alternate = try await json("books/2", token: token)
    let primaryTitle = try XCTUnwrap(primary["title"] as? String)
    let alternateTitle = try XCTUnwrap(alternate["title"] as? String)
    let app = try await launchAndSignIn(username: "ipad-catalog", token: token)
    app.buttons["catalogSettings"].tap()
    XCTAssertTrue(app.textFields["catalogKOReaderUsername"].waitForExistence(timeout: 15))
    fill(app.textFields["catalogKOReaderUsername"], value: username)
    fill(app.secureTextFields["catalogKOReaderPassword"], value: password)
    reveal(app.buttons["catalogKOReaderSave"], app: app)
    app.buttons["catalogKOReaderSave"].tap()
    XCTAssertTrue(app.staticTexts["KOReader credentials saved."].waitForExistence(timeout: 15))
    let credentials = try await json("koreader/sync-status", token: token)
    if (credentials["credentials"] as? [String: Any])?["syncEnabled"] as? Bool == false {
      reveal(app.buttons["catalogKOReaderToggle"], app: app)
      app.buttons["catalogKOReaderToggle"].tap()
      XCTAssertTrue(app.staticTexts["KOReader sync enabled."].waitForExistence(timeout: 15))
    }
    let initialPatternResponse = try await json("koreader/file-naming-pattern", token: token)
    let initialPattern = try XCTUnwrap(initialPatternResponse["pattern"] as? String)
    let device: [String: Any] = [
      "deviceId": deviceID, "deviceModel": "E04 native setup", "pluginVersion": "0.4.0",
    ]
    var matchInput = device
    matchInput["hashes"] = hashes
    matchInput["books"] = hashes.enumerated().map { index, hash in
      [
        "hash": hash, "title": "Isolated E04 unmatched \(index) \(deviceID)", "source": "file",
        "metadataAmbiguous": false,
      ] as [String: Any]
    }
    let matches = try await setupProtocol("match-check", username: username, body: matchInput)
    XCTAssertEqual((matches["matches"] as? [[String: Any]])?.count, 0)
    var sweepInput = device
    sweepInput["booksMatched"] = 0
    sweepInput["pageStatsUploaded"] = 0
    sweepInput["annotationsUpserted"] = 0
    _ = try await setupProtocol("sweeps", username: username, body: sweepInput)
    reveal(app.buttons["catalogKOReaderManagement"], app: app)
    app.buttons["catalogKOReaderManagement"].tap()
    XCTAssertTrue(
      app.buttons["koreaderPreparePlugin"].wait(for: \.isEnabled, toEqual: true, timeout: 20))
    let documents = try await setupDocuments()
    let exportedURL = documents.appendingPathComponent("bookorbit.koplugin.zip")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: exportedURL.path),
      "Use a fresh actual Files ZIP export.")
    app.buttons["koreaderPreparePlugin"].tap()
    XCTAssertTrue(app.buttons["koreaderSavePlugin"].waitForExistence(timeout: 20))
    capture("IPAD-E04-A03-koreader-configured-plugin-ready")
    app.buttons["koreaderSavePlugin"].tap()
    saveSetupPluginToFiles(app: app)
    setupResult(
      "Plugin ZIP saved. Extract it into koreader/plugins and restart KOReader.", app: app)
    let zip = try await setupExportBytes(exportedURL, documents: documents)
    let receipt = try CatalogPluginArtifactSupport.validate(
      zip, server: base, username: username, password: password)
    let attachment = XCTAttachment(data: zip, uniformTypeIdentifier: "public.zip-archive")
    attachment.name = "IPAD-E04-A03-koreader-actual-Files-export.zip"
    attachment.lifetime = .keepAlways
    add(attachment)
    let receiptAttachment = XCTAttachment(
      data: try JSONSerialization.data(withJSONObject: receipt, options: .sortedKeys),
      uniformTypeIdentifier: "public.json")
    receiptAttachment.name = "IPAD-E04-A03-koreader-actual-ZIP-receipt"
    receiptAttachment.lifetime = .keepAlways
    add(receiptAttachment)
    capture("IPAD-E04-A03-koreader-native-Files-export-saved")

    setupFill("koreaderDefaultPattern", value: "Invalid*Pattern", app: app)
    reveal(app.buttons["koreaderDefaultPatternSave"], app: app)
    app.buttons["koreaderDefaultPatternSave"].tap()
    XCTAssertTrue(app.staticTexts["koreaderManagementError"].waitForExistence(timeout: 15))
    capture("IPAD-E04-A03-koreader-naming-validation-error")
    setupFill("koreaderDefaultPattern", value: "E04Setup/{title}", app: app)
    reveal(app.buttons["koreaderDefaultPatternSave"], app: app)
    app.buttons["koreaderDefaultPatternSave"].tap()
    setupResult("Default file naming pattern saved.", app: app)
    let savedPattern = try await json("koreader/file-naming-pattern", token: token)
    XCTAssertEqual(savedPattern["pattern"] as? String, "E04Setup/{title}")
    let deviceButton = app.buttons["koreaderManageDevice\(deviceID)"]
    reveal(deviceButton, app: app)
    deviceButton.tap()
    setupFill("koreaderDevicePattern", value: "E04Device/{title}", app: app)
    setupFill("koreaderDeviceSeriesPattern", value: "E04Series/{series}/{title}", app: app)
    setupFill("koreaderDeviceStandalonePattern", value: "E04Standalone/{title}", app: app)
    reveal(app.buttons["koreaderDevicePatternsSave"], app: app)
    app.buttons["koreaderDevicePatternsSave"].tap()
    setupResult("Device file naming patterns saved.", app: app)
    let configured = try await setupDevice(deviceID, token: token)
    XCTAssertEqual(configured["fileNamingPattern"] as? String, "E04Device/{title}")
    XCTAssertEqual(configured["seriesFileNamingPattern"] as? String, "E04Series/{series}/{title}")
    XCTAssertEqual(configured["standaloneFileNamingPattern"] as? String, "E04Standalone/{title}")
    let catalog = try await setupProtocol(
      "catalog/books/1?deviceId=\(deviceID)", username: username)
    let files = try XCTUnwrap(catalog["files"] as? [[String: Any]])
    let hasSeries = !(primary["seriesName"] is NSNull) && primary["seriesName"] as? String != nil
    XCTAssertTrue(
      files.contains {
        ($0["devicePath"] as? String)?.hasPrefix(hasSeries ? "E04Series/" : "E04Standalone/")
          == true
      })
    capture("IPAD-E04-A03-koreader-device-naming-persisted")
    reveal(app.buttons["koreaderDevicePatternsReset"], app: app)
    app.buttons["koreaderDevicePatternsReset"].tap()
    setupResult("Device file naming patterns reset to the account default.", app: app)
    let reset = try await setupDevice(deviceID, token: token)
    for field in ["fileNamingPattern", "seriesFileNamingPattern", "standaloneFileNamingPattern"] {
      XCTAssertTrue(reset[field] is NSNull || reset[field] as? String == "" || reset[field] == nil)
    }
    reveal(app.buttons["koreaderDeviceRetire"], app: app)
    app.buttons["koreaderDeviceRetire"].tap()
    app.buttons["Retire device"].tap()
    setupResult("Device retired.", app: app)
    let retired = try await setupDevice(deviceID, token: token)
    XCTAssertNotNil(retired["retiredAt"] as? String)
    reveal(app.buttons["koreaderDeviceRetire"], app: app)
    app.buttons["koreaderDeviceRetire"].tap()
    app.buttons["Restore device"].tap()
    setupResult("Device restored.", app: app)
    let restored = try await setupDevice(deviceID, token: token)
    XCTAssertTrue(restored["retiredAt"] is NSNull)
    capture("IPAD-E04-A03-koreader-device-retirement-restored")
    setupBack("E04 native setup", app: app)

    reveal(app.buttons["koreaderManageHashLinks"], app: app)
    app.buttons["koreaderManageHashLinks"].tap()
    let link = app.buttons["koreaderLinkUnmatched\(hashes[0])"]
    reveal(link, app: app)
    link.tap()
    XCTAssertTrue(app.textFields["koreaderLinkTargetSearch"].waitForExistence(timeout: 15))
    XCTAssertLessThanOrEqual(
      app.buttons.matching(
        NSPredicate(format: "identifier BEGINSWITH %@", "koreaderLinkTargetBook")
      ).count, 40)
    fill(app.textFields["koreaderLinkTargetSearch"], value: primaryTitle)
    app.buttons["koreaderLinkTargetSearchSubmit"].tap()
    let primaryTarget = app.buttons["koreaderLinkTargetBook1"]
    XCTAssertTrue(primaryTarget.wait(for: \.isHittable, toEqual: true, timeout: 15))
    XCTAssertTrue(primaryTarget.wait(for: \.isEnabled, toEqual: true, timeout: 15))
    capture("IPAD-E04-A03-koreader-bounded-library-link-picker")
    primaryTarget.tap()
    setupResult("KOReader book linked.", app: app)
    let linked = try await setupList("koreader/hash-links", token: token)
    XCTAssertEqual(linked.first { $0["hash"] as? String == hashes[0] }?["bookId"] as? Int, 1)
    let relink = app.buttons["koreaderRelinkHash\(hashes[0])"]
    reveal(relink, app: app)
    relink.tap()
    XCTAssertTrue(app.textFields["koreaderLinkTargetSearch"].waitForExistence(timeout: 10))
    fill(app.textFields["koreaderLinkTargetSearch"], value: alternateTitle)
    app.buttons["koreaderLinkTargetSearchSubmit"].tap()
    let alternateTarget = app.buttons["koreaderLinkTargetBook2"]
    XCTAssertTrue(alternateTarget.wait(for: \.isHittable, toEqual: true, timeout: 15))
    XCTAssertTrue(alternateTarget.wait(for: \.isEnabled, toEqual: true, timeout: 15))
    alternateTarget.tap()
    setupResult("Book link changed.", app: app)
    let relinked = try await setupList("koreader/hash-links", token: token)
    XCTAssertEqual(relinked.first { $0["hash"] as? String == hashes[0] }?["bookId"] as? Int, 2)
    capture("IPAD-E04-A03-koreader-manual-link-target-changed")
    reveal(app.buttons["koreaderUnlinkHash\(hashes[0])"], app: app)
    app.buttons["koreaderUnlinkHash\(hashes[0])"].tap()
    app.buttons["Remove link"].tap()
    setupResult("Manual book link removed.", app: app)
    let unlinked = try await setupList("koreader/hash-links", token: token)
    XCTAssertFalse(unlinked.contains { $0["hash"] as? String == hashes[0] })
    reveal(app.buttons["koreaderDismissUnmatched\(hashes[0])"], app: app)
    app.buttons["koreaderDismissUnmatched\(hashes[0])"].tap()
    app.buttons["Dismiss book"].tap()
    setupResult("Unmatched book dismissed.", app: app)
    let remaining = try await setupList("koreader/unmatched-books", token: token)
    XCTAssertEqual(
      remaining.compactMap { $0["hash"] as? String }, [hashes[1]],
      "Bulk dismissal is limited to this dedicated fixture's remaining hash.")
    reveal(app.buttons["koreaderDismissAllUnmatched"], app: app)
    app.buttons["koreaderDismissAllUnmatched"].tap()
    app.buttons["Dismiss all"].tap()
    setupResult("Dismissed 1 unmatched books.", app: app)
    let dismissed = try await setupList("koreader/unmatched-books", token: token)
    XCTAssertTrue(dismissed.isEmpty)
    capture("IPAD-E04-A03-koreader-manual-and-unmatched-cleanup")
    setupBack("Book matching", app: app)
    setupFill("koreaderDefaultPattern", value: initialPattern, app: app)
    reveal(app.buttons["koreaderDefaultPatternSave"], app: app)
    app.buttons["koreaderDefaultPatternSave"].tap()
    setupResult("Default file naming pattern saved.", app: app)
    reveal(app.buttons["koreaderManageDevice\(deviceID)"], app: app)
    app.buttons["koreaderManageDevice\(deviceID)"].tap()
    reveal(app.buttons["koreaderDeviceRemove"], app: app)
    app.buttons["koreaderDeviceRemove"].tap()
    app.buttons["Remove device"].tap()
    XCTAssertTrue(app.navigationBars["KOReader setup"].waitForExistence(timeout: 15))
    let finalStatus = try await json("koreader/sync-status", token: token)
    let deviceRows =
      (finalStatus["devices"] as? [[String: Any]] ?? [])
      + (finalStatus["sweeps"] as? [[String: Any]] ?? [])
    XCTAssertFalse(deviceRows.contains { $0["deviceId"] as? String == deviceID })
    capture("IPAD-E04-A03-koreader-device-removed")
    if let receiver {
      _ = try await requestURL(
        URL(string: receiver + "/native-handoff")!, method: "POST",
        body: [
          "testId": "IPAD-E04-A03", "case": "A03", "username": "ipad-owner",
          "catalogManagement": [
            "username": "ipad-catalog", "deviceId": deviceID, "externalProtocolInput": true,
            "zip": receipt,
          ],
        ], expected: 204)
    }
    app.terminate()
  }

  @MainActor
  func testIPADE04A04NativePublishedPDFInkRedeliversForWebDeletion() async throws {
    let receiver = try XCTUnwrap(
      receiver, "The E04 runner must provide the controlled receiver URL.")
    let token = try await loginAPI()
    let initial = try await json("annotations/native/files/1/source?bookId=1&page=0", token: token)
    let before = try await inkItems(token: token)
    let beforeIDs = Set(before.compactMap { $0["id"] as? Int })
    let app = try await launchAndSignIn(
      username: "ipad-owner", token: token, annotationFixture: true)
    app.buttons["catalogSettings"].tap()
    XCTAssertTrue(app.textFields["catalogKOReaderUsername"].waitForExistence(timeout: 15))
    reveal(app.textFields["catalogOPDSUsername"], app: app)
    fill(app.textFields["catalogOPDSUsername"], value: "ipad-catalog-opds")
    fill(app.secureTextFields["catalogOPDSPassword"], value: password)
    if !app.staticTexts["ipad-catalog-opds"].exists {
      reveal(app.buttons["catalogOPDSCreate"], app: app)
      app.buttons["catalogOPDSCreate"].tap()
      XCTAssertTrue(app.staticTexts["OPDS account created."].waitForExistence(timeout: 15))
      reveal(app.secureTextFields["catalogOPDSPassword"], app: app)
      fill(app.secureTextFields["catalogOPDSPassword"], value: password)
    }
    reveal(app.buttons["catalogOPDSTest"], app: app)
    app.buttons["catalogOPDSTest"].tap()
    XCTAssertTrue(app.staticTexts["OPDS connection verified."].waitForExistence(timeout: 15))
    capture("IPAD-E04-A04-native-current-source-catalog-account")
    app.buttons["Done"].tap()
    if app.buttons["All books"].exists { app.buttons["All books"].tap() }
    app.buttons["Table"].tap()
    fill(app.textViews["librarySearch"], value: "Orbit fixture\n")
    let title = app.buttons["tableOpen1_title"]
    XCTAssertTrue(title.wait(for: \.isHittable, toEqual: true, timeout: 15))
    title.tap()
    app.buttons["Book details"].tap()
    XCTAssertTrue(app.navigationBars["Book details"].waitForExistence(timeout: 10))
    XCTAssertTrue(E02ProfileSupport.openBookFile(app: app, fileID: 1))
    XCTAssertTrue(app.staticTexts["Page 1 of 3"].waitForExistence(timeout: 20))
    tapInk("pdfInkFixtureStroke", app: app)
    let created = try await waitForInk(token: token) { items in
      items.first { !beforeIDs.contains($0["id"] as? Int ?? -1) && $0["deletedAt"] is NSNull }
    }
    let annotationID = try XCTUnwrap(created["id"] as? Int)
    let clientID = try XCTUnwrap(created["clientId"] as? String)
    let version = try XCTUnwrap(created["version"] as? Int)
    XCTAssertTrue(app.images["pdfInkItem\(clientID)"].waitForExistence(timeout: 10))
    capture("IPAD-E04-A04-native-pencil-boundary-published-source-ink")
    tapInk("pdfInkSelect", app: app)
    let selected = app.buttons["pdfInkSelectItem\(clientID)"]
    XCTAssertTrue(selected.wait(for: \.isHittable, toEqual: true, timeout: 10))
    selected.tap()
    tapInk("pdfInkMoveRight", app: app)
    let moved = try await waitForInk(token: token) { items in
      items.first { $0["id"] as? Int == annotationID && ($0["version"] as? Int ?? 0) > version }
    }
    XCTAssertNotEqual(
      try JSONSerialization.data(
        withJSONObject: try XCTUnwrap(created["drawing"]), options: .sortedKeys),
      try JSONSerialization.data(
        withJSONObject: try XCTUnwrap(moved["drawing"]), options: .sortedKeys))
    let current = try await json("annotations/native/files/1/source?bookId=1&page=0", token: token)
    XCTAssertNotEqual(initial["sourceRevision"] as? String, current["sourceRevision"] as? String)
    XCTAssertEqual(moved["sourceRevision"] as? String, current["sourceRevision"] as? String)
    capture("IPAD-E04-A04-native-ink-move-published-for-redelivery")
    accessibilityAudit.collect(
      app, screen: "IPAD-E04-A04-native-ink-move-published-for-redelivery", testCase: self)
    _ = try await requestURL(
      URL(string: receiver + "/native-handoff")!, method: "POST",
      body: [
        "testId": "IPAD-E04-A04", "case": "A04", "username": "ipad-owner",
        "bookId": 1, "fileId": 1,
        "initialRevision": try XCTUnwrap(initial["sourceRevision"] as? String),
        "catalog": [
          "bookId": 1, "fileId": 1, "opdsUsername": "ipad-catalog-opds", "opdsPassword": password,
        ],
        "ink": [
          "annotationId": annotationID, "clientId": clientID,
          "version": try XCTUnwrap(moved["version"] as? Int),
          "sourceRevision": try XCTUnwrap(current["sourceRevision"] as? String),
          "drawing": try XCTUnwrap(moved["drawing"]), "pdf": try XCTUnwrap(moved["pdf"]),
        ],
      ], expected: 204)
    app.buttons["Close reader"].tap()
    app.buttons["Done"].tap()
  }

  @MainActor
  private func catalogScopeFixture(token: String, title: String) async throws -> CatalogScopeFixture
  {
    let expectedFilter: [String: Any] = [
      "type": "group", "join": "AND",
      "rules": [["type": "rule", "field": "title", "operator": "eq", "value": title]],
    ]
    let collectionName = "E04 native catalog collection"
    let smartScopeName = "E04 native catalog scope"
    if let literal = ProcessInfo.processInfo.environment["IPAD_E04_CATALOG_CONTINUATION_FIXTURE"] {
      let bytes = Data(literal.utf8)
      XCTAssertLessThanOrEqual(bytes.count, 4096)
      let fixture = try JSONDecoder().decode(CatalogScopeFixture.self, from: bytes)
      XCTAssertGreaterThan(fixture.collectionID, 0)
      XCTAssertGreaterThan(fixture.smartScopeID, 0)
      XCTAssertEqual(fixture.collectionName, collectionName)
      XCTAssertEqual(fixture.smartScopeName, smartScopeName)
      let collection = try await json("collections/\(fixture.collectionID)", token: token)
      XCTAssertEqual(collection["id"] as? Int, fixture.collectionID)
      XCTAssertEqual(collection["name"] as? String, fixture.collectionName)
      XCTAssertEqual(collection["isOwner"] as? Bool, true)
      XCTAssertEqual(collection["mediaType"] as? String, "books")
      XCTAssertEqual(collection["bookCount"] as? Int, 1)
      let members = try await json(
        "collections/\(fixture.collectionID)/books?page=0&size=1&collapseSeries=false", token: token
      )
      let items = try XCTUnwrap(members["items"] as? [[String: Any]])
      XCTAssertEqual(members["total"] as? Int, 1)
      XCTAssertEqual(items.count, 1)
      XCTAssertEqual(items.first?["id"] as? Int, 1)
      let scope = try await json("smart-scopes/\(fixture.smartScopeID)", token: token)
      XCTAssertEqual(scope["id"] as? Int, fixture.smartScopeID)
      XCTAssertEqual(scope["name"] as? String, fixture.smartScopeName)
      XCTAssertEqual(scope["isOwner"] as? Bool, true)
      XCTAssertEqual(scope["mediaType"] as? String, "books")
      let filter = try XCTUnwrap(scope["filter"] as? [String: Any])
      XCTAssertEqual(
        try JSONSerialization.data(withJSONObject: filter, options: .sortedKeys),
        try JSONSerialization.data(withJSONObject: expectedFilter, options: .sortedKeys))
      let receipt = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.json")
      receipt.name = "IPAD-E04-A03-actual-retained-scope-continuation"
      receipt.lifetime = .keepAlways
      add(receipt)
      return fixture
    }
    let collection = try await json(
      "collections", token: token,
      body: [
        "name": collectionName, "icon": "Folder", "mediaType": "books", "isPublic": false,
      ])
    let collectionID = try XCTUnwrap(collection["id"] as? Int)
    _ = try await json("collections/\(collectionID)/books", token: token, body: ["bookIds": [1]])
    let scope = try await json(
      "smart-scopes", token: token,
      body: [
        "name": smartScopeName, "icon": "filter", "mediaType": "books", "isPublic": false,
        "filter": expectedFilter,
      ])
    return CatalogScopeFixture(
      collectionID: collectionID, collectionName: collectionName,
      smartScopeID: try XCTUnwrap(scope["id"] as? Int), smartScopeName: smartScopeName)
  }

  @MainActor
  private func catalogLibraryCountLabel(token: String, username: String, minimum: Int, exact: Int?)
    async throws -> String
  {
    let bytes = try await requestURL(
      URL(string: base + "/api/v1/books/query")!, method: "POST", token: token,
      body: [
        "sort": [] as [[String: String]], "pagination": ["page": 0, "size": 1],
        "collapseSeries": false, "q": "",
      ], expected: 201)
    XCTAssertLessThanOrEqual(bytes.count, 1024 * 1024)
    let page = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    let total = try XCTUnwrap(page["total"] as? Int)
    let items = try XCTUnwrap(page["items"] as? [[String: Any]])
    XCTAssertEqual(page["page"] as? Int, 0)
    XCTAssertEqual(page["size"] as? Int, 1)
    XCTAssertGreaterThanOrEqual(
      total, minimum, "Catalog acceptance retains the actual 50,000-book scale requirement.")
    if let exact { XCTAssertEqual(total, exact) }
    XCTAssertEqual(items.count, total == 0 ? 0 : 1)
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 0
    formatter.usesGroupingSeparator = true
    let number = try XCTUnwrap(formatter.string(from: NSNumber(value: total)))
    let label = total == 1 ? "1 book" : "\(number) books"
    let receipt = XCTAttachment(
      data: try JSONSerialization.data(
        withJSONObject: [
          "username": username, "total": total, "page": 0, "size": 1, "returned": items.count,
          "minimum": minimum, "nativeLabel": label, "locale": "en_US",
        ], options: .sortedKeys), uniformTypeIdentifier: "public.json")
    receipt.name = "IPAD-E04-native-catalog-scoped-login-count-\(username)"
    receipt.lifetime = .keepAlways
    add(receipt)
    return label
  }

  @MainActor
  private func setupLogin() async throws -> String {
    let response = try await json(
      "auth/login",
      body: [
        "username": "ipad-catalog", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "Catalog setup native UI fixture",
      ])
    return try XCTUnwrap(response["accessToken"] as? String)
  }

  @MainActor
  private func setupList(_ path: String, token: String) async throws -> [[String: Any]] {
    let bytes = try await request(path, token: token)
    let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [[String: Any]])
    XCTAssertLessThanOrEqual(rows.count, 100)
    return rows
  }

  @MainActor
  private func setupProtocol(_ path: String, username: String, body: [String: Any]? = nil)
    async throws -> [String: Any]
  {
    var request = URLRequest(
      url: try XCTUnwrap(URL(string: base + "/api/v1/koreader/plugin/" + path)))
    request.httpMethod = body == nil ? "GET" : "POST"
    request.timeoutInterval = 20
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue(username, forHTTPHeaderField: "X-Auth-User")
    request.setValue(password, forHTTPHeaderField: "X-Auth-Key")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (bytes, response) = try await E04FixtureHTTP.data(for: request)
    XCTAssertTrue((200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0))
    XCTAssertLessThanOrEqual(bytes.count, 1024 * 1024)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
  }

  @MainActor
  private func setupDevice(_ id: String, token: String) async throws -> [String: Any] {
    let status = try await json("koreader/sync-status", token: token)
    let rows =
      (status["devices"] as? [[String: Any]] ?? []) + (status["sweeps"] as? [[String: Any]] ?? [])
    return try XCTUnwrap(rows.first { $0["deviceId"] as? String == id })
  }

  @MainActor
  private func setupFill(_ identifier: String, value: String, app: XCUIApplication) {
    reveal(app.descendants(matching: .any)[identifier], app: app)
    let field = app.textFields[identifier]
    let text = app.textViews[identifier]
    let control = field.exists ? field : text
    fill(control, value: value)
  }

  @MainActor
  private func setupResult(_ message: String, app: XCUIApplication) {
    let result = app.staticTexts["koreaderManagementResult"]
    XCTAssertTrue(result.waitForExistence(timeout: 20))
    let expected = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", message), object: result)
    XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 20), .completed)
    reveal(result, app: app)
  }

  @MainActor
  private func setupBack(_ currentTitle: String, app: XCUIApplication) {
    let back = app.navigationBars[currentTitle].buttons.element(boundBy: 0)
    XCTAssertTrue(back.wait(for: \.isHittable, toEqual: true, timeout: 10))
    back.tap()
  }

  @MainActor
  private func setupDocuments() async throws -> URL {
    let directory: String
    if let configured = ProcessInfo.processInfo.environment["IPAD_E04_EXPORTED_ARTIFACT_DIRECTORY"]
    {
      directory = configured
    } else {
      let fault = try XCTUnwrap(
        ProcessInfo.processInfo.environment["IPAD_E04_FAULT_URL"],
        "Harness must provide the installed public Documents directory for the actual Files export."
      )
      let bytes = try await requestURL(
        try XCTUnwrap(URL(string: fault + "/__faults/annotations/public-files-directory")),
        method: "GET", expected: 200)
      let response = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
      directory = try XCTUnwrap(response["directory"] as? String)
    }
    XCTAssertTrue(directory.hasPrefix("/"))
    let documents = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
    let attributes = try documents.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    XCTAssertEqual(documents.lastPathComponent, "Documents")
    XCTAssertEqual(attributes.isDirectory, true)
    XCTAssertEqual(attributes.isSymbolicLink, false)
    return documents.resolvingSymlinksInPath()
  }

  @MainActor
  private func saveSetupPluginToFiles(app: XCUIApplication) {
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
    capture("IPAD-E04-A03-koreader-save-to-native-Files-dialog")
    XCTAssertTrue(save.isHittable)
    save.tap()
    XCTAssertTrue(save.wait(for: \.exists, toEqual: false, timeout: 15))
  }

  @MainActor
  private func setupExportBytes(_ url: URL, documents: URL) async throws -> Data {
    let deadline = Date().addingTimeInterval(15)
    while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
      try await Task.sleep(for: .milliseconds(200))
    }
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: url.path),
      "Read the actual file saved through the native Files provider.")
    let attributes = try url.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    XCTAssertEqual(attributes.isRegularFile, true)
    XCTAssertEqual(attributes.isSymbolicLink, false)
    XCTAssertEqual(url.resolvingSymlinksInPath().deletingLastPathComponent(), documents)
    let size = try XCTUnwrap(attributes.fileSize)
    XCTAssertGreaterThan(size, 0)
    XCTAssertLessThanOrEqual(size, 16 * 1024 * 1024)
    let bytes = try Data(contentsOf: url)
    XCTAssertEqual(bytes.count, size)
    return bytes
  }

  @MainActor
  private func inkItems(token: String) async throws -> [[String: Any]] {
    let response = try await json(
      "annotations/native/source-ink?bookId=1&bookFileId=1&cursor=0&limit=100", token: token)
    XCTAssertEqual(
      response["hasMore"] as? Bool, false, "The deterministic ink fixture stays bounded.")
    return try XCTUnwrap(response["items"] as? [[String: Any]])
  }

  @MainActor
  private func waitForInk(token: String, condition: ([[String: Any]]) -> [String: Any]?)
    async throws -> [String: Any]
  {
    let deadline = Date().addingTimeInterval(20)
    repeat {
      if let item = condition(try await inkItems(token: token)) { return item }
      try await Task.sleep(for: .milliseconds(250))
    } while Date() < deadline
    throw XCTUnwrapFailure.missingPublishedInk
  }

  @MainActor
  private func tapInk(_ identifier: String, app: XCUIApplication) {
    let control = app.buttons[identifier]
    let toolbar = app.scrollViews["pdfInkToolbar"]
    XCTAssertTrue(control.waitForExistence(timeout: 10))
    XCTAssertTrue(toolbar.exists)
    for _ in 0..<8 {
      if control.isHittable && toolbar.frame.intersection(app.frame).contains(control.frame) {
        break
      }
      let forward = control.frame.minX >= toolbar.frame.minX
      let y = (control.frame.midY - toolbar.frame.minY) / toolbar.frame.height
      let from = toolbar.coordinate(withNormalizedOffset: CGVector(dx: forward ? 0.7 : 0.3, dy: y))
      let to = toolbar.coordinate(withNormalizedOffset: CGVector(dx: forward ? 0.3 : 0.7, dy: y))
      from.press(forDuration: 0.05, thenDragTo: to)
    }
    XCTAssertTrue(control.isHittable)
    control.tap()
    XCTAssertTrue(app.staticTexts["Page 1 of 3"].exists)
  }

  @MainActor
  private func launchAndSignIn(
    username: String, token: String? = nil, minimumBookCount: Int = 50_000,
    exactBookCount: Int? = nil, annotationFixture: Bool = false
  )
    async throws -> XCUIApplication
  {
    let scopedToken: String
    if let token {
      scopedToken = token
    } else {
      scopedToken = try await loginAPI(username: username)
    }
    let expectedCount = try await catalogLibraryCountLabel(
      token: scopedToken, username: username, minimum: minimumBookCount, exact: exactBookCount)
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    if annotationFixture {
      app.launchArguments.append("--annotation-input-driver")
      app.launchEnvironment["BOOKORBIT_ANNOTATION_INPUT_FIXTURE"] = "1"
    }
    app.launch()
    if !app.textFields["serverURL"].waitForExistence(timeout: 5) {
      if app.buttons["signOut"].exists { app.buttons["signOut"].tap() }
      if app.buttons["Change server"].exists { app.buttons["Change server"].tap() }
    }
    fill(app.textFields["serverURL"], value: base)
    app.buttons["connectServer"].tap()
    XCTAssertTrue(app.textFields["username"].wait(for: \.isHittable, toEqual: true, timeout: 10))
    fill(app.textFields["username"], value: username)
    fill(app.secureTextFields["password"], value: "IpadFixture123")
    app.buttons["signIn"].tap()
    XCTAssertTrue(app.staticTexts[expectedCount].waitForExistence(timeout: 20))
    return app
  }

  @MainActor
  private func fill(_ element: XCUIElement, value: String) {
    XCTAssertTrue(element.wait(for: \.isHittable, toEqual: true, timeout: 10))
    element.tap()
    let existing = element.value as? String ?? ""
    if !existing.isEmpty {
      element.typeText(
        String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.utf16.count))
    }
    element.typeText(value)
  }

  @MainActor
  private func reveal(_ element: XCUIElement, app: XCUIApplication) {
    let list =
      app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
    for _ in 0..<14 {
      if element.exists && element.isHittable && app.frame.contains(element.frame) { return }
      if element.exists && element.frame.minY < list.frame.minY {
        list.swipeDown()
      } else {
        list.swipeUp()
      }
    }
    XCTAssertTrue(element.isHittable)
  }

  @MainActor
  private func loginAPI(username: String = "ipad-owner") async throws -> String {
    let result = try await json(
      "auth/login",
      body: [
        "username": username, "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "Catalog native UI fixture",
      ])
    return try XCTUnwrap(result["accessToken"] as? String)
  }

  @MainActor
  private func json(_ path: String, token: String? = nil, body: [String: Any]? = nil) async throws
    -> [String: Any]
  {
    let data = try await request(path, token: token, body: body)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @MainActor
  private func request(_ path: String, token: String? = nil, body: [String: Any]? = nil)
    async throws -> Data
  {
    try await requestURL(
      URL(string: base + "/api/v1/" + path)!, method: body == nil ? "GET" : "POST", token: token,
      body: body)
  }

  @MainActor
  private func requestURL(
    _ url: URL, method: String, token: String? = nil, body: [String: Any]? = nil,
    expected: Int? = nil
  ) async throws -> Data {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 20
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await E04FixtureHTTP.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if let expected {
      XCTAssertEqual(status, expected)
    } else {
      XCTAssertTrue(
        (200..<300).contains(status), String(data: data, encoding: .utf8) ?? "Invalid response")
    }
    return data
  }

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}

private struct CatalogScopeFixture: Codable {
  let collectionID: Int
  let collectionName: String
  let smartScopeID: Int
  let smartScopeName: String

  private enum CodingKeys: String, CodingKey {
    case collectionID = "collectionId"
    case collectionName
    case smartScopeID = "smartScopeId"
    case smartScopeName
  }
}

private enum XCTUnwrapFailure: Error { case missingPublishedInk }
