import CryptoKit
import Foundation
import PDFKit
import XCTest

final class AnnotationJourneyTests: XCTestCase {
  private nonisolated static let networkSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 5
    configuration.timeoutIntervalForResource = 8
    configuration.waitsForConnectivity = false
    return URLSession(configuration: configuration)
  }()

  private nonisolated static var fixtureServerURL: String {
    loopbackURL(
      ProcessInfo.processInfo.environment["IPAD_ANNOTATION_SERVER_URL"]
        ?? "http://127.0.0.1:16482")
  }

  private nonisolated static var faultServerURL: String {
    loopbackURL(
      ProcessInfo.processInfo.environment["IPAD_ANNOTATION_FAULT_URL"]
        ?? "http://127.0.0.1:16485")
  }

  private nonisolated static func loopbackURL(_ value: String) -> String {
    guard var components = URLComponents(string: value) else { return value }
    if components.host == "localhost" { components.host = "127.0.0.1" }
    if components.path == "/api/v1" { components.path = "" }
    return components.string?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? value
  }

  private nonisolated static func networkResponse(for input: URLRequest) async throws
    -> (Data, URLResponse)
  {
    var request = input
    request.timeoutInterval = 5
    return try await networkSession.data(for: request)
  }

  private nonisolated static func logoutCleanup(refresh: String, endpoint: URL)
    -> @Sendable () async throws -> Void
  {
    {
      var request = URLRequest(url: endpoint)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: ["refreshToken": refresh])
      let (_, response) = try await networkResponse(for: request)
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }
  }

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
  }

  override func tearDown() async throws {
    if let testRun, testRun.failureCount > 0 {
      let screenshot = await MainActor.run { XCUIScreen.main.screenshot().pngRepresentation }
      let attachment = XCTAttachment(data: screenshot, uniformTypeIdentifier: "public.png")
      attachment.name = "IPAD-E02-native-failure-\(name)"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    try await super.tearDown()
  }

  @MainActor
  func testIPADE02A01NativePassageToolsReachable() throws {
    let app = launchAndSignIn()
    openBook("Native renderer proof", fileID: 2, app: app)
    previewPassage(app)
    let save = app.buttons["passageSave"]
    XCTAssertTrue(save.wait(for: \.isEnabled, toEqual: true, timeout: 10))
    capture("IPAD-E02-A01-native-passage-tools-reachable")
    save.tap()
    XCTAssertTrue(
      app.staticTexts["passageSelectionPreview"].wait(for: \.exists, toEqual: false, timeout: 10))
    XCTAssertTrue(app.buttons["passageUndo"].wait(for: \.isEnabled, toEqual: true, timeout: 10))
  }

  @MainActor
  func testIPADE02A01PreviewAndSaveEPUBHighlight() async throws {
    let token = try await loginAPI()
    let before = try await annotations(bookID: 2, token: token)
    let existingIDs = Set(before.compactMap { $0["id"] as? Int })
    let app = launchAndSignIn()
    openBook("Native renderer proof", fileID: 2, app: app)
    let selection = app.buttons["epubFixtureSelectPassage"]
    XCTAssertTrue(selection.wait(for: \.isHittable, toEqual: true, timeout: 20))
    selection.tap()
    openSelectedPassagePreview(app)
    let preview = app.staticTexts["passageSelectionPreview"]
    XCTAssertTrue(preview.waitForExistence(timeout: 10))
    XCTAssertTrue(preview.label.contains("Alpha"))
    XCTAssertTrue(preview.label.contains("omega."))
    XCTAssertTrue(app.buttons["Highlight"].exists)
    capture("IPAD-E02-A01-highlight-semantic-preview")
    app.buttons["passageSave"].tap()
    XCTAssertTrue(preview.wait(for: \.exists, toEqual: false, timeout: 10))
    let saved = try await waitForAnnotations(bookID: 2, token: token) { items in
      items.contains {
        $0["kind"] as? String == "highlight" && !existingIDs.contains($0["id"] as? Int ?? -1)
      }
    }
    let highlightItem = try XCTUnwrap(
      saved.first {
        $0["kind"] as? String == "highlight" && !existingIDs.contains($0["id"] as? Int ?? -1)
      })
    let highlightID = try XCTUnwrap(highlightItem["id"] as? Int)
    XCTAssertTrue((highlightItem["cfi"] as? String ?? "").hasPrefix("epubcfi("))
    app.buttons["epubPassageNotes"].tap()
    let highlight = app.buttons["passageEdit\(highlightID)"]
    XCTAssertTrue(highlight.waitForExistence(timeout: 15))
    highlight.tap()
    XCTAssertTrue(preview.waitForExistence(timeout: 5))
    app.buttons["passageCancel"].tap()
    XCTAssertTrue(app.buttons["passageUndo"].isEnabled)
    capture("IPAD-E02-A01-highlight-saved")
    app.buttons["passageUndo"].tap()
    _ = try await waitForAnnotations(bookID: 2, token: token) { items in
      items.contains { $0["id"] as? Int == highlightID && $0["deletedAt"] is String }
    }
    capture("IPAD-E02-A01-one-operation-highlight-undo")
  }

  @MainActor
  func testIPADE02A01ScribbleCompletionAndRetainedHandwritingSurviveReflow() async throws {
    let token = try await loginAPI()
    let initial = try await annotations(bookID: 2, token: token)
    let existingIDs = Set(initial.compactMap { $0["id"] as? Int })
    let app = launchAndSignIn()
    openBook("Native renderer proof", fileID: 2, app: app)
    previewPassage(app)
    app.buttons["Text note"].tap()
    let scribble = app.buttons["passageFixtureScribble"]
    XCTAssertTrue(scribble.wait(for: \.isHittable, toEqual: true, timeout: 5))
    scribble.tap()
    XCTAssertEqual(
      app.textViews["passageNoteText"].value as? String,
      "Converted English passage fixture")
    capture("IPAD-E02-A01-tagged-Scribble-completion-preview")
    app.buttons["passageSave"].tap()
    XCTAssertTrue(
      app.staticTexts["passageSelectionPreview"].wait(for: \.exists, toEqual: false, timeout: 10))
    previewPassage(app)
    app.buttons["Handwriting"].tap()
    XCTAssertTrue(app.staticTexts["0 retained strokes"].waitForExistence(timeout: 5))
    app.buttons["passageFixtureStroke"].tap()
    XCTAssertTrue(app.staticTexts["1 retained strokes"].waitForExistence(timeout: 5))
    capture("IPAD-E02-A01-tagged-Pencil-retained-stroke-preview")
    app.buttons["passageSave"].tap()
    XCTAssertTrue(
      app.staticTexts["passageSelectionPreview"].wait(for: \.exists, toEqual: false, timeout: 10))
    let saved = try await waitForAnnotations(bookID: 2, token: token) { items in
      items.filter { !existingIDs.contains($0["id"] as? Int ?? -1) && $0["deletedAt"] is NSNull }
        .count == 2
    }
    let text = try XCTUnwrap(
      saved.first {
        $0["kind"] as? String == "text_note" && !existingIDs.contains($0["id"] as? Int ?? -1)
      })
    let textID = try XCTUnwrap(text["id"] as? Int)
    let handwriting = try XCTUnwrap(
      saved.first {
        $0["kind"] as? String == "handwriting" && !existingIDs.contains($0["id"] as? Int ?? -1)
      })
    XCTAssertEqual(text["note"] as? String, "Converted English passage fixture")
    XCTAssertEqual(text["cfi"] as? String, handwriting["cfi"] as? String)
    let handwritingID = try XCTUnwrap(handwriting["id"] as? Int)
    let anchor = try XCTUnwrap(handwriting["cfi"] as? String)
    let drawing = try XCTUnwrap(handwriting["drawing"] as? [String: Any])
    XCTAssertEqual((drawing["strokes"] as? [[String: Any]])?.count, 1)
    XCTAssertFalse((drawing["nativeData"] as? String ?? "").isEmpty)
    XCUIDevice.shared.orientation = .landscapeLeft
    XCTAssertTrue(
      app.buttons["epubPassageNotes"].wait(for: \.isHittable, toEqual: true, timeout: 10))
    for identifier in ["epubReaderTools", "epubSettings"] {
      let matches = app.descendants(matching: .any).matching(identifier: identifier)
      guard matches.element.waitForExistence(timeout: 5), matches.count == 1,
        matches.element.wait(for: \.isHittable, toEqual: true, timeout: 5)
      else {
        XCTFail("Expected one hittable reader menu control: \(identifier).")
        return
      }
      matches.element.tap()
    }
    XCTAssertTrue(app.navigationBars["Reader settings"].waitForExistence(timeout: 5))
    let fontSizes = app.steppers.matching(identifier: "epubFontSize")
    let increments = fontSizes.element.buttons.matching(identifier: "epubFontSize-Increment")
    guard fontSizes.element.waitForExistence(timeout: 5), fontSizes.count == 1,
      increments.element.waitForExistence(timeout: 5), increments.count == 1,
      increments.element.wait(for: \.isHittable, toEqual: true, timeout: 5)
    else {
      attach(
        Data(app.debugDescription.utf8), name: "IPAD-E02-A01-font-size-controls-hierarchy",
        type: "public.plain-text")
      XCTFail("Expected one hittable native font size increment control.")
      return
    }
    XCTAssertEqual(fontSizes.element.value as? String, "16")
    let increment = increments.element
    increment.tap()
    let increasedFontSize = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "17"), object: fontSizes.element)
    XCTAssertEqual(XCTWaiter.wait(for: [increasedFontSize], timeout: 5), .completed)
    let saveSettings = app.buttons["epubSaveSettings"]
    XCTAssertTrue(saveSettings.wait(for: \.isHittable, toEqual: true, timeout: 5))
    saveSettings.tap()
    XCTAssertTrue(
      app.navigationBars["Reader settings"].wait(for: \.exists, toEqual: false, timeout: 10))
    reopenPassage(handwritingID, app: app)
    XCTAssertTrue(app.staticTexts["1 retained strokes"].waitForExistence(timeout: 10))
    let passageCanvases = app.scrollViews.matching(identifier: "passageInkCanvas")
    guard passageCanvases.element.waitForExistence(timeout: 5), passageCanvases.count == 1,
      passageCanvases.element.wait(for: \.isHittable, toEqual: true, timeout: 5)
    else {
      XCTFail("Expected one hittable retained passage handwriting canvas after reflow.")
      return
    }
    XCTAssertEqual(passageCanvases.element.value as? String, "1 retained strokes")
    capture("IPAD-E02-A01-handwriting-reopened-landscape-after-reflow")
    app.buttons["passageFixtureStroke"].tap()
    XCTAssertTrue(app.staticTexts["2 retained strokes"].waitForExistence(timeout: 5))
    XCTAssertEqual(passageCanvases.element.value as? String, "2 retained strokes")
    app.buttons["passageSave"].tap()
    let edited = try await waitForAnnotations(bookID: 2, token: token) { items in
      guard let item = items.first(where: { $0["id"] as? Int == handwritingID }),
        let drawing = item["drawing"] as? [String: Any]
      else { return false }
      return (drawing["strokes"] as? [[String: Any]])?.count == 2
    }
    let editedItem = try XCTUnwrap(edited.first { $0["id"] as? Int == handwritingID })
    XCTAssertEqual(editedItem["cfi"] as? String, anchor)
    XCTAssertGreaterThan(editedItem["version"] as? Int ?? 0, handwriting["version"] as? Int ?? 0)
    XCUIDevice.shared.orientation = .portrait
    reopenPassage(handwritingID, app: app)
    XCTAssertTrue(app.staticTexts["2 retained strokes"].waitForExistence(timeout: 5))
    XCTAssertEqual(passageCanvases.count, 1)
    XCTAssertTrue(passageCanvases.element.wait(for: \.isHittable, toEqual: true, timeout: 5))
    XCTAssertEqual(passageCanvases.element.value as? String, "2 retained strokes")
    capture("IPAD-E02-A01-edited-handwriting-portrait-popover")
    try audit(app, state: "IPAD-E02-A01-handwriting-popover")
    app.buttons["passageCancel"].tap()
    let mode = app.buttons["pencilWritingMode"]
    XCTAssertEqual(mode.value as? String, "Writing")
    XCTAssertFalse(app.buttons["epubNextPage"].isEnabled)
    XCTAssertFalse(app.buttons["epubPreviousPage"].isEnabled)
    let writingPosition = app.staticTexts["epubReadingPosition"].label
    mode.tap()
    XCTAssertEqual(mode.value as? String, "Navigation")
    XCTAssertTrue(app.buttons["epubNextPage"].isEnabled)
    XCTAssertEqual(app.staticTexts["epubReadingPosition"].label, writingPosition)
    capture("IPAD-E02-A01-writing-to-navigation")
    app.buttons["epubCloseReader"].tap()
    app.buttons["Done"].tap()
    app.buttons["openAnnotationHub"].tap()
    let searchFields = app.textFields.matching(identifier: "annotationHubSearch")
    let search = searchFields.element
    XCTAssertTrue(search.waitForExistence(timeout: 15))
    XCTAssertEqual(searchFields.count, 1)
    XCTAssertTrue(search.wait(for: \.isHittable, toEqual: true, timeout: 5))
    replaceText(search, with: "Converted English passage fixture\n")
    XCTAssertTrue(app.buttons["annotationHubItem\(textID)"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["annotationHubItem\(handwritingID)"].exists)
    capture("IPAD-E02-A01-converted-text-search-without-raw-ink")
    let strokes = try XCTUnwrap(drawing["strokes"] as? [[String: Any]])
    let rawInkIdentity = try XCTUnwrap(strokes.first?["id"] as? String)
    replaceText(search, with: "\(rawInkIdentity)\n")
    XCTAssertTrue(app.staticTexts["annotationHubEmpty"].waitForExistence(timeout: 10))
    capture("IPAD-E02-A01-raw-ink-identity-is-not-searchable")
  }

  @MainActor
  func testIPADE02A02TwoInkGroupsPublishToDeliveredPDF() async throws {
    let token = try await loginAPI()
    let originalBytes = try await api("books/files/1/serve", token: token)
    let original = try XCTUnwrap(PDFDocument(data: originalBytes))
    let before = try await annotations(bookID: 1, token: token)
    let existingIDs = Set(before.compactMap { $0["id"] as? Int })
    let app = launchAndSignIn()
    openBook("Orbit fixture", fileID: 1, app: app)
    XCTAssertTrue(app.staticTexts["Page 1 of 3"].waitForExistence(timeout: 15))
    let draw = app.buttons["pdfInkDraw"]
    XCTAssertTrue(draw.wait(for: \.isHittable, toEqual: true, timeout: 10))
    draw.tap()
    let groups = app.images.matching(NSPredicate(format: "identifier BEGINSWITH %@", "pdfInkItem"))
    let originalGroupCount = groups.count
    tapInkControl("pdfInkFixtureStroke", app: app)
    XCTAssertTrue(groups.element(boundBy: originalGroupCount).waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["Ink synchronized"].waitForExistence(timeout: 20))
    capture("IPAD-E02-A02-first-retained-ink-group")
    tapInkControl("pdfInkFixtureStroke", app: app)
    XCTAssertTrue(groups.element(boundBy: originalGroupCount + 1).waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["Ink synchronized"].waitForExistence(timeout: 20))
    XCTAssertEqual(groups.count, originalGroupCount + 2)
    capture("IPAD-E02-A02-two-separately-editable-ink-groups")
    let saved = try await waitForAnnotations(bookID: 1, token: token) { items in
      items.filter { item in
        item["kind"] as? String == "pdf_ink" && item["deletedAt"] is NSNull
          && !existingIDs.contains(item["id"] as? Int ?? -1)
      }.count == 2
    }
    let added = saved.filter { !existingIDs.contains($0["id"] as? Int ?? -1) }
    XCTAssertEqual(Set(added.compactMap { $0["clientId"] as? String }).count, 2)
    for item in added {
      XCTAssertEqual(item["kind"] as? String, "pdf_ink")
      XCTAssertGreaterThan(item["version"] as? Int ?? 0, 0)
      XCTAssertFalse((item["sourceRevision"] as? String ?? "").isEmpty)
      let drawing = try XCTUnwrap(item["drawing"] as? [String: Any])
      XCTAssertEqual(drawing["format"] as? String, "bookorbit-ink-v1")
      XCTAssertFalse((drawing["nativeData"] as? String ?? "").isEmpty)
      XCTAssertEqual((drawing["strokes"] as? [[String: Any]])?.count, 1)
    }
    let deliveredBytes = try await api("books/files/1/serve", token: token)
    attach(deliveredBytes, name: "IPAD-E02-A02-published-source", type: "com.adobe.pdf")
    let delivered = try XCTUnwrap(PDFDocument(data: deliveredBytes))
    XCTAssertEqual(delivered.pageCount, 3)
    for index in 0..<3 {
      let page = try XCTUnwrap(delivered.page(at: index))
      let originalPage = try XCTUnwrap(original.page(at: index))
      XCTAssertEqual(page.bounds(for: .mediaBox), CGRect(x: 0, y: 0, width: 600, height: 800))
      XCTAssertEqual(page.string, originalPage.string)
      let image = page.thumbnail(of: CGSize(width: 600, height: 800), for: .mediaBox)
      let originalImage = originalPage.thumbnail(
        of: CGSize(width: 600, height: 800), for: .mediaBox)
      if index == 0 {
        XCTAssertNotEqual(image.pngData(), originalImage.pngData())
        XCTAssertEqual(
          page.annotations.filter { $0.type == "Ink" }.count,
          originalPage.annotations.filter { $0.type == "Ink" }.count + 2)
      } else {
        XCTAssertEqual(image.pngData(), originalImage.pngData())
      }
      let imageAttachment = XCTAttachment(image: image)
      imageAttachment.name = "IPAD-E02-A02-independent-PDFKit-render-page-\(index + 1)"
      imageAttachment.lifetime = .keepAlways
      add(imageAttachment)
    }
  }

  @MainActor
  func testIPADE02A04SelectedPDFPauseResumeAndOfflineRestart() async throws {
    try await fault("reset")
    let app = launchAndSignIn(serverURL: Self.faultServerURL)
    openBookDetail("Orbit fixture", bookID: 1, app: app)
    guard E02ProfileSupport.openOfflineResources(app: app) else { return }
    let choice = app.buttons["offlineSelectFile1"]
    XCTAssertTrue(choice.waitForExistence(timeout: 10))
    XCTAssertEqual(choice.value as? String, "Not selected")
    XCTAssertFalse(app.buttons["offlineDownload"].isEnabled)
    choice.tap()
    XCTAssertEqual(choice.value as? String, "Selected")
    try await fault("transfer-arm?path=%2Fapi%2Fv1%2Fbooks%2Ffiles%2F1%2Fserve")
    app.buttons["offlineDownload"].tap()
    try await fault("held", method: "GET", expectedStatus: 200)
    XCTAssertTrue(app.buttons["offlinePause"].wait(for: \.isHittable, toEqual: true, timeout: 10))
    XCTAssertFalse(app.staticTexts["Verified ready for offline reading"].exists)
    XCTAssertNotEqual(app.staticTexts["offlineBytes"].label, "No content selected")
    capture("IPAD-E02-A04-real-transfer-first-byte")
    app.buttons["offlinePause"].tap()
    let resume = app.buttons["offlineResume"]
    XCTAssertTrue(resume.waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["offlineStatus"].label.hasPrefix("Paused."))
    capture("IPAD-E02-A04-paused-resumable-transfer")
    try await fault("reset")
    resume.tap()
    XCTAssertTrue(
      app.staticTexts["Verified ready for offline reading"].waitForExistence(timeout: 40))
    XCTAssertFalse(app.buttons["offlinePause"].exists)
    capture("IPAD-E02-A04-verified-selected-PDF-ready")
    try audit(app, state: "IPAD-E02-A04-verified-offline-resources")
    guard E02ProfileSupport.closeOfflineResources(app: app) else { return }
    app.buttons["Done"].tap()
    try await fault("offline")
    app.terminate()
    app.launch()
    let offline = app.buttons["offlineLibrary"]
    XCTAssertTrue(offline.wait(for: \.isHittable, toEqual: true, timeout: 25))
    offline.tap()
    let book = app.buttons["offlineBook1"]
    XCTAssertTrue(book.waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Verified ready for offline reading"].exists)
    capture("IPAD-E02-A04-offline-library-after-restart")
    book.tap()
    let read = app.buttons["readFile1"]
    XCTAssertTrue(read.wait(for: \.isHittable, toEqual: true, timeout: 10))
    read.tap()
    XCTAssertTrue(app.staticTexts["Page 1 of 3"].waitForExistence(timeout: 15))
    XCTAssertTrue(
      app.staticTexts.matching(
        NSPredicate(
          format: "label CONTAINS %@",
          "Orbit fixture: passage 1")
      ).firstMatch.isHittable)
    capture("IPAD-E02-A04-actual-PDF-readable-without-transport")
    let groups = app.images.matching(NSPredicate(format: "identifier BEGINSWITH %@", "pdfInkItem"))
    let existingIdentities = Set(groups.allElementsBoundByIndex.map(\.identifier))
    app.buttons["pdfInkDraw"].tap()
    tapInkControl("pdfInkFixtureStroke", app: app)
    XCTAssertTrue(app.staticTexts["Ink saved locally"].waitForExistence(timeout: 10))
    let pending = try XCTUnwrap(
      groups.allElementsBoundByIndex.first {
        !existingIdentities.contains($0.identifier)
      })
    let pendingIdentity = pending.identifier
    capture("IPAD-E02-A04-pending-ink-without-transport")
    app.terminate()
    app.launch()
    XCTAssertTrue(offline.waitForExistence(timeout: 25))
    offline.tap()
    XCTAssertTrue(book.waitForExistence(timeout: 10))
    book.tap()
    XCTAssertTrue(read.waitForExistence(timeout: 10))
    read.tap()
    XCTAssertTrue(app.staticTexts["Page 1 of 3"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.images[pendingIdentity].waitForExistence(timeout: 10))
    capture("IPAD-E02-A04-pending-ink-survives-second-restart")
    try await fault("online")
  }

  @MainActor
  func testIPADE02A03MoveResizeCopyDeleteAndPublishedUndoPreserveInkIdentity() async throws {
    let token = try await loginAPI()
    let before = try await annotations(bookID: 1, token: token)
    let existingIDs = Set(before.compactMap { $0["id"] as? Int })
    let app = launchAndSignIn()
    openBook("Orbit fixture", fileID: 1, app: app)
    tapInkControl("pdfInkFixtureStroke", app: app)
    let created = try await waitForAnnotations(bookID: 1, token: token) { items in
      items.contains { !existingIDs.contains($0["id"] as? Int ?? -1) && $0["deletedAt"] is NSNull }
    }
    let item = try XCTUnwrap(created.first { !existingIDs.contains($0["id"] as? Int ?? -1) })
    let id = try XCTUnwrap(item["id"] as? Int)
    let clientID = try XCTUnwrap(item["clientId"] as? String)
    let originalRect = try inkRect(item)
    let originalStrokes = try inkStrokeIDs(item)
    tapInkControl("pdfInkSelect", app: app)
    app.buttons["pdfInkSelectItem\(clientID)"].tap()
    capture("IPAD-E02-A03-selected-source-ink")
    tapInkControl("pdfInkMoveRight", app: app)
    let moved = try await waitForAnnotations(bookID: 1, token: token) { items in
      guard let value = items.first(where: { $0["id"] as? Int == id }),
        let rect = try? self.inkRect(value)
      else { return false }
      return rect.minX > originalRect.minX
    }
    let movedItem = try XCTUnwrap(moved.first { $0["id"] as? Int == id })
    let movedRect = try inkRect(movedItem)
    XCTAssertEqual(try inkStrokeIDs(movedItem), originalStrokes)
    XCTAssertEqual(movedRect.width, originalRect.width, accuracy: 0.01)
    tapInkControl("pdfInkGrow", app: app)
    let resized = try await waitForAnnotations(bookID: 1, token: token) { items in
      guard let value = items.first(where: { $0["id"] as? Int == id }),
        let rect = try? self.inkRect(value)
      else { return false }
      return rect.width > movedRect.width && rect.height > movedRect.height
    }
    let resizedItem = try XCTUnwrap(resized.first { $0["id"] as? Int == id })
    XCTAssertEqual(try inkStrokeIDs(resizedItem), originalStrokes)
    capture("IPAD-E02-A03-moved-and-resized-source-ink")
    tapInkControl("pdfInkCopy", app: app)
    XCTAssertTrue(app.staticTexts["Ink copied"].waitForExistence(timeout: 5))
    tapInkControl("pdfInkPaste", app: app)
    let copied = try await waitForAnnotations(bookID: 1, token: token) { items in
      items.filter { !existingIDs.contains($0["id"] as? Int ?? -1) && $0["deletedAt"] is NSNull }
        .count == 2
    }
    let copy = try XCTUnwrap(
      copied.first { !existingIDs.contains($0["id"] as? Int ?? -1) && $0["id"] as? Int != id })
    let copyID = try XCTUnwrap(copy["id"] as? Int)
    XCTAssertNotEqual(copy["clientId"] as? String, clientID)
    XCTAssertEqual(try inkStrokeIDs(copy).count, originalStrokes.count)
    capture("IPAD-E02-A03-pasted-distinct-ink-group")
    tapInkControl("pdfInkDelete", app: app)
    let deleted = try await waitForAnnotations(bookID: 1, token: token) { items in
      items.contains { $0["id"] as? Int == copyID && $0["deletedAt"] is String }
    }
    let tombstone = try XCTUnwrap(deleted.first { $0["id"] as? Int == copyID })
    XCTAssertTrue(deleted.contains { $0["id"] as? Int == id && $0["deletedAt"] is NSNull })
    capture("IPAD-E02-A03-published-ink-deletion")
    tapInkControl("pdfInkUndo", app: app)
    let restored = try await waitForAnnotations(bookID: 1, token: token) { items in
      items.contains {
        $0["id"] as? Int == copyID && $0["deletedAt"] is NSNull
          && ($0["version"] as? Int ?? 0) > (tombstone["version"] as? Int ?? 0)
      }
    }
    let inverse = try XCTUnwrap(restored.first { $0["id"] as? Int == copyID })
    XCTAssertEqual(inverse["clientId"] as? String, copy["clientId"] as? String)
    XCTAssertEqual(try inkRect(inverse), try inkRect(copy))
    XCTAssertEqual(
      try inkRect(try XCTUnwrap(restored.first { $0["id"] as? Int == id })),
      try inkRect(resizedItem))
    capture("IPAD-E02-A03-published-versioned-undo")
  }

  @MainActor
  func testIPADE02A05AuthoritativeDeletionPreservesOfflineEditAsRecoveryDraft() async throws {
    try await fault("reset")
    let token = try await loginAPI()
    let initial = try await annotations(bookID: 1, token: token)
    let existingIDs = Set(initial.compactMap { $0["id"] as? Int })
    let app = launchAndSignIn(serverURL: Self.faultServerURL)
    openBook("Orbit fixture", fileID: 1, app: app)
    tapInkControl("pdfInkFixtureStroke", app: app)
    let created = try await waitForAnnotations(bookID: 1, token: token) { items in
      items.contains {
        !existingIDs.contains($0["id"] as? Int ?? -1) && $0["kind"] as? String == "pdf_ink"
      }
    }
    let item = try XCTUnwrap(created.first { !existingIDs.contains($0["id"] as? Int ?? -1) })
    let id = try XCTUnwrap(item["id"] as? Int)
    let clientID = try XCTUnwrap(item["clientId"] as? String)
    try await fault("offline")
    tapInkControl("pdfInkSelect", app: app)
    app.buttons["pdfInkSelectItem\(clientID)"].tap()
    tapInkControl("pdfInkMoveRight", app: app)
    XCTAssertTrue(app.staticTexts["Ink saved locally"].waitForExistence(timeout: 10))
    capture("IPAD-E02-A05-native-stale-offline-ink-edit")
    let concurrentBrowser = ProcessInfo.processInfo.environment["IPAD_E02_CONCURRENT_NATIVE"] == "1"
    if concurrentBrowser {
      try await checkpoint("native-offline-ready", reach: true)
      try await checkpoint("browser-delete-done")
    } else {
      let body: [String: Any] = [
        "deviceId": "Annotation UI concurrent public client",
        "operations": [
          [
            "operationId": UUID().uuidString, "clientId": clientID, "annotationId": id,
            "bookId": 1, "baseVersion": try XCTUnwrap(item["version"] as? Int), "action": "delete",
          ]
        ],
      ]
      let result = try await api(
        "annotations/native/operations", method: "POST", token: token, body: body)
      attach(result, name: "IPAD-E02-A05-direct-public-client-delete", type: "public.json")
    }
    let deleted = try await waitForAnnotations(bookID: 1, token: token) { items in
      items.contains { $0["id"] as? Int == id && $0["deletedAt"] is String }
    }
    let tombstone = try XCTUnwrap(deleted.first { $0["id"] as? Int == id })
    let committedBytes = try await api("books/files/1/serve", token: token)
    try await fault("online")
    XCUIDevice.shared.press(.home)
    app.activate()
    XCTAssertTrue(app.buttons["Close reader"].waitForExistence(timeout: 20))
    app.buttons["Close reader"].tap()
    app.buttons["Done"].tap()
    app.buttons["openAnnotationHub"].tap()
    let searchFields = app.textFields.matching(identifier: "annotationHubSearch")
    XCTAssertTrue(searchFields.element.waitForExistence(timeout: 15))
    XCTAssertEqual(searchFields.count, 1)
    tapHubControl("annotationHubSynchronize", app: app)
    tapHubControl("annotationHubRecovery", app: app)
    XCTAssertTrue(
      app.staticTexts["The annotation was deleted in another reader"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["Original drawing retained"].exists)
    capture("IPAD-E02-A05-authoritative-deletion-recovery-draft")
    try audit(app, state: "IPAD-E02-A05-recovery-draft")
    app.terminate()
    app.launch()
    XCTAssertTrue(app.buttons["openAnnotationHub"].waitForExistence(timeout: 25))
    app.buttons["openAnnotationHub"].tap()
    XCTAssertTrue(searchFields.element.waitForExistence(timeout: 15))
    XCTAssertEqual(searchFields.count, 1)
    tapHubControl("annotationHubRecovery", app: app)
    XCTAssertTrue(
      app.staticTexts["The annotation was deleted in another reader"].waitForExistence(timeout: 15))
    capture("IPAD-E02-A05-recovery-survives-restart")
    let converged = try await annotations(bookID: 1, token: token)
    let final = try XCTUnwrap(converged.first { $0["id"] as? Int == id })
    XCTAssertEqual(final["deletedAt"] as? String, tombstone["deletedAt"] as? String)
    XCTAssertEqual(final["version"] as? Int, tombstone["version"] as? Int)
    let finalBytes = try await api("books/files/1/serve", token: token)
    XCTAssertEqual(finalBytes, committedBytes)
    if concurrentBrowser { try await checkpoint("native-reconciled", reach: true) }
  }

  @MainActor
  func testIPADE02A06DeletedSourceKeepsProtectedCompleteVersionForExport() async throws {
    try await fault("reset")
    let token = try await loginAPI()
    let detailBytes = try await api("books/6", token: token)
    let detail = try XCTUnwrap(JSONSerialization.jsonObject(with: detailBytes) as? [String: Any])
    let files = try XCTUnwrap(detail["files"] as? [[String: Any]])
    let pdf = try XCTUnwrap(files.first { ($0["format"] as? String)?.lowercased() == "pdf" })
    let fileID = try XCTUnwrap(pdf["id"] as? Int)
    let originalBytes = try await api("books/files/\(fileID)/serve", token: token)
    let original = try XCTUnwrap(PDFDocument(data: originalBytes))
    XCTAssertGreaterThan(original.pageCount, 0)
    let originalRevision = SHA256.hash(data: originalBytes).map { String(format: "%02x", $0) }
      .joined()
    let app = launchAndSignIn(serverURL: Self.faultServerURL)
    openBookDetail(try XCTUnwrap(detail["title"] as? String), bookID: 6, app: app)
    guard E02ProfileSupport.openOfflineResources(app: app) else { return }
    let selection = app.buttons["offlineSelectFile\(fileID)"]
    XCTAssertTrue(selection.waitForExistence(timeout: 10))
    XCTAssertEqual(selection.value as? String, "Not selected")
    selection.tap()
    app.buttons["offlineDownload"].tap()
    XCTAssertTrue(
      app.staticTexts["Verified ready for offline reading"].waitForExistence(timeout: 40))
    guard E02ProfileSupport.closeOfflineResources(app: app) else { return }
    app.buttons["readFile\(fileID)"].tap()
    XCTAssertTrue(app.buttons["pdfInkDraw"].waitForExistence(timeout: 15))
    try await fault("offline")
    tapInkControl("pdfInkFixtureStroke", app: app)
    XCTAssertTrue(app.staticTexts["Ink saved locally"].waitForExistence(timeout: 10))
    capture("IPAD-E02-A06-pending-ink-before-source-deletion")
    _ = try await api("books/files/\(fileID)", method: "DELETE", token: token)
    try await fault("online")
    app.terminate()
    app.launch()
    XCTAssertTrue(app.buttons["offlineLibrary"].wait(for: \.isHittable, toEqual: true, timeout: 25))
    app.buttons["offlineLibrary"].tap()
    let recovery = app.buttons["offlineSourceRecovery"]
    XCTAssertTrue(recovery.wait(for: \.isHittable, toEqual: true, timeout: 10))
    recovery.tap()
    XCTAssertTrue(app.staticTexts["Source deleted"].waitForExistence(timeout: 20))
    XCTAssertTrue(app.staticTexts["Book 6, file \(fileID), PDF"].exists)
    XCTAssertTrue(app.staticTexts["Revision \(originalRevision)"].exists)
    let versions = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "sourceRecoveryVersion"))
    XCTAssertLessThanOrEqual(versions.count, 40)
    let protection = app.staticTexts.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "sourceRecoveryProtected")
    ).firstMatch
    let remove = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "sourceRecoveryRemove")
    ).firstMatch
    XCTAssertTrue(remove.waitForExistence(timeout: 10))
    remove.tap()
    XCTAssertTrue(app.staticTexts["sourceRecoveryError"].waitForExistence(timeout: 10))
    XCTAssertTrue(protection.exists)
    XCTAssertFalse(remove.isEnabled)
    capture("IPAD-E02-A06-deleted-source-protected-complete-version")
    let prepare = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "sourceRecoveryPrepareExport")
    ).firstMatch
    XCTAssertTrue(prepare.wait(for: \.isHittable, toEqual: true, timeout: 10))
    prepare.tap()
    let ready = app.staticTexts["sourceRecoveryExportReady"]
    XCTAssertTrue(ready.waitForExistence(timeout: 10))
    XCTAssertTrue(ready.label.hasPrefix("Verified complete export: "))
    capture("IPAD-E02-A06-verified-complete-source-export-ready")
    let export = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "sourceRecoveryExport")
    ).firstMatch
    export.tap()
    let saveToFiles = app.buttons["Save to Files"]
    XCTAssertTrue(saveToFiles.wait(for: \.isHittable, toEqual: true, timeout: 10))
    saveToFiles.tap()
    let directory = try XCTUnwrap(
      ProcessInfo.processInfo.environment["IPAD_E02_EXPORTED_ARTIFACT_DIRECTORY"],
      "Supply the installed app's public Documents directory for the native PDF export.")
    let documents = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
    XCTAssertTrue(directory.hasPrefix("/"))
    XCTAssertEqual(documents.lastPathComponent, "Documents")
    XCTAssertEqual(documents.resolvingSymlinksInPath().path, documents.path)
    let directoryValues = try documents.resourceValues(forKeys: [
      .isDirectoryKey, .isSymbolicLinkKey,
    ])
    XCTAssertEqual(directoryValues.isDirectory, true)
    XCTAssertEqual(directoryValues.isSymbolicLink, false)
    let filename = "Deleted source A06-\(UUID().uuidString).pdf"
    let exportURL = documents.appendingPathComponent(filename)
    XCTAssertFalse(FileManager.default.fileExists(atPath: exportURL.path))
    let originalFilename = String(ready.label.dropFirst("Verified complete export: ".count))
    saveA06PDFToPublicDocuments(filename: filename, originalFilename: originalFilename, app: app)
    let deadline = Date().addingTimeInterval(15)
    while !FileManager.default.fileExists(atPath: exportURL.path) && Date() < deadline {
      try await Task.sleep(for: .milliseconds(250))
    }
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: exportURL.path), "Read the actual native Files PDF")
    let values = try exportURL.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    XCTAssertEqual(values.isRegularFile, true)
    XCTAssertEqual(values.isSymbolicLink, false)
    XCTAssertEqual(
      exportURL.resolvingSymlinksInPath().deletingLastPathComponent().path, documents.path)
    let size = try XCTUnwrap(values.fileSize)
    XCTAssertGreaterThan(size, 0)
    XCTAssertLessThanOrEqual(size, 16 * 1024 * 1024)
    let savedBytes = try Data(contentsOf: exportURL)
    XCTAssertEqual(savedBytes.count, size)
    XCTAssertEqual(savedBytes, originalBytes)
    let savedRevision = SHA256.hash(data: savedBytes).map { String(format: "%02x", $0) }.joined()
    XCTAssertEqual(savedRevision, originalRevision)
    let savedPDF = try XCTUnwrap(PDFDocument(data: savedBytes))
    XCTAssertEqual(savedPDF.pageCount, original.pageCount)
    var pageFacts: [[String: Any]] = []
    for index in 0..<original.pageCount {
      let originalPage = try XCTUnwrap(original.page(at: index))
      let savedPage = try XCTUnwrap(savedPDF.page(at: index))
      XCTAssertEqual(savedPage.rotation, originalPage.rotation)
      var boxes: [[String: Any]] = []
      for box in [PDFDisplayBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] {
        let bounds = savedPage.bounds(for: box)
        XCTAssertEqual(bounds, originalPage.bounds(for: box))
        boxes.append([
          "box": box.rawValue, "x": bounds.minX, "y": bounds.minY, "width": bounds.width,
          "height": bounds.height,
        ])
      }
      pageFacts.append(["page": index, "rotation": savedPage.rotation, "boxes": boxes])
    }
    attach(
      savedBytes, name: "IPAD-E02-A06-actual-native-Files-complete-source", type: "com.adobe.pdf")
    attach(
      try JSONSerialization.data(
        withJSONObject: [
          "filename": filename, "sha256": savedRevision, "bytes": size,
          "pageCount": savedPDF.pageCount, "pages": pageFacts,
        ], options: [.sortedKeys]),
      name: "IPAD-E02-A06-actual-native-Files-PDF-hash-and-geometry", type: "public.json")
    XCTAssertTrue(app.staticTexts["Source deleted"].waitForExistence(timeout: 10))
    app.terminate()
    app.launch()
    XCTAssertTrue(app.buttons["offlineLibrary"].waitForExistence(timeout: 25))
    app.buttons["offlineLibrary"].tap()
    XCTAssertTrue(recovery.waitForExistence(timeout: 10))
    recovery.tap()
    XCTAssertTrue(app.staticTexts["Revision \(originalRevision)"].waitForExistence(timeout: 15))
    remove.tap()
    XCTAssertTrue(app.staticTexts["sourceRecoveryError"].waitForExistence(timeout: 10))
    XCTAssertTrue(protection.exists)
    XCTAssertFalse(remove.isEnabled)
    capture("IPAD-E02-A06-source-and-pending-protection-survive-restart")
  }

  @MainActor
  func testIPADE02A07HubDeepLinkExportTrashRestoreAndExplicitRepair() async throws {
    let marker = "A07-\(UUID().uuidString)"
    let token = try await loginAPI()
    let initial = try await annotations(bookID: 2, token: token)
    let existingIDs = Set(initial.compactMap { $0["id"] as? Int })
    let originalItems = try JSONSerialization.data(withJSONObject: initial, options: [.sortedKeys])
    let app = launchAndSignIn()
    openBook("Native renderer proof", fileID: 2, app: app)
    selectA07Chapter(second: true, app: app)
    let tools = app.descendants(matching: .any).matching(identifier: "epubReaderTools")
    XCTAssertTrue(tools.element.wait(for: \.isEnabled, toEqual: true, timeout: 20))
    XCTAssertEqual(tools.count, 1)
    XCTAssertTrue(tools.element.wait(for: \.isHittable, toEqual: true, timeout: 10))
    let selection = app.buttons["epubFixtureSelectPassage"]
    XCTAssertTrue(selection.wait(for: \.isHittable, toEqual: true, timeout: 20))
    selection.tap()
    XCTAssertFalse(app.buttons["passageCancel"].exists, "A07 must select an unowned passage")
    openSelectedPassagePreview(app)
    XCTAssertTrue(app.staticTexts["passageSelectionPreview"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.staticTexts["passageSelectionPreview"].label, "Second chapter begins here.")
    app.buttons["Handwriting"].tap()
    app.buttons["passageFixtureStroke"].tap()
    XCTAssertTrue(app.staticTexts["1 retained strokes"].waitForExistence(timeout: 5))
    app.buttons["passageSave"].tap()
    let saved = try await waitForAnnotations(bookID: 2, token: token) { items in
      items.contains {
        !existingIDs.contains($0["id"] as? Int ?? -1) && $0["kind"] as? String == "handwriting"
      }
    }
    let owned = saved.filter { !existingIDs.contains($0["id"] as? Int ?? -1) }
    XCTAssertEqual(owned.count, 1)
    let item = try XCTUnwrap(owned.first)
    let id = try XCTUnwrap(item["id"] as? Int)
    XCTAssertEqual(item["kind"] as? String, "handwriting")
    XCTAssertEqual(item["text"] as? String, "Second chapter begins here.")
    let originalDrawing = try XCTUnwrap(item["drawing"] as? [String: Any])
    try assertA07Preserved(initialIDs: existingIDs, original: originalItems, items: saved)
    attach(
      try JSONSerialization.data(
        withJSONObject: ["marker": marker, "canonicalID": id, "item": item], options: [.sortedKeys]),
      name: "IPAD-E02-A07-owned-native-note-cleanup-identity", type: "public.json")
    app.buttons["epubCloseReader"].tap()
    app.buttons["Done"].tap()
    app.buttons["openAnnotationHub"].tap()
    let searchFields = app.textFields.matching(identifier: "annotationHubSearch")
    let search = searchFields.element
    XCTAssertTrue(search.waitForExistence(timeout: 15))
    XCTAssertEqual(searchFields.count, 1)
    XCTAssertTrue(search.wait(for: \.isHittable, toEqual: true, timeout: 5))
    replaceText(search, with: "Second chapter begins here.\n")
    app.buttons["annotationHubFilters"].tap()
    chooseHubPicker("annotationHubKind", option: "Handwritten notes", app: app)
    chooseHubPicker("annotationHubGrouping", option: "Month", app: app)
    app.buttons["annotationHubApplyFilters"].tap()
    let row = app.buttons["annotationHubItem\(id)"]
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    XCTAssertLessThanOrEqual(
      app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "annotationHubItem"))
        .count, 40)
    capture("IPAD-E02-A07-search-kind-filter-month-group")
    row.tap()
    XCTAssertTrue(app.images["annotationHubRetainedDrawing"].waitForExistence(timeout: 10))
    capture("IPAD-E02-A07-hub-retained-drawing-detail")
    app.buttons["annotationHubOpenPassage"].tap()
    let openedPreview = app.staticTexts.matching(identifier: "passageSelectionPreview")
    XCTAssertTrue(openedPreview.element.wait(for: \.isHittable, toEqual: true, timeout: 20))
    XCTAssertEqual(openedPreview.count, 1)
    XCTAssertTrue(app.staticTexts["1 retained strokes"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.staticTexts["passageSelectionPreview"].label, "Second chapter begins here.")
    capture("IPAD-E02-A07-hub-deep-link-known-passage")
    app.buttons["passageCancel"].tap()
    app.buttons["epubCloseReader"].tap()
    let detailBars = app.navigationBars.matching(identifier: "Annotation")
    XCTAssertTrue(detailBars.element.waitForExistence(timeout: 10))
    XCTAssertEqual(detailBars.count, 1)
    let detailDone = detailBars.element.buttons.matching(NSPredicate(format: "label == %@", "Done"))
    XCTAssertEqual(detailDone.count, 1)
    XCTAssertTrue(detailDone.element.wait(for: \.isEnabled, toEqual: true, timeout: 15))
    XCTAssertTrue(detailDone.element.wait(for: \.isHittable, toEqual: true, timeout: 10))
    detailDone.element.tap()
    XCTAssertTrue(detailBars.element.wait(for: \.exists, toEqual: false, timeout: 10))
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    app.buttons["annotationHubSelect\(id)"].tap()
    XCTAssertEqual(app.staticTexts["annotationHubSelectedCount"].label, "1 selected")
    let directory = try XCTUnwrap(
      ProcessInfo.processInfo.environment["IPAD_E02_EXPORTED_ARTIFACT_DIRECTORY"],
      "Supply the installed app's public Documents directory from the native harness.")
    let documents = URL(fileURLWithPath: directory, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath()
    XCTAssertTrue(directory.hasPrefix("/"))
    XCTAssertEqual(documents.lastPathComponent, "Documents")
    let directoryValues = try documents.resourceValues(forKeys: [
      .isDirectoryKey, .isSymbolicLinkKey,
    ])
    XCTAssertEqual(directoryValues.isDirectory, true)
    XCTAssertEqual(directoryValues.isSymbolicLink, false)
    let filename = "BookOrbit annotations \(marker).json"
    let exportURL = documents.appendingPathComponent(filename)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: exportURL.path),
      "A07 requires a new native Files artifact")
    let beforeExport = try await annotations(bookID: 2, token: token)
    let expectedExport = try XCTUnwrap(beforeExport.first { $0["id"] as? Int == id })
    tapHubControl("annotationHubExport", app: app)
    saveA07ToPublicDocuments(filename: filename, app: app)
    XCTAssertTrue(
      app.staticTexts["Annotations exported with retained drawings and version details."]
        .waitForExistence(timeout: 15))
    let deadline = Date().addingTimeInterval(15)
    while !FileManager.default.fileExists(atPath: exportURL.path) && Date() < deadline {
      try await Task.sleep(for: .milliseconds(250))
    }
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: exportURL.path),
      "Inspect the actual native Files Save artifact")
    let exportedValues = try exportURL.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    XCTAssertEqual(exportedValues.isRegularFile, true)
    XCTAssertEqual(exportedValues.isSymbolicLink, false)
    XCTAssertEqual(
      exportURL.resolvingSymlinksInPath().deletingLastPathComponent().path, documents.path)
    let size = try XCTUnwrap(exportedValues.fileSize)
    XCTAssertGreaterThan(size, 0)
    XCTAssertLessThanOrEqual(size, 16 * 1024 * 1024)
    let exportedBytes = try Data(contentsOf: exportURL)
    XCTAssertEqual(exportedBytes.count, size)
    attach(
      exportedBytes, name: "IPAD-E02-A07-actual-native-Files-retained-drawing", type: "public.json")
    let hash = SHA256.hash(data: exportedBytes).map { String(format: "%02x", $0) }.joined()
    attach(
      try JSONSerialization.data(
        withJSONObject: ["filename": filename, "canonicalID": id, "sha256": hash, "bytes": size],
        options: [.sortedKeys]),
      name: "IPAD-E02-A07-native-Files-export-hash", type: "public.json")
    let exported = try XCTUnwrap(
      JSONSerialization.jsonObject(with: exportedBytes) as? [String: Any])
    XCTAssertEqual(exported["format"] as? String, "bookorbit-annotations-v1")
    let exportedItems = try XCTUnwrap(exported["items"] as? [[String: Any]])
    XCTAssertEqual(exportedItems.count, 1)
    let exportedItem = try XCTUnwrap(exportedItems.first)
    XCTAssertEqual(exportedItem["id"] as? Int, id)
    XCTAssertEqual(
      try XCTUnwrap(exportedItem["version"] as? Int),
      try XCTUnwrap(expectedExport["version"] as? Int))
    XCTAssertEqual(
      try XCTUnwrap(exportedItem["cfi"] as? String), try XCTUnwrap(expectedExport["cfi"] as? String)
    )
    XCTAssertEqual(
      try XCTUnwrap(exportedItem["jumpFileId"] as? Int),
      try XCTUnwrap(expectedExport["jumpFileId"] as? Int))
    XCTAssertEqual(exportedItem["text"] as? String, expectedExport["text"] as? String)
    XCTAssertEqual(exportedItem["kind"] as? String, "handwriting")
    let exportedDrawing = try XCTUnwrap(exportedItem["drawing"] as? [String: Any])
    let expectedDrawing = try XCTUnwrap(expectedExport["drawing"] as? [String: Any])
    XCTAssertEqual(exportedDrawing as NSDictionary, expectedDrawing as NSDictionary)
    XCTAssertEqual(exportedDrawing as NSDictionary, originalDrawing as NSDictionary)
    tapHubControl("annotationHubTrashSelected", app: app)
    app.buttons["Move to Trash"].tap()
    let trashed = try await waitForAnnotations(bookID: 2, token: token) { items in
      items.contains { $0["id"] as? Int == id && $0["deletedAt"] is String }
    }
    XCTAssertFalse(row.exists)
    capture("IPAD-E02-A07-bulk-trash-active-list")
    app.buttons["annotationHubFilters"].tap()
    chooseHubPicker("annotationHubStatus", option: "Trash", app: app)
    app.buttons["annotationHubApplyFilters"].tap()
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    capture("IPAD-E02-A07-trash-filter-retained-note")
    app.buttons["annotationHubSelect\(id)"].tap()
    tapHubControl("annotationHubRestoreSelected", app: app)
    let restored = try await waitForAnnotations(bookID: 2, token: token) { items in
      items.contains { $0["id"] as? Int == id && $0["deletedAt"] is NSNull }
    }
    let restoredItem = try XCTUnwrap(restored.first { $0["id"] as? Int == id })
    let restoredDrawing = try XCTUnwrap(restoredItem["drawing"] as? [String: Any])
    XCTAssertEqual(
      restoredDrawing["nativeData"] as? String, originalDrawing["nativeData"] as? String)
    XCTAssertGreaterThan(
      restoredItem["version"] as? Int ?? 0,
      try XCTUnwrap(trashed.first { $0["id"] as? Int == id })["version"] as? Int ?? 0)
    app.buttons["annotationHubFilters"].tap()
    chooseHubPicker("annotationHubStatus", option: "Annotations", app: app)
    app.buttons["annotationHubApplyFilters"].tap()
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.tap()
    app.buttons["annotationHubRepair"].tap()
    app.buttons["annotationHubRepairFile2"].tap()
    selectA07Chapter(second: false, app: app)
    let repairSelection = app.buttons["epubFixtureSelectPassage"]
    XCTAssertTrue(repairSelection.wait(for: \.isHittable, toEqual: true, timeout: 15))
    repairSelection.tap()
    let confirmation = app.buttons["passageRepairHere"]
    XCTAssertTrue(confirmation.wait(for: \.isHittable, toEqual: true, timeout: 10))
    let beforeRepair = try await annotations(bookID: 2, token: token)
    let unchanged = try XCTUnwrap(beforeRepair.first { $0["id"] as? Int == id })
    XCTAssertEqual(unchanged["version"] as? Int, restoredItem["version"] as? Int)
    XCTAssertEqual(unchanged["cfi"] as? String, item["cfi"] as? String)
    confirmation.tap()
    let repaired = try await waitForAnnotations(bookID: 2, token: token) { items in
      items.contains { $0["id"] as? Int == id && $0["positionStatus"] as? String == "repaired" }
    }
    let repairedItem = try XCTUnwrap(repaired.first { $0["id"] as? Int == id })
    XCTAssertNotEqual(repairedItem["cfi"] as? String, item["cfi"] as? String)
    XCTAssertTrue((repairedItem["text"] as? String ?? "").contains("Alpha"))
    XCTAssertGreaterThan(repairedItem["version"] as? Int ?? 0, restoredItem["version"] as? Int ?? 0)
    try assertA07Preserved(initialIDs: existingIDs, original: originalItems, items: repaired)
    let repairedDrawing = try XCTUnwrap(repairedItem["drawing"] as? [String: Any])
    XCTAssertEqual(
      repairedDrawing["nativeData"] as? String, originalDrawing["nativeData"] as? String)
    capture("IPAD-E02-A07-explicit-anchor-repair-preserves-drawing")
  }

  @MainActor
  private func saveA06PDFToPublicDocuments(
    filename: String, originalFilename: String, app: XCUIApplication
  ) {
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
    let originalBase = URL(fileURLWithPath: originalFilename).deletingPathExtension()
      .lastPathComponent
    XCTAssertFalse(originalBase.isEmpty)
    let fields = app.textFields.matching(NSPredicate(format: "value CONTAINS %@", originalBase))
    if !fields.element.exists {
      let filenameButton = app.buttons[originalFilename]
      XCTAssertTrue(filenameButton.wait(for: \.isHittable, toEqual: true, timeout: 5))
      filenameButton.tap()
    }
    XCTAssertTrue(fields.element.wait(for: \.isHittable, toEqual: true, timeout: 10))
    XCTAssertEqual(fields.count, 1, "Use the actual native PDF filename editor")
    replaceText(
      fields.element, with: URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
    )
    capture("IPAD-E02-A06-source-export-to-native-Files")
    XCTAssertTrue(save.isHittable)
    save.tap()
    XCTAssertTrue(save.wait(for: \.exists, toEqual: false, timeout: 15))
  }

  @MainActor
  private func saveA07ToPublicDocuments(filename: String, app: XCUIApplication) {
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
      NSPredicate(format: "value CONTAINS %@", "BookOrbit annotations"))
    XCTAssertEqual(fields.count, 1, "Expected the actual native export filename field")
    XCTAssertTrue(fields.element.wait(for: \.isHittable, toEqual: true, timeout: 10))
    let field = fields.element
    let originalName = field.value as? String ?? ""
    XCTAssertTrue(originalName.contains("BookOrbit annotations"))
    let exportName = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
    field.tap()
    field.typeText(
      String(repeating: XCUIKeyboardKey.delete.rawValue, count: originalName.utf16.count)
        + exportName)
    let renamedFields = app.textFields.matching(NSPredicate(format: "value == %@", exportName))
    XCTAssertEqual(renamedFields.count, 1, "Expected the uniquely renamed native export filename")
    XCTAssertEqual(renamedFields.element.value as? String, exportName)
    capture("IPAD-E02-A07-native-Files-export-destination")
    XCTAssertTrue(save.isHittable)
    save.tap()
    XCTAssertTrue(save.wait(for: \.exists, toEqual: false, timeout: 15))
  }

  @MainActor
  private func selectA07Chapter(second: Bool, app: XCUIApplication) {
    let tools = app.descendants(matching: .any).matching(identifier: "epubReaderTools")
    let previous = app.descendants(matching: .any).matching(identifier: "epubPreviousSection")
    let next = app.descendants(matching: .any).matching(identifier: "epubNextSection")
    let firstChapter = app.webViews.staticTexts.matching(
      NSPredicate(format: "label == %@", "First chapter ends here."))
    let secondChapter = app.webViews.staticTexts.matching(
      NSPredicate(format: "label == %@", "Second chapter begins here."))
    XCTAssertTrue(tools.element.wait(for: \.isHittable, toEqual: true, timeout: 20))
    XCTAssertEqual(tools.count, 1)
    XCTAssertTrue(tools.element.wait(for: \.isEnabled, toEqual: true, timeout: 20))
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
      XCTAssertTrue(tools.element.wait(for: \.isEnabled, toEqual: true, timeout: 20))
      tools.element.tap()
      XCTAssertTrue(previous.element.waitForExistence(timeout: 10))
      XCTAssertEqual(previous.count, 1)
    }
    XCTAssertFalse(previous.element.isEnabled, "The fixture has two chapters; begin from the first")
    if second {
      XCTAssertTrue(next.element.wait(for: \.isHittable, toEqual: true, timeout: 10))
      XCTAssertEqual(next.count, 1)
      XCTAssertTrue(next.element.isEnabled)
      next.element.tap()
      XCTAssertTrue(next.element.wait(for: \.isHittable, toEqual: false, timeout: 10))
      XCTAssertTrue(secondChapter.element.wait(for: \.isHittable, toEqual: true, timeout: 15))
      XCTAssertEqual(secondChapter.count, 1)
    } else {
      XCTAssertTrue(tools.element.isHittable, "Dismiss the native Reader tools menu visibly")
      tools.element.tap()
      XCTAssertTrue(previous.element.wait(for: \.isHittable, toEqual: false, timeout: 10))
      XCTAssertTrue(firstChapter.element.wait(for: \.isHittable, toEqual: true, timeout: 15))
      XCTAssertEqual(firstChapter.count, 1)
    }
    XCTAssertTrue(
      app.buttons["epubFixtureSelectPassage"].wait(for: \.isHittable, toEqual: true, timeout: 20))
  }

  @MainActor
  private func assertA07Preserved(initialIDs: Set<Int>, original: Data, items: [[String: Any]])
    throws
  {
    let retained = items.filter { initialIDs.contains($0["id"] as? Int ?? -1) }
    XCTAssertEqual(retained.count, initialIDs.count)
    XCTAssertEqual(
      try JSONSerialization.data(withJSONObject: retained, options: [.sortedKeys]), original)
  }

  @MainActor
  private func chooseHubPicker(_ id: String, option: String, app: XCUIApplication) {
    let picker = app.buttons[id]
    XCTAssertTrue(picker.wait(for: \.isHittable, toEqual: true, timeout: 5))
    picker.tap()
    app.buttons[option].tap()
  }

  @MainActor
  private func launchAndSignIn(serverURL: String? = nil) -> XCUIApplication {
    let profile = ProcessInfo.processInfo.environment["IPAD_E02_PROFILE"] ?? "pro13-portrait-light"
    XCUIDevice.shared.orientation = profile.contains("landscape") ? .landscapeLeft : .portrait
    let app = XCUIApplication()
    app.launchArguments = [
      "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "--annotation-input-driver",
      "-AppleInterfaceStyle", profile.contains("dark") ? "Dark" : "Light",
      "-UIPreferredContentSizeCategoryName",
      profile.contains("large")
        ? "UICTContentSizeCategoryXXXL" : "UICTContentSizeCategoryL",
    ]
    app.launchEnvironment["BOOKORBIT_ANNOTATION_INPUT_FIXTURE"] = "1"
    E02ProfileSupport.configure(app)
    app.launch()
    if !app.textFields["serverURL"].waitForExistence(timeout: 3) {
      for _ in 0..<5 where !app.buttons["signOut"].exists {
        if app.buttons["epubCloseReader"].exists {
          app.buttons["epubCloseReader"].tap()
        } else if app.buttons["Close reader"].exists {
          app.buttons["Close reader"].tap()
        } else if app.buttons["sourceRecoveryClose"].exists {
          app.buttons["sourceRecoveryClose"].tap()
        } else if app.buttons["annotationHubDone"].exists {
          app.buttons["annotationHubDone"].tap()
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
    replaceText(server, with: serverURL.map(Self.loopbackURL) ?? Self.fixtureServerURL)
    app.buttons["connectServer"].tap()
    let username = app.textFields["username"]
    guard
      E02ProfileSupport.ensureSignInForm(
        app: app, serverURL: serverURL.map(Self.loopbackURL) ?? Self.fixtureServerURL)
    else { return app }
    XCTAssertTrue(username.wait(for: \.isHittable, toEqual: true, timeout: 10))
    username.tap()
    username.typeText("ipad-owner")
    app.secureTextFields["password"].tap()
    app.secureTextFields["password"].typeText("IpadFixture123")
    app.buttons["signIn"].tap()
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 25))
    if ProcessInfo.processInfo.environment["IPAD_ANNOTATION_FORCE_UI_FAILURE"] == "1" {
      XCTAssertTrue(
        app.staticTexts["IPAD-E02-forced-teardown-failure"].exists,
        "Controlled UI assertion failure for bounded teardown verification")
    }
    return app
  }

  @MainActor
  private func openBook(_ title: String, fileID: Int, app: XCUIApplication) {
    openBookDetail(title, bookID: fileID, app: app)
    let hierarchy = app.debugDescription
    print("IPAD-E02 Book details hierarchy for file \(fileID):\n\(hierarchy)")
    attach(
      Data(hierarchy.utf8), name: "IPAD-E02-book-details-file-\(fileID)-hierarchy",
      type: "public.plain-text")
    let contents = app.descendants(matching: .any).matching(identifier: "bookDetailContent")
    guard contents.firstMatch.waitForExistence(timeout: 10), contents.count == 1 else {
      XCTFail("Expected one named Book details content container to find file \(fileID).")
      return
    }
    let content = contents.element
    guard content.wait(for: \.isHittable, toEqual: true, timeout: 10) else {
      XCTFail("Book details content is not visible for file \(fileID).")
      return
    }
    let matches = content.buttons.matching(identifier: "readFile\(fileID)")
    let read = matches.element
    for scroll in 0..<12 {
      guard matches.count <= 1 else {
        XCTFail("Expected one Read action for file \(fileID), found \(matches.count).")
        return
      }
      let visibleTop = max(content.frame.minY, app.navigationBars["Book details"].frame.maxY)
      if read.exists && read.isHittable && read.frame.minY >= visibleTop
        && read.frame.maxY <= content.frame.maxY
      {
        break
      }
      if content.staticTexts["bookHasNoFiles"].exists { break }
      let scrollDown = read.exists && read.frame.minY < visibleTop
      print(
        "IPAD-E02 Read file \(fileID) scroll=\(scroll) matches=\(matches.count) direction=\(scrollDown ? "down" : "up")"
      )
      // Short drags keep virtualized file controls from passing between accessibility snapshots.
      let start = content.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.65))
      let end = content.coordinate(
        withNormalizedOffset: CGVector(dx: 0.02, dy: scrollDown ? 0.9 : 0.4))
      start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
    }
    guard matches.count == 1,
      read.wait(for: \.isHittable, toEqual: true, timeout: 10),
      read.frame.minY >= max(content.frame.minY, app.navigationBars["Book details"].frame.maxY),
      read.frame.maxY <= content.frame.maxY
    else {
      attach(
        Data(app.debugDescription.utf8), name: "IPAD-E02-unreachable-read-file-\(fileID)-hierarchy",
        type: "public.plain-text")
      XCTFail(
        "File \(fileID) is unavailable or unreachable after twelve bounded Book details content scrolls."
      )
      return
    }
    XCTAssertEqual(matches.count, 1)
    capture("IPAD-E02-native-file-\(fileID)-read-action-visible")
    read.tap()
  }

  @MainActor
  private func openBookDetail(_ title: String, bookID: Int, app: XCUIApplication) {
    if app.buttons["All books"].exists { app.buttons["All books"].tap() }
    app.buttons["Table"].tap()
    let matches = app.textViews.matching(identifier: "librarySearch")
    let search = matches.element
    XCTAssertTrue(search.wait(for: \.isHittable, toEqual: true, timeout: 10))
    XCTAssertEqual(matches.count, 1)
    replaceText(search, with: title)
    XCTAssertEqual(search.value as? String, title)
    capture("IPAD-E02-A01-library-search-visible-title")
    search.typeText("\n")
    let openTitle = app.buttons["tableOpen\(bookID)_title"]
    XCTAssertTrue(openTitle.wait(for: \.isHittable, toEqual: true, timeout: 15))
    openTitle.tap()
    let details = app.buttons["Book details"]
    XCTAssertTrue(details.wait(for: \.isHittable, toEqual: true, timeout: 5))
    details.tap()
    XCTAssertTrue(app.navigationBars["Book details"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["Edit Series index"].exists)
    capture("IPAD-E02-native-book-\(bookID)-details-from-title-action")
  }

  @MainActor
  private func previewPassage(_ app: XCUIApplication) {
    let selection = app.buttons["epubFixtureSelectPassage"]
    XCTAssertTrue(selection.wait(for: \.isHittable, toEqual: true, timeout: 20))
    selection.tap()
    openSelectedPassagePreview(app)
    let preview = app.staticTexts["passageSelectionPreview"]
    XCTAssertTrue(preview.label.contains("Alpha"))
    XCTAssertTrue(preview.label.contains("omega."))
  }

  @MainActor
  private func openSelectedPassagePreview(_ app: XCUIApplication) {
    let marks = app.descendants(matching: .any).matching(identifier: "epubMarkPassage")
    let mark = marks.element
    XCTAssertTrue(mark.wait(for: \.isEnabled, toEqual: true, timeout: 10))
    XCTAssertEqual(marks.count, 1)
    let panels = app.scrollViews.containing(.any, identifier: "epubMarkPassage")
    let windows = app.windows.containing(.any, identifier: "epubMarkPassage")
    guard panels.count == 1, windows.count == 1 else {
      XCTFail(
        "Expected one reader controls scroll view and window containing Mark selected passage.")
      return
    }
    let panel = panels.element
    let window = windows.element
    let positions = panel.staticTexts.matching(identifier: "epubReadingPosition")
    guard positions.count == 1 else {
      XCTFail("Expected one logical reading position in the reader controls scroll view.")
      return
    }
    let windowFrame = window.frame
    let position = positions.element.label
    let visible = panel.frame.intersection(windowFrame)
    for _ in 0..<6 {
      if mark.isHittable && visible.contains(mark.frame) { break }
      if mark.frame.minY < visible.minY {
        panel.swipeDown()
      } else {
        panel.swipeUp()
      }
      guard window.frame == windowFrame, positions.element.label == position else {
        XCTFail(
          "Revealing Mark selected passage moved the reader window or logical reading position.")
        return
      }
    }
    guard mark.wait(for: \.isHittable, toEqual: true, timeout: 10),
      visible.contains(mark.frame), mark.isEnabled
    else {
      XCTFail(
        "Mark selected passage is not fully visible, hittable and enabled in reader controls.")
      return
    }
    mark.tap()
    let previews = app.staticTexts.matching(identifier: "passageSelectionPreview")
    XCTAssertTrue(previews.element.waitForExistence(timeout: 10))
    XCTAssertEqual(previews.count, 1)
  }

  @MainActor
  private func tapInkControl(_ id: String, app: XCUIApplication) {
    let controls = app.buttons.matching(identifier: id)
    let toolbars = app.scrollViews.matching(identifier: "pdfInkToolbar")
    let windows = app.windows.containing(.scrollView, identifier: "pdfInkToolbar")
    let pages = app.staticTexts.matching(
      NSPredicate(format: "label MATCHES %@", "Page [0-9]+ of [0-9]+"))
    guard controls.element.waitForExistence(timeout: 10), controls.count == 1,
      toolbars.count == 1, windows.count == 1, pages.count == 1
    else {
      XCTFail("Expected unique ink control, toolbar, reader window and logical page: \(id).")
      return
    }
    let control = controls.element
    let toolbar = toolbars.element
    let window = windows.element
    let windowFrame = window.frame
    let pageLabel = pages.element.label
    let visible = toolbar.frame.intersection(windowFrame)
    for _ in 0..<6 {
      if control.isHittable && visible.contains(control.frame) { break }
      let rowY = control.frame.midY
      guard rowY > visible.minY, rowY < visible.maxY else {
        XCTFail("Ink control row is outside the visible toolbar: \(id).")
        return
      }
      let revealLeft = control.frame.minX < visible.minX
      let startX = visible.minX + visible.width * (revealLeft ? 0.3 : 0.7)
      let endX = visible.minX + visible.width * (revealLeft ? 0.65 : 0.35)
      // The scroll view frame includes window chrome above the actual control row.
      let start = toolbar.coordinate(
        withNormalizedOffset: CGVector(
          dx: (startX - toolbar.frame.minX) / toolbar.frame.width,
          dy: (rowY - toolbar.frame.minY) / toolbar.frame.height))
      let end = start.withOffset(CGVector(dx: endX - startX, dy: 0))
      start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
      guard window.frame == windowFrame, pages.element.label == pageLabel else {
        XCTFail("Revealing ink control moved the reader window or changed its logical page: \(id).")
        return
      }
    }
    guard control.wait(for: \.isHittable, toEqual: true, timeout: 5),
      visible.contains(control.frame), control.wait(for: \.isEnabled, toEqual: true, timeout: 10)
    else {
      XCTFail("Ink control is not fully visible, hittable and enabled: \(id).")
      return
    }
    control.tap()
  }

  @MainActor
  private func tapHubControl(_ id: String, app: XCUIApplication) {
    let control = app.buttons[id]
    XCTAssertTrue(control.waitForExistence(timeout: 10))
    let toolbar = app.scrollViews.containing(.button, identifier: id).firstMatch
    for _ in 0..<6 where !control.isHittable { toolbar.swipeLeft() }
    XCTAssertTrue(control.wait(for: \.isHittable, toEqual: true, timeout: 5))
    XCTAssertTrue(control.wait(for: \.isEnabled, toEqual: true, timeout: 15))
    control.tap()
  }

  @MainActor
  private func inkRect(_ item: [String: Any]) throws -> CGRect {
    let pdf = try XCTUnwrap(item["pdf"] as? [String: Any])
    let rect = try XCTUnwrap(pdf["rect"] as? [String: Any])
    return CGRect(
      x: try XCTUnwrap(rect["x"] as? Double), y: try XCTUnwrap(rect["y"] as? Double),
      width: try XCTUnwrap(rect["width"] as? Double),
      height: try XCTUnwrap(rect["height"] as? Double))
  }

  @MainActor
  private func inkStrokeIDs(_ item: [String: Any]) throws -> [String] {
    let drawing = try XCTUnwrap(item["drawing"] as? [String: Any])
    let strokes = try XCTUnwrap(drawing["strokes"] as? [[String: Any]])
    return try strokes.map { try XCTUnwrap($0["id"] as? String) }
  }

  @MainActor
  private func reopenPassage(_ id: Int, app: XCUIApplication) {
    let menu = app.buttons["epubPassageNotes"]
    XCTAssertTrue(menu.wait(for: \.isHittable, toEqual: true, timeout: 10))
    menu.tap()
    let item = app.buttons["passageEdit\(id)"]
    XCTAssertTrue(item.waitForExistence(timeout: 10))
    item.tap()
    XCTAssertTrue(app.staticTexts["passageSelectionPreview"].waitForExistence(timeout: 10))
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
  private func loginAPI() async throws -> String {
    let data = try await api(
      "auth/login", method: "POST",
      body: [
        "username": "ipad-owner", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "Annotation UI assertion client",
      ])
    let credentials = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let refresh = try XCTUnwrap(credentials["refreshToken"] as? String)
    let endpoint = try XCTUnwrap(URL(string: "\(Self.fixtureServerURL)/api/v1/auth/logout"))
    addTeardownBlock(Self.logoutCleanup(refresh: refresh, endpoint: endpoint))
    return try XCTUnwrap(credentials["accessToken"] as? String)
  }

  @MainActor
  private func api(
    _ path: String, method: String = "GET", token: String? = nil, body: [String: Any]? = nil
  ) async throws -> Data {
    var request = URLRequest(
      url: try XCTUnwrap(URL(string: "\(Self.fixtureServerURL)/api/v1/\(path)")))
    request.httpMethod = method
    request.timeoutInterval = 15
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await Self.networkResponse(for: request)
    XCTAssertTrue((200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0), path)
    return data
  }

  @MainActor
  private func fault(_ action: String, method: String = "POST", expectedStatus: Int = 204)
    async throws
  {
    var request = URLRequest(
      url: try XCTUnwrap(URL(string: "\(Self.faultServerURL)/__faults/annotations/\(action)")))
    request.httpMethod = method
    request.timeoutInterval = 15
    let (data, response) = try await Self.networkResponse(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, expectedStatus)
    if action == "held" { XCTAssertEqual(String(data: data, encoding: .utf8), "held") }
  }

  @MainActor
  private func checkpoint(_ stage: String, reach: Bool = false) async throws {
    let url = try XCTUnwrap(
      URL(string: "\(Self.faultServerURL)/__faults/annotations/checkpoint/\(stage)"))
    if reach {
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      let (_, response) = try await Self.networkResponse(for: request)
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
      return
    }
    let deadline = Date().addingTimeInterval(45)
    var reached = false
    repeat {
      let (data, response) = try await Self.networkResponse(for: URLRequest(url: url))
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
      let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
      reached = value["reached"] as? Bool == true
      if !reached { try await Task.sleep(for: .milliseconds(250)) }
    } while !reached && Date() < deadline
    XCTAssertTrue(reached, "The concurrent browser did not reach \(stage)")
  }

  @MainActor
  private func annotations(bookID: Int, token: String) async throws -> [[String: Any]] {
    let data = try await api(
      "annotations/native/delta?bookId=\(bookID)&cursor=0&limit=100", token: token)
    let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(response["hasMore"] as? Bool, false, "A journey fixture must remain bounded")
    return try XCTUnwrap(response["items"] as? [[String: Any]])
  }

  @MainActor
  private func waitForAnnotations(
    bookID: Int, token: String, condition: ([[String: Any]]) -> Bool
  ) async throws -> [[String: Any]] {
    let deadline = Date().addingTimeInterval(20)
    var items = try await annotations(bookID: bookID, token: token)
    while !condition(items) && Date() < deadline {
      try await Task.sleep(for: .milliseconds(250))
      items = try await annotations(bookID: bookID, token: token)
    }
    XCTAssertTrue(condition(items), "The public annotation state did not converge")
    let data = try JSONSerialization.data(
      withJSONObject: items, options: [.prettyPrinted, .sortedKeys])
    attach(data, name: "IPAD-E02-public-annotations-book-\(bookID)", type: "public.json")
    return items
  }

  private func attach(_ data: Data, name: String, type: String) {
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: type)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor
  private func audit(_ app: XCUIApplication, state: String) throws {
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = "\(state)-hierarchy"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
    try app.performAccessibilityAudit { issue in
      let attachment = XCTAttachment(
        string:
          "\(issue.detailedDescription)\n\(issue.element?.debugDescription ?? "No associated element")"
      )
      attachment.name = "\(state)-accessibility-issue"
      attachment.lifetime = .keepAlways
      self.add(attachment)
      return false
    }
  }

  @MainActor
  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    let profile = ProcessInfo.processInfo.environment["IPAD_E02_PROFILE"] ?? "pro13-portrait-light"
    attachment.name = "\(name)-\(profile)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
