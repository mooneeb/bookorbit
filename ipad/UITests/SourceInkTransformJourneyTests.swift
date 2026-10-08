import Foundation
import PDFKit
import XCTest

final class SourceInkTransformJourneyTests: XCTestCase {
  private let httpSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 20
    configuration.waitsForConnectivity = false
    return URLSession(configuration: configuration)
  }()

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
  }

  override func tearDown() async throws {
    if let testRun, testRun.failureCount > 0 {
      let data = await MainActor.run { XCUIScreen.main.screenshot().pngRepresentation }
      attach(data, name: "IPAD-E02-A03-transform-failure-\(name)", type: "public.png")
    }
    try await super.tearDown()
  }

  @MainActor
  func testIPADE02A03LassoTransformsAndPublishedInversePreserveNewerSeparateInk() async throws {
    try await fault("reset")
    let token = try await loginAPI()
    let selected = try await seedInkGroup(token: token)
    let selectedStrokeID = try XCTUnwrap(strokeIDs(selected).first)
    let untouchedStrokeID = try XCTUnwrap(strokeIDs(selected).last)
    let untouchedStroke = try stroke(selected, id: untouchedStrokeID)
    let separate = try await seedInk(token: token, x: 350, y: 350, color: "#aa00ff")
    let selectedID = try id(selected)
    let separateID = try id(separate)
    let selectedIdentity = try identity(selected)
    let separateIdentity = try identity(separate)
    let originalBytes = try await api("books/files/1/serve", token: token)
    let app = try await openPDF(token: token)
    XCTAssertTrue(app.images["pdfInkItem\(selectedIdentity)"].waitForExistence(timeout: 20))
    XCTAssertTrue(app.images["pdfInkItem\(separateIdentity)"].exists)
    tapInk("pdfInkSelect", app: app)
    tapGroup(separateIdentity, app: app)
    XCTAssertTrue(app.buttons["pdfInkSelectItem\(separateIdentity)"].isSelected)
    tapInk("pdfInkLasso", app: app)
    XCTAssertEqual(app.buttons["pdfInkFixtureLasso"].label, "Feed fixture lasso")
    tapInk("pdfInkFixtureLasso", app: app)
    XCTAssertTrue(
      app.buttons["pdfInkSelectItem\(selectedIdentity)"].wait(
        for: \.isSelected, toEqual: true, timeout: 10))
    XCTAssertFalse(app.buttons["pdfInkSelectItem\(separateIdentity)"].isSelected)
    XCTAssertEqual(app.staticTexts["pdfInkSelectedStrokeCount"].label, "1 of 2 strokes selected")
    capture("IPAD-E02-A03-tagged-lasso-selects-red-stroke-excludes-green-in-same-group")
    tapInk("pdfInkMoveRight", app: app)
    let moved = try await waitForItem(selectedID, token: token) {
      guard let current = try? self.strokeBounds($0, id: selectedStrokeID),
        let original = try? self.strokeBounds(selected, id: selectedStrokeID)
      else {
        return false
      }
      return current.minX > original.minX
    }
    XCTAssertEqual(try strokeIDs(moved), try strokeIDs(selected))
    XCTAssertEqual(try identity(moved), selectedIdentity)
    XCTAssertEqual(try json(stroke(moved, id: untouchedStrokeID)), try json(untouchedStroke))
    let movedRect = try strokeBounds(moved, id: selectedStrokeID)
    let separateAfterMove = try await item(separateID, token: token)
    XCTAssertEqual(try rect(separateAfterMove), try rect(separate))
    tapInk("pdfInkGrow", app: app)
    let resized = try await waitForItem(selectedID, token: token) {
      guard let value = try? self.strokeBounds($0, id: selectedStrokeID) else { return false }
      return value.width > movedRect.width && value.height > movedRect.height
    }
    XCTAssertEqual(try strokeIDs(resized), try strokeIDs(selected))
    XCTAssertEqual(try json(stroke(resized, id: untouchedStrokeID)), try json(untouchedStroke))
    XCTAssertFalse((try drawing(resized)["nativeData"] as? String ?? "").isEmpty)
    let resizedPDF = try await artifact(
      token: token, name: "stroke-subset-transformed", present: [selectedID, separateID])
    try assertPublishedStroke(untouchedStroke, itemID: selectedID, in: resizedPDF)
    capture("IPAD-E02-A03-lasso-selected-stroke-moved-resized-green-preserved")
    tapInk("pdfInkDelete", app: app)
    let partiallyDeleted = try await waitForItem(selectedID, token: token) {
      (try? self.strokeIDs($0)) == [untouchedStrokeID] && $0["deletedAt"] is NSNull
    }
    XCTAssertEqual(try identity(partiallyDeleted), selectedIdentity)
    XCTAssertEqual(
      try json(stroke(partiallyDeleted, id: untouchedStrokeID)), try json(untouchedStroke))
    let partialPDF = try await artifact(
      token: token, name: "selected-stroke-deleted-group-retained",
      present: [selectedID, separateID])
    try assertPublishedStroke(untouchedStroke, itemID: selectedID, in: partialPDF)
    tapInk("pdfInkUndo", app: app)
    let restoredGroup = try await waitForItem(selectedID, token: token) {
      (try? self.strokeIDs($0)) == (try? self.strokeIDs(resized))
        && ($0["version"] as? Int ?? 0) > (partiallyDeleted["version"] as? Int ?? 0)
    }
    XCTAssertEqual(try json(drawing(restoredGroup)), try json(drawing(resized)))
    XCTAssertEqual(try identity(restoredGroup), selectedIdentity)
    XCTAssertEqual(app.staticTexts["pdfInkSelectedStrokeCount"].label, "1 of 2 strokes selected")
    capture("IPAD-E02-A03-one-versioned-undo-restores-deleted-stroke-within-group")
    let beforeCopy = Set(try await sourceInk(token: token).compactMap { $0["id"] as? Int })
    tapInk("pdfInkCopy", app: app)
    XCTAssertTrue(app.staticTexts["Ink copied"].waitForExistence(timeout: 10))
    tapInk("pdfInkPaste", app: app)
    let copiedItems = try await waitForInk(token: token) {
      $0.contains { !beforeCopy.contains($0["id"] as? Int ?? -1) && $0["deletedAt"] is NSNull }
    }
    let copied = try XCTUnwrap(copiedItems.first { !beforeCopy.contains($0["id"] as? Int ?? -1) })
    let copyID = try id(copied)
    let copyIdentity = try identity(copied)
    XCTAssertNotEqual(copyID, selectedID)
    XCTAssertNotEqual(copyIdentity, selectedIdentity)
    XCTAssertEqual(try strokeIDs(copied).count, 1)
    XCTAssertFalse(try strokeIDs(copied).contains(selectedStrokeID))
    XCTAssertFalse(try strokeIDs(copied).contains(untouchedStrokeID))
    let copiedStrokeID = try XCTUnwrap(strokeIDs(copied).first)
    let copiedStroke = try stroke(copied, id: copiedStrokeID)
    let selectedStroke = try stroke(resized, id: selectedStrokeID)
    let copiedBounds = try strokeBounds(copied, id: copiedStrokeID)
    let selectedBounds = try strokeBounds(resized, id: selectedStrokeID)
    XCTAssertEqual(copiedBounds.width, selectedBounds.width, accuracy: 0.1)
    XCTAssertEqual(copiedBounds.height, selectedBounds.height, accuracy: 0.1)
    XCTAssertEqual(copiedStroke["color"] as? String, selectedStroke["color"] as? String)
    XCTAssertEqual(
      try XCTUnwrap(copiedStroke["width"] as? Double),
      try XCTUnwrap(selectedStroke["width"] as? Double), accuracy: 0.1)
    let copiedPoints = try XCTUnwrap(copiedStroke["points"] as? [[String: Any]])
    let selectedPoints = try XCTUnwrap(selectedStroke["points"] as? [[String: Any]])
    XCTAssertEqual(copiedPoints.count, selectedPoints.count)
    for (copiedPoint, selectedPoint) in zip(copiedPoints, selectedPoints) {
      for axis in ["x", "y"] {
        XCTAssertEqual(
          try XCTUnwrap(copiedPoint[axis] as? Double),
          try XCTUnwrap(selectedPoint[axis] as? Double) + 16, accuracy: 0.1)
      }
    }
    XCTAssertTrue(app.images["pdfInkItem\(copyIdentity)"].waitForExistence(timeout: 15))
    let copiedPDF = try await artifact(
      token: token, name: "copied", present: [selectedID, separateID, copyID])
    capture("IPAD-E02-A03-copy-has-distinct-retained-source-identity")
    tapInk("pdfInkDelete", app: app)
    let deleted = try await waitForItem(copyID, token: token) { $0["deletedAt"] is String }
    XCTAssertTrue(
      app.images["pdfInkItem\(copyIdentity)"].wait(for: \.exists, toEqual: false, timeout: 10))
    let deletedPDF = try await artifact(
      token: token, name: "deleted", present: [selectedID, separateID], absent: [copyID])
    XCTAssertNotEqual(copiedPDF, deletedPDF)
    let newer = try await seedInk(token: token, x: 400, y: 400, color: "#0000ff")
    let newerID = try id(newer)
    let newerIdentity = try identity(newer)
    let newerDrawing = try drawing(newer)
    tapInk("pdfInkUndo", app: app)
    let inverse = try await waitForItem(copyID, token: token) {
      $0["deletedAt"] is NSNull && ($0["version"] as? Int ?? 0) > (deleted["version"] as? Int ?? 0)
    }
    XCTAssertEqual(try identity(inverse), copyIdentity)
    XCTAssertEqual(try rect(inverse), try rect(copied))
    XCTAssertEqual(try json(drawing(inverse)), try json(drawing(copied)))
    let preservedNewer = try await item(newerID, token: token)
    let preservedSeparate = try await item(separateID, token: token)
    let preservedOriginalGroup = try await item(selectedID, token: token)
    XCTAssertEqual(try json(drawing(preservedOriginalGroup)), try json(drawing(resized)))
    XCTAssertEqual(try json(drawing(preservedNewer)), try json(newerDrawing))
    XCTAssertEqual(try rect(preservedSeparate), try rect(separate))
    XCTAssertTrue(app.images["pdfInkItem\(copyIdentity)"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.images["pdfInkItem\(newerIdentity)"].waitForExistence(timeout: 15))
    let restoredPDF = try await artifact(
      token: token, name: "explicit-inverse-preserves-newer",
      present: [selectedID, separateID, copyID, newerID])
    XCTAssertNotEqual(deletedPDF, restoredPDF)
    try assertPublishedStroke(untouchedStroke, itemID: selectedID, in: restoredPDF)
    try assertUnrelatedPages(originalBytes, restoredPDF)
    capture("IPAD-E02-A03-postcommit-inverse-keeps-newer-separate-group")
  }

  @MainActor
  func testIPADE02A03UndoQueuesUnknownWriteAndConvergesAfterRestart() async throws {
    try await fault("reset")
    let token = try await loginAPI()
    let app = try await openPDF(token: token)
    let baseline = try await sourceInk(token: token)
    let baselinePDF = try await api("books/files/1/serve", token: token)
    let groups = app.images.matching(NSPredicate(format: "identifier BEGINSWITH %@", "pdfInkItem"))
    let existing = Set(groups.allElementsBoundByIndex.map(\.identifier))
    try await fault("write-arm")
    tapInk("pdfInkFixtureStroke", app: app)
    XCTAssertTrue(app.staticTexts["Ink saved locally"].waitForExistence(timeout: 10))
    try await fault("held", method: "GET", expectedStatus: 200)
    let pending = try XCTUnwrap(
      groups.allElementsBoundByIndex.first { !existing.contains($0.identifier) })
    let pendingIdentity = String(pending.identifier.dropFirst("pdfInkItem".count))
    let heldPublicItems = try await sourceInk(token: token)
    XCTAssertFalse(
      heldPublicItems.contains {
        ($0["clientId"] as? String)?.lowercased() == pendingIdentity.lowercased()
      })
    capture("IPAD-E02-A03-real-native-ink-held-before-server-persistence")
    tapInk("pdfInkUndo", app: app)
    XCTAssertTrue(
      app.staticTexts["Undo queued. The saved change will be checked when connected."]
        .waitForExistence(timeout: 10))
    XCTAssertTrue(pending.wait(for: \.exists, toEqual: false, timeout: 10))
    capture("IPAD-E02-A03-attempted-write-undo-queued-with-overlay-hidden")
    try await fault("offline")
    try await releaseHeldRequest()
    app.terminate()
    try await fault("online")
    app.launch()
    try await readCurrentPDF(app: app)
    let reconciled = try await waitForInk(token: token) {
      $0.contains {
        ($0["clientId"] as? String)?.lowercased() == pendingIdentity.lowercased()
          && $0["deletedAt"] is String
      }
    }
    let undone = try XCTUnwrap(
      reconciled.first {
        ($0["clientId"] as? String)?.lowercased() == pendingIdentity.lowercased()
      })
    let undoneID = try id(undone)
    XCTAssertGreaterThan(try XCTUnwrap(undone["version"] as? Int), 1)
    for previous in baseline {
      let preserved = try XCTUnwrap(reconciled.first { $0["id"] as? Int == previous["id"] as? Int })
      XCTAssertEqual(preserved["version"] as? Int, previous["version"] as? Int)
      XCTAssertEqual(try json(drawing(preserved)), try json(drawing(previous)))
      XCTAssertEqual(try rect(preserved), try rect(previous))
    }
    let preservedIDs = try baseline.filter { $0["deletedAt"] is NSNull }.map(id)
    let finalPDF = try await artifact(
      token: token, name: "queued-undo-reconciled-after-restart", present: preservedIDs,
      absent: [undoneID])
    try assertPageAppearance(baselinePDF, finalPDF, pages: 0..<3)
    XCTAssertFalse(app.images["pdfInkItem\(pendingIdentity.lowercased())"].exists)
    XCTAssertTrue(app.staticTexts["Ink synchronized"].waitForExistence(timeout: 15))
    XCTAssertFalse(app.staticTexts["pdfInkError"].exists)
    capture("IPAD-E02-A03-durable-queued-undo-converges-without-visible-source-ink")
  }

  @MainActor
  func testIPADE02A03UndoCancelsUnattemptedInkWithNoPublicOperationPOST() async throws {
    try await fault("reset")
    let token = try await loginAPI()
    let app = try await openPDF(token: token, precommitFixture: true)
    let baseline = try await sourceInk(token: token)
    let originalPDF = try await api("books/files/1/serve", token: token)
    let groups = app.images.matching(NSPredicate(format: "identifier BEGINSWITH %@", "pdfInkItem"))
    let existing = Set(groups.allElementsBoundByIndex.map(\.identifier))
    tapInk("pdfInkFixtureStroke", app: app)
    XCTAssertTrue(app.staticTexts["Ink saved locally"].waitForExistence(timeout: 10))
    let pending = try XCTUnwrap(
      groups.allElementsBoundByIndex.first { !existing.contains($0.identifier) })
    let pendingIdentifier = pending.identifier
    XCTAssertTrue(pending.exists)
    tapInk("pdfInkUndo", app: app)
    XCTAssertTrue(app.staticTexts["Ink synchronized"].waitForExistence(timeout: 10))
    XCTAssertTrue(pending.wait(for: \.exists, toEqual: false, timeout: 10))
    capture("IPAD-E02-A03-tagged-timing-fixture-cancels-unattempted-native-ink")
    app.terminate()
    app.launch()
    try await readCurrentPDF(app: app)
    XCTAssertFalse(app.images[pendingIdentifier].exists)
    let unchanged = try await sourceInk(token: token)
    XCTAssertEqual(try json(unchanged), try json(baseline))
    let unchangedPDF = try await api("books/files/1/serve", token: token)
    XCTAssertEqual(unchangedPDF, originalPDF)
    let requests = try await traffic()
    let operationPosts = requests.filter {
      guard $0["method"] as? String == "POST", let path = $0["path"] as? String else {
        return false
      }
      return path == "/api/v1/annotations/native/operations"
        || path.range(
          of: "^/api/v1/annotations/native/source-ink/[1-9][0-9]*/[1-9][0-9]*/operations$",
          options: .regularExpression) != nil
    }
    XCTAssertTrue(operationPosts.isEmpty, "Unattempted Undo must cancel before a public write")
    XCTAssertFalse(app.staticTexts["pdfInkError"].exists)
    capture("IPAD-E02-A03-canceled-local-ink-stays-absent-after-restart-with-zero-POSTs")
  }

  @MainActor
  func testIPADE02A03UndoRefusesToReplaceNewerEditOfSameSourceItem() async throws {
    try await fault("reset")
    let token = try await loginAPI()
    let before = Set(try await sourceInk(token: token).compactMap { $0["id"] as? Int })
    let app = try await openPDF(token: token)
    tapInk("pdfInkFixtureStroke", app: app)
    let createdItems = try await waitForInk(token: token) {
      $0.contains { !before.contains($0["id"] as? Int ?? -1) && $0["deletedAt"] is NSNull }
    }
    let created = try XCTUnwrap(createdItems.first { !before.contains($0["id"] as? Int ?? -1) })
    let createdID = try id(created)
    let createdIdentity = try identity(created)
    let source = try await pageSource(token: token)
    let payload = try inkPayload(
      source: source, x: 250, y: 350, color: "#00ff00", strokeID: "newer-\(UUID().uuidString)")
    let response = try await operations(
      token: token,
      changes: [
        [
          "operationId": UUID().uuidString, "clientId": createdIdentity, "annotationId": createdID,
          "bookId": 1, "baseVersion": try XCTUnwrap(created["version"] as? Int), "action": "update",
          "payload": payload,
        ]
      ])
    let newer = try XCTUnwrap(response.first?["annotation"] as? [String: Any])
    let protectedPDF = try await artifact(
      token: token, name: "newer-same-item-before-undo", present: [createdID])
    tapInk("pdfInkUndo", app: app)
    XCTAssertTrue(app.staticTexts["pdfInkError"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["pdfInkError"].label.contains("Newer changes exist"))
    let preserved = try await item(createdID, token: token)
    XCTAssertEqual(preserved["version"] as? Int, newer["version"] as? Int)
    XCTAssertTrue(preserved["deletedAt"] is NSNull)
    XCTAssertEqual(try json(drawing(preserved)), try json(drawing(newer)))
    let preservedPDF = try await api("books/files/1/serve", token: token)
    XCTAssertEqual(preservedPDF, protectedPDF)
    XCTAssertTrue(app.images["pdfInkItem\(createdIdentity)"].exists)
    capture("IPAD-E02-A03-newer-same-item-edit-blocks-stale-undo")
  }

  @MainActor
  private func seedInkGroup(token: String) async throws -> [String: Any] {
    let source = try await pageSource(token: token)
    let clientID = UUID().uuidString
    var payload = try inkPayload(
      source: source, x: 80, y: 200, color: "#ff0000", strokeID: "\(clientID)-red")
    payload["pdf"] = [
      "page": 0, "rect": ["x": 76, "y": 196, "width": 378, "height": 8], "rects": [],
    ]
    payload["drawing"] = [
      "format": "bookorbit-ink-v1",
      "strokes": [
        [
          "id": "\(clientID)-red", "color": "#ff0000", "width": 8,
          "points": [["x": 80, "y": 200], ["x": 180, "y": 200]],
        ],
        [
          "id": "\(clientID)-green", "color": "#00ff00", "width": 8,
          "points": [["x": 350, "y": 200], ["x": 450, "y": 200]],
        ],
      ],
    ]
    let results = try await operations(
      token: token,
      changes: [
        [
          "operationId": UUID().uuidString, "clientId": clientID, "bookId": 1,
          "baseVersion": 0, "action": "create", "payload": payload,
        ]
      ])
    return try XCTUnwrap(results.first?["annotation"] as? [String: Any])
  }

  private func stroke(_ item: [String: Any], id: String) throws -> [String: Any] {
    let strokes = try XCTUnwrap(drawing(item)["strokes"] as? [[String: Any]])
    return try XCTUnwrap(strokes.first { $0["id"] as? String == id })
  }

  private func strokeBounds(_ item: [String: Any], id: String) throws -> CGRect {
    let value = try stroke(item, id: id)
    let points = try XCTUnwrap(value["points"] as? [[String: Any]])
    let xs = try points.map { try XCTUnwrap($0["x"] as? Double) }
    let ys = try points.map { try XCTUnwrap($0["y"] as? Double) }
    let width = try XCTUnwrap(value["width"] as? Double)
    let minimumX = try XCTUnwrap(xs.min())
    let minimumY = try XCTUnwrap(ys.min())
    return CGRect(
      x: minimumX - width / 2, y: minimumY - width / 2,
      width: try XCTUnwrap(xs.max()) - minimumX + width,
      height: try XCTUnwrap(ys.max()) - minimumY + width)
  }

  @MainActor
  private func assertPublishedStroke(_ expected: [String: Any], itemID: Int, in bytes: Data) throws
  {
    let document = try XCTUnwrap(PDFDocument(data: bytes))
    let page = try XCTUnwrap(document.page(at: 0))
    let annotation = try XCTUnwrap(
      page.annotations.first {
        $0.value(forAnnotationKey: .name) as? String == "bookorbit:\(itemID)"
      })
    let retained = annotation.value(
      forAnnotationKey: PDFAnnotationKey(rawValue: "/BookOrbitDrawing"))
    let data: Data
    if let string = retained as? String {
      data = Data(string.utf8)
    } else {
      data = try XCTUnwrap(retained as? Data)
    }
    let drawing = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let strokes = try XCTUnwrap(drawing["strokes"] as? [[String: Any]])
    let actual = try XCTUnwrap(strokes.first { $0["id"] as? String == expected["id"] as? String })
    XCTAssertEqual(try json(actual), try json(expected))
  }

  @MainActor
  private func seedInk(token: String, x: Int, y: Int, color: String) async throws -> [String: Any] {
    let source = try await pageSource(token: token)
    let clientID = UUID().uuidString
    let results = try await operations(
      token: token,
      changes: [
        [
          "operationId": UUID().uuidString, "clientId": clientID, "bookId": 1, "baseVersion": 0,
          "action": "create",
          "payload": try inkPayload(source: source, x: x, y: y, color: color, strokeID: clientID),
        ]
      ])
    return try XCTUnwrap(results.first?["annotation"] as? [String: Any])
  }

  private func inkPayload(source: [String: Any], x: Int, y: Int, color: String, strokeID: String)
    throws -> [String: Any]
  {
    [
      "kind": "pdf_ink", "bookFileId": 1, "text": "",
      "pdf": [
        "page": 0, "rect": ["x": x - 4, "y": y - 4, "width": 108, "height": 8], "rects": [],
      ],
      "drawing": [
        "format": "bookorbit-ink-v1",
        "strokes": [
          [
            "id": strokeID, "color": color, "width": 8,
            "points": [["x": x, "y": y], ["x": x + 100, "y": y]],
          ]
        ],
      ],
      "sourceRevision": try XCTUnwrap(source["sourceRevision"] as? String),
      "pageFingerprint": try XCTUnwrap(source["pageFingerprint"] as? String),
    ]
  }

  @MainActor
  private func operations(token: String, changes: [[String: Any]]) async throws -> [[String: Any]] {
    let data = try await api(
      "annotations/native/source-ink/1/1/operations", method: "POST", token: token,
      body: ["deviceId": "IPAD-E02-A03-other-public-client", "operations": changes])
    let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let results = try XCTUnwrap(value["results"] as? [[String: Any]])
    for result in results {
      XCTAssertEqual(result["status"] as? String, "applied")
      XCTAssertEqual((result["publication"] as? [String: Any])?["status"] as? String, "published")
    }
    attach(data, name: "IPAD-E02-A03-canonical-source-operations", type: "public.json")
    return results
  }

  @MainActor
  private func pageSource(token: String) async throws -> [String: Any] {
    let data = try await api("annotations/native/files/1/source?bookId=1&page=0", token: token)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @MainActor
  private func sourceInk(token: String) async throws -> [[String: Any]] {
    let data = try await api(
      "annotations/native/source-ink?bookId=1&bookFileId=1&cursor=0&limit=100", token: token)
    let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(value["hasMore"] as? Bool, false, "The source fixture must remain bounded")
    return try XCTUnwrap(value["items"] as? [[String: Any]])
  }

  @MainActor
  private func item(_ id: Int, token: String) async throws -> [String: Any] {
    let values = try await sourceInk(token: token)
    return try XCTUnwrap(values.first { $0["id"] as? Int == id })
  }

  @MainActor
  private func waitForItem(_ id: Int, token: String, condition: ([String: Any]) -> Bool)
    async throws -> [String: Any]
  {
    let values = try await waitForInk(token: token) { items in
      items.first { $0["id"] as? Int == id }.map(condition) == true
    }
    return try XCTUnwrap(values.first { $0["id"] as? Int == id })
  }

  @MainActor
  private func waitForInk(token: String, condition: ([[String: Any]]) -> Bool) async throws
    -> [[String: Any]]
  {
    let deadline = Date().addingTimeInterval(20)
    var values = try await sourceInk(token: token)
    while !condition(values) && Date() < deadline {
      try await Task.sleep(for: .milliseconds(250))
      values = try await sourceInk(token: token)
    }
    XCTAssertTrue(condition(values), "Public source ink did not converge")
    attach(try json(values), name: "IPAD-E02-A03-public-source-ink", type: "public.json")
    return values
  }

  @MainActor
  private func artifact(token: String, name: String, present: [Int], absent: [Int] = [])
    async throws -> Data
  {
    let bytes = try await api("books/files/1/serve", token: token)
    let document = try XCTUnwrap(PDFDocument(data: bytes))
    XCTAssertEqual(document.pageCount, 3)
    let page = try XCTUnwrap(document.page(at: 0))
    let names = Set(page.annotations.compactMap { $0.value(forAnnotationKey: .name) as? String })
    for id in present { XCTAssertTrue(names.contains("bookorbit:\(id)")) }
    for id in absent { XCTAssertFalse(names.contains("bookorbit:\(id)")) }
    for index in 0..<3 {
      let page = try XCTUnwrap(document.page(at: index))
      XCTAssertEqual(page.bounds(for: .mediaBox), CGRect(x: 0, y: 0, width: 600, height: 800))
      XCTAssertTrue((page.string ?? "").contains("Orbit fixture: passage \(index + 1)"))
    }
    attach(bytes, name: "IPAD-E02-A03-source-PDF-\(name)", type: "com.adobe.pdf")
    let rendered = XCTAttachment(
      image: page.thumbnail(of: CGSize(width: 600, height: 800), for: .mediaBox))
    rendered.name = "IPAD-E02-A03-independent-PDFKit-render-\(name)"
    rendered.lifetime = .keepAlways
    add(rendered)
    return bytes
  }

  @MainActor
  private func assertUnrelatedPages(_ before: Data, _ after: Data) throws {
    try assertPageAppearance(before, after, pages: 1..<3)
  }

  @MainActor
  private func assertPageAppearance(_ before: Data, _ after: Data, pages: Range<Int>) throws {
    let original = try XCTUnwrap(PDFDocument(data: before))
    let current = try XCTUnwrap(PDFDocument(data: after))
    for index in pages {
      let first = try XCTUnwrap(original.page(at: index))
      let second = try XCTUnwrap(current.page(at: index))
      XCTAssertEqual(first.string, second.string)
      XCTAssertEqual(
        first.thumbnail(of: CGSize(width: 600, height: 800), for: .mediaBox).pngData(),
        second.thumbnail(of: CGSize(width: 600, height: 800), for: .mediaBox).pngData())
    }
  }

  private func id(_ item: [String: Any]) throws -> Int { try XCTUnwrap(item["id"] as? Int) }
  private func identity(_ item: [String: Any]) throws -> String {
    try XCTUnwrap(item["clientId"] as? String)
  }
  private func drawing(_ item: [String: Any]) throws -> [String: Any] {
    try XCTUnwrap(item["drawing"] as? [String: Any])
  }
  private func strokeIDs(_ item: [String: Any]) throws -> [String] {
    try XCTUnwrap(drawing(item)["strokes"] as? [[String: Any]]).map {
      try XCTUnwrap($0["id"] as? String)
    }
  }
  private func rect(_ item: [String: Any]) throws -> CGRect {
    let pdf = try XCTUnwrap(item["pdf"] as? [String: Any])
    let bounds = try XCTUnwrap(pdf["rect"] as? [String: Any])
    return CGRect(
      x: try XCTUnwrap(bounds["x"] as? Double), y: try XCTUnwrap(bounds["y"] as? Double),
      width: try XCTUnwrap(bounds["width"] as? Double),
      height: try XCTUnwrap(bounds["height"] as? Double))
  }
  private func json(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  }

  @MainActor
  private func openPDF(token: String, precommitFixture: Bool = false) async throws
    -> XCUIApplication
  {
    _ = try await api("books/files/1/progress", method: "DELETE", token: token)
    XCUIDevice.shared.orientation = profile.contains("landscape") ? .landscapeLeft : .portrait
    let app = XCUIApplication()
    app.launchArguments = [
      "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "--annotation-input-driver",
      "-AppleInterfaceStyle", profile.contains("dark") ? "Dark" : "Light",
      "-UIPreferredContentSizeCategoryName",
      profile.contains("large") ? "UICTContentSizeCategoryXXXL" : "UICTContentSizeCategoryL",
    ]
    app.launchEnvironment["BOOKORBIT_ANNOTATION_INPUT_FIXTURE"] = "1"
    if precommitFixture { app.launchEnvironment["BOOKORBIT_ANNOTATION_PRECOMMIT_FIXTURE"] = "1" }
    E02ProfileSupport.configure(app)
    app.launch()
    if !app.textFields["serverURL"].waitForExistence(timeout: 3) {
      for _ in 0..<7 where !app.buttons["signOut"].exists {
        if app.buttons["epubCloseReader"].exists {
          app.buttons["epubCloseReader"].tap()
        } else if app.buttons["Close reader"].exists {
          app.buttons["Close reader"].tap()
        } else if app.buttons["annotationHubDone"].exists {
          app.buttons["annotationHubDone"].tap()
        } else if app.buttons["sourceRecoveryClose"].exists {
          app.buttons["sourceRecoveryClose"].tap()
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
    replaceText(server, with: "http://127.0.0.1:16485")
    app.buttons["connectServer"].tap()
    guard E02ProfileSupport.ensureSignInForm(app: app, serverURL: "http://127.0.0.1:16485") else {
      return app
    }
    let username = app.textFields["username"]
    XCTAssertTrue(username.wait(for: \.isHittable, toEqual: true, timeout: 10))
    replaceText(username, with: "ipad-owner")
    replaceText(app.secureTextFields["password"], with: "IpadFixture123")
    app.buttons["signIn"].tap()
    try await readCurrentPDF(app: app)
    return app
  }

  @MainActor
  private func readCurrentPDF(app: XCUIApplication) async throws {
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 25))
    if app.buttons["All books"].exists { app.buttons["All books"].tap() }
    app.buttons["Table"].tap()
    let search = app.textViews["librarySearch"]
    XCTAssertTrue(search.wait(for: \.isHittable, toEqual: true, timeout: 10))
    replaceText(search, with: "Orbit fixture\n")
    let title = app.buttons["tableOpen1_title"]
    XCTAssertTrue(title.wait(for: \.isHittable, toEqual: true, timeout: 15))
    title.tap()
    app.buttons["Book details"].tap()
    XCTAssertTrue(app.navigationBars["Book details"].waitForExistence(timeout: 10))
    attach(
      Data(app.debugDescription.utf8), name: "IPAD-E02-A03-book-details-hierarchy",
      type: "public.plain-text")
    guard E02ProfileSupport.openBookFile(app: app, fileID: 1) else { return }
    XCTAssertTrue(app.staticTexts["Page 1 of 3"].waitForExistence(timeout: 25))
    XCTAssertTrue(app.buttons["pdfInkDraw"].waitForExistence(timeout: 15))
  }

  @MainActor
  private func tapGroup(_ identity: String, app: XCUIApplication) {
    let button = app.buttons["pdfInkSelectItem\(identity)"]
    let rows = app.scrollViews.matching(identifier: "pdfInkGroups")
    XCTAssertEqual(rows.count, 1, "The source ink picker must be uniquely identifiable")
    let row = rows.element
    XCTAssertTrue(row.wait(for: \.isHittable, toEqual: true, timeout: 10))
    for _ in 0..<6 where !button.isHittable { row.swipeLeft() }
    XCTAssertTrue(button.wait(for: \.isHittable, toEqual: true, timeout: 10))
    button.tap()
  }

  @MainActor
  private func tapInk(_ id: String, app: XCUIApplication) {
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
  private func replaceText(_ field: XCUIElement, with text: String) {
    field.tap()
    let old = field.value as? String ?? ""
    if !old.isEmpty && old != field.placeholderValue {
      field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.95)).tap()
      field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.utf16.count))
    }
    field.typeText(text)
  }

  @MainActor
  private func loginAPI() async throws -> String {
    let data = try await api(
      "auth/login", method: "POST",
      body: [
        "username": "ipad-owner", "password": "IpadFixture123",
        "clientKind": "native", "deviceLabel": "Source transform public assertions",
      ])
    let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let refresh = try XCTUnwrap(value["refreshToken"] as? String)
    addTeardownBlock { [refresh, httpSession] in
      var request = URLRequest(url: URL(string: "http://127.0.0.1:16482/api/v1/auth/logout")!)
      request.httpMethod = "POST"
      request.timeoutInterval = 15
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: ["refreshToken": refresh])
      let (_, response) = try await httpSession.data(for: request)
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }
    return try XCTUnwrap(value["accessToken"] as? String)
  }

  @MainActor
  private func api(
    _ path: String, method: String = "GET", token: String? = nil, body: [String: Any]? = nil
  ) async throws -> Data {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:16482/api/v1/\(path)")!)
    request.httpMethod = method
    request.timeoutInterval = 15
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await httpSession.data(for: request)
    XCTAssertTrue((200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0), path)
    return data
  }

  @MainActor
  private func fault(_ action: String, method: String = "POST", expectedStatus: Int = 204)
    async throws
  {
    var request = URLRequest(
      url: URL(string: "http://127.0.0.1:16485/__faults/annotations/\(action)")!)
    request.httpMethod = method
    request.timeoutInterval = 15
    let (data, response) = try await httpSession.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, expectedStatus)
    if action == "held" { XCTAssertEqual(String(data: data, encoding: .utf8), "held") }
  }

  @MainActor
  private func releaseHeldRequest() async throws {
    var request = URLRequest(
      url: URL(string: "http://127.0.0.1:16485/__faults/annotations/release")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 15
    let (_, response) = try await httpSession.data(for: request)
    let status = try XCTUnwrap((response as? HTTPURLResponse)?.statusCode)
    XCTAssertTrue(
      [204, 409].contains(status), "Release must either release or observe a closed socket")
  }

  @MainActor
  private func traffic() async throws -> [[String: Any]] {
    var request = URLRequest(
      url: URL(string: "http://127.0.0.1:16485/__faults/annotations/traffic")!)
    request.timeoutInterval = 15
    let (data, response) = try await httpSession.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    let trace = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(
      trace["truncated"] as? Bool, false, "Absence proof requires complete bounded traffic")
    attach(data, name: "IPAD-E02-A03-real-transport-traffic", type: "public.json")
    return try XCTUnwrap(trace["items"] as? [[String: Any]])
  }

  private var profile: String {
    ProcessInfo.processInfo.environment["IPAD_E02_PROFILE"] ?? "pro13-portrait-light"
  }
  @MainActor private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "\(name)-\(profile)"
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
