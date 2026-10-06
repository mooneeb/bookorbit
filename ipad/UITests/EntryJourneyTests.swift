import Foundation
import XCTest

final class EntryJourneyTests: XCTestCase {
  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
  }

  override func tearDownWithError() throws {
    if let testRun, testRun.failureCount > 0 {
      let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
      attachment.name = "failure-\(name)"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    try super.tearDownWithError()
  }

  @MainActor
  func testIPADE01A01LocalLoginAndRelaunch() async throws {
    let app = launchAtServerEntry()
    connect(app)
    signIn(app)
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    XCTAssertTrue(app.staticTexts["Library book 00001"].exists)
    capture("IPAD-E01-A01-library-portrait")
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.tap()
    search.typeText("Orbit fixture\n")
    XCTAssertTrue(app.buttons["Orbit fixture"].firstMatch.waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["Library book 00001"].exists)
    app.buttons["Orbit fixture"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts["PDF"].waitForExistence(timeout: 10))
    capture("IPAD-E01-A01-book-detail")
    app.buttons["Done"].tap()
    XCUIDevice.shared.orientation = .landscapeLeft
    XCTAssertTrue(app.buttons["Orbit fixture"].firstMatch.waitForExistence(timeout: 10))
    capture("IPAD-E01-A01-search-landscape")
    XCUIDevice.shared.orientation = .portrait
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    try await revokeNativeSession()
    app.terminate()
    app.launch()
    XCTAssertTrue(
      app.staticTexts["Your session expired. Sign in again."].waitForExistence(timeout: 20))
    capture("IPAD-E01-A01-expired-session")
    signIn(app)
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    continueAfterFailure = true
    try app.performAccessibilityAudit()
    continueAfterFailure = false
    app.buttons["signOut"].tap()
    XCTAssertTrue(app.buttons["connectServer"].waitForExistence(timeout: 10))
  }

  @MainActor
  func testIPADE01A03ProductionPDFCurlAndResume() async throws {
    let login = try await metadataRequest(
      "auth/login", method: "POST",
      body: JSONSerialization.data(withJSONObject: [
        "username": "ipad-reader", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "Production PDF fixture",
      ]))
    let credentials = try XCTUnwrap(JSONSerialization.jsonObject(with: login) as? [String: Any])
    let token = try XCTUnwrap(credentials["accessToken"] as? String)
    _ = try await metadataRequest("books/files/1/progress", method: "DELETE", token: token)
    let app = launchAtServerEntry()
    connect(app)
    signIn(app, username: "ipad-reader")
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    let search = app.searchFields.firstMatch
    search.tap()
    search.typeText("Orbit\n")
    let book = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Orbit")).firstMatch
    XCTAssertTrue(book.waitForExistence(timeout: 10))
    book.tap()
    let read = app.buttons["readFile1"]
    XCTAssertTrue(read.waitForExistence(timeout: 10))
    capture("IPAD-E01-A03-production-pdf-book-detail")
    read.tap()
    XCTAssertTrue(app.staticTexts["Page 1 of 3"].waitForExistence(timeout: 15))
    let firstPassage = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@", "Orbit fixture: passage 1")
    ).firstMatch
    XCTAssertTrue(firstPassage.wait(for: \.isHittable, toEqual: true, timeout: 10))
    capture("IPAD-E01-A03-production-pdf-first-page")
    try app.performAccessibilityAudit()
    app.otherElements["pdfReader"].swipeLeft()
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Position saved"].waitForExistence(timeout: 10))
    let secondPassage = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@", "Orbit fixture: passage 2")
    ).firstMatch
    XCTAssertTrue(secondPassage.wait(for: \.isHittable, toEqual: true, timeout: 10))
    capture("IPAD-E01-A03-production-pdf-curled-page")
    XCUIDevice.shared.orientation = .landscapeLeft
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 5))
    XCTAssertTrue(secondPassage.isHittable)
    capture("IPAD-E01-A03-production-pdf-landscape")
    XCUIDevice.shared.orientation = .portrait
    app.buttons["Close reader"].tap()
    XCTAssertTrue(read.waitForExistence(timeout: 10))
    app.buttons["Done"].tap()
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    search.tap()
    search.typeText("Orbit\n")
    XCTAssertTrue(book.waitForExistence(timeout: 10))
    book.tap()
    XCTAssertTrue(read.waitForExistence(timeout: 10))
    read.tap()
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 15))
    XCTAssertTrue(secondPassage.wait(for: \.isHittable, toEqual: true, timeout: 10))
    capture("IPAD-E01-A03-production-pdf-resumed")
    try app.performAccessibilityAudit()
    let data = try await metadataRequest("books/files/1/progress", token: token)
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = "IPAD-E01-A03-production-pdf-public-progress"
    attachment.lifetime = .keepAlways
    add(attachment)
    let progress = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(progress["pageNumber"] as? Double, 2)
    app.buttons["Close reader"].tap()
    app.buttons["Done"].tap()
    app.buttons["signOut"].tap()
    _ = try await metadataRequest(
      "auth/logout", method: "POST",
      body: JSONSerialization.data(withJSONObject: [
        "refreshToken": try XCTUnwrap(credentials["refreshToken"] as? String)
      ]))
  }

  @MainActor
  func testIPADE01A03PDFPageNavigationAndResume() async throws {
    try await pdfProgressFault("snapshot-reset", method: "POST")
    addTeardownBlock {
      var request = URLRequest(
        url: URL(string: "http://localhost:16485/__faults/progress/snapshot-reset")!)
      request.httpMethod = "POST"
      request.timeoutInterval = 10
      let (_, response) = try await URLSession.shared.data(for: request)
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
    }
    let login = try await metadataRequest(
      "auth/login", method: "POST",
      body: JSONSerialization.data(withJSONObject: [
        "username": "ipad-reader", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "PDF page navigation fixture",
      ]))
    let credentials = try XCTUnwrap(JSONSerialization.jsonObject(with: login) as? [String: Any])
    let token = try XCTUnwrap(credentials["accessToken"] as? String)
    _ = try await metadataRequest("books/files/1/progress", method: "DELETE", token: token)
    let app = launchAtServerEntry()
    connect(app, serverURL: "http://localhost:16485")
    signIn(app, username: "ipad-reader")
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    let search = app.searchFields.firstMatch
    search.tap()
    search.typeText("Orbit\n")
    let book = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Orbit")).firstMatch
    XCTAssertTrue(book.waitForExistence(timeout: 10))
    book.tap()
    let read = app.buttons["readFile1"]
    XCTAssertTrue(read.wait(for: \.isHittable, toEqual: true, timeout: 10))
    read.tap()
    XCTAssertTrue(app.staticTexts["Page 1 of 3"].waitForExistence(timeout: 15))
    let navigate = app.buttons["pdfNavigate"]
    XCTAssertTrue(navigate.wait(for: \.isHittable, toEqual: true, timeout: 5))
    navigate.tap()
    let page = app.textFields["pdfDestinationPage"]
    XCTAssertTrue(page.waitForExistence(timeout: 5))
    let go = app.buttons["pdfGoToPage"]
    replaceText(page, with: "0", in: app)
    XCTAssertTrue(go.wait(for: \.isEnabled, toEqual: false, timeout: 5))
    XCTAssertTrue(app.staticTexts["Enter a page from 1 to 3."].exists)
    capture("IPAD-E01-A03-pdf-invalid-page")
    let hideKeyboard = app.buttons["pdfDismissKeyboard"]
    XCTAssertTrue(hideKeyboard.isHittable)
    hideKeyboard.tap()
    XCTAssertTrue(app.keyboards.firstMatch.wait(for: \.exists, toEqual: false, timeout: 5))
    capture("IPAD-E01-A03-pdf-invalid-page-keyboard-dismissed")
    try app.performAccessibilityAudit { issue in
      let attachment = XCTAttachment(
        string:
          "\(issue.detailedDescription)\n\(issue.element?.debugDescription ?? "No associated element")"
      )
      attachment.name = "IPAD-E01-A03-pdf-navigation-accessibility-issue"
      attachment.lifetime = .keepAlways
      self.add(attachment)
      return false
    }
    replaceText(page, with: "4", in: app)
    XCTAssertTrue(go.wait(for: \.isEnabled, toEqual: false, timeout: 5))
    replaceText(page, with: "3", in: app)
    XCTAssertTrue(go.wait(for: \.isEnabled, toEqual: true, timeout: 5))
    try await pdfProgressFault("arm", method: "POST")
    go.tap()
    XCTAssertTrue(page.wait(for: \.exists, toEqual: false, timeout: 5))
    XCTAssertTrue(app.staticTexts["Page 3 of 3"].waitForExistence(timeout: 10))
    let thirdPassage = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@", "Orbit fixture: passage 3")
    ).firstMatch
    XCTAssertTrue(thirdPassage.wait(for: \.isHittable, toEqual: true, timeout: 10))
    try await pdfProgressFault("held")
    XCTAssertTrue(app.staticTexts["Saving position…"].exists)
    capture("IPAD-E01-A03-pdf-navigation-position-pending")
    navigate.tap()
    XCTAssertTrue(page.waitForExistence(timeout: 5))
    XCTAssertEqual(page.value as? String, "3")
    app.buttons["Cancel"].tap()
    XCTAssertTrue(page.wait(for: \.exists, toEqual: false, timeout: 5))
    let pendingData = try await metadataRequest("books/files/1/progress", token: token)
    let pending = try XCTUnwrap(JSONSerialization.jsonObject(with: pendingData) as? [String: Any])
    XCTAssertTrue(pending["pageNumber"] is NSNull)
    XCTAssertEqual(pending["percentage"] as? Double, 0)
    XCTAssertTrue(app.staticTexts["Page 3 of 3"].exists)
    XCTAssertTrue(thirdPassage.isHittable)
    XCTAssertTrue(app.staticTexts["Saving position…"].exists)
    capture("IPAD-E01-A03-pdf-navigation-canceled-while-saving")
    try app.performAccessibilityAudit()
    try await pdfProgressFault("release", method: "POST")
    XCTAssertTrue(app.staticTexts["Position saved"].waitForExistence(timeout: 10))
    capture("IPAD-E01-A03-pdf-navigated-page")
    try app.performAccessibilityAudit()
    app.buttons["Close reader"].tap()
    XCTAssertTrue(read.waitForExistence(timeout: 10))
    app.buttons["Done"].tap()
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    search.tap()
    search.typeText("Orbit\n")
    XCTAssertTrue(book.waitForExistence(timeout: 10))
    book.tap()
    XCTAssertTrue(read.wait(for: \.isHittable, toEqual: true, timeout: 10))
    read.tap()
    XCTAssertTrue(app.staticTexts["Page 3 of 3"].waitForExistence(timeout: 15))
    XCTAssertTrue(thirdPassage.wait(for: \.isHittable, toEqual: true, timeout: 10))
    capture("IPAD-E01-A03-pdf-navigation-resumed")
    let data = try await metadataRequest("books/files/1/progress", token: token)
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = "IPAD-E01-A03-pdf-navigation-public-progress"
    attachment.lifetime = .keepAlways
    add(attachment)
    let progress = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(progress["pageNumber"] as? Double, 3)
    XCTAssertEqual(progress["percentage"] as? Double, 100)
    app.otherElements["pdfReader"].swipeRight()
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Position saved"].waitForExistence(timeout: 10))
    let secondPassage = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@", "Orbit fixture: passage 2")
    ).firstMatch
    XCTAssertTrue(secondPassage.wait(for: \.isHittable, toEqual: true, timeout: 10))
    capture("IPAD-E01-A03-pdf-gesture-after-navigation")
    app.buttons["Close reader"].tap()
    app.buttons["Done"].tap()
    app.buttons["signOut"].tap()
    _ = try await metadataRequest(
      "auth/logout", method: "POST",
      body: JSONSerialization.data(withJSONObject: [
        "refreshToken": try XCTUnwrap(credentials["refreshToken"] as? String)
      ]))
  }

  @MainActor
  func testIPADE01A04PDFSearchAndResume() async throws {
    let login = try await metadataRequest(
      "auth/login", method: "POST",
      body: JSONSerialization.data(withJSONObject: [
        "username": "ipad-reader", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "PDF search fixture",
      ]))
    let credentials = try XCTUnwrap(JSONSerialization.jsonObject(with: login) as? [String: Any])
    let token = try XCTUnwrap(credentials["accessToken"] as? String)
    _ = try await metadataRequest("books/files/1/progress", method: "DELETE", token: token)
    let app = launchAtServerEntry()
    connect(app)
    signIn(app, username: "ipad-reader")
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    let search = app.searchFields.firstMatch
    search.tap()
    search.typeText("Orbit\n")
    let book = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Orbit")).firstMatch
    XCTAssertTrue(book.waitForExistence(timeout: 10))
    book.tap()
    let read = app.buttons["readFile1"]
    XCTAssertTrue(read.wait(for: \.isHittable, toEqual: true, timeout: 10))
    read.tap()
    XCTAssertTrue(app.staticTexts["Page 1 of 3"].waitForExistence(timeout: 15))
    let openSearch = app.buttons["pdfSearch"]
    XCTAssertTrue(openSearch.wait(for: \.isHittable, toEqual: true, timeout: 5))
    openSearch.tap()
    let query = app.textFields["pdfSearchQuery"]
    XCTAssertTrue(query.waitForExistence(timeout: 5))
    let find = app.buttons["pdfFindText"]
    XCTAssertFalse(find.isEnabled)
    replaceText(query, with: "missing lunar sentence", in: app)
    find.tap()
    XCTAssertTrue(app.staticTexts["No matches"].waitForExistence(timeout: 10))
    capture("IPAD-E01-A04-pdf-search-no-matches")
    try app.performAccessibilityAudit()
    app.buttons["pdfClearSearch"].tap()
    let cleared = query.value as? String
    XCTAssertTrue(cleared == nil || cleared == "" || cleared == query.placeholderValue)
    XCTAssertFalse(find.isEnabled)
    XCTAssertFalse(app.staticTexts["No matches"].exists)
    replaceText(query, with: "PASSAGE 3", in: app)
    find.tap()
    let result = app.buttons["pdfSearchResult0"]
    XCTAssertTrue(result.wait(for: \.isHittable, toEqual: true, timeout: 10))
    XCTAssertTrue(result.label.contains("Page 3"))
    XCTAssertTrue(result.label.contains("passage 3"))
    capture("IPAD-E01-A04-pdf-search-result")
    try app.performAccessibilityAudit()
    result.tap()
    XCTAssertTrue(app.staticTexts["Page 3 of 3"].waitForExistence(timeout: 10))
    let thirdPassage = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@", "Orbit fixture: passage 3")
    ).firstMatch
    XCTAssertTrue(thirdPassage.wait(for: \.isHittable, toEqual: true, timeout: 10))
    XCTAssertTrue(app.staticTexts["Position saved"].waitForExistence(timeout: 10))
    capture("IPAD-E01-A04-pdf-search-opened-passage")
    try assertPDFSearchHighlight(in: app, page: 3, present: true, state: "opened-match")
    try app.performAccessibilityAudit()
    let data = try await metadataRequest("books/files/1/progress", token: token)
    let progress = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(progress["pageNumber"] as? Double, 3)
    XCTAssertEqual(progress["percentage"] as? Double, 100)
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = "IPAD-E01-A04-pdf-search-public-progress"
    attachment.lifetime = .keepAlways
    add(attachment)
    app.otherElements["pdfReader"].swipeRight()
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Position saved"].waitForExistence(timeout: 10))
    capture("IPAD-E01-A04-pdf-search-highlight-cleared-by-curl")
    try assertPDFSearchHighlight(in: app, page: 2, present: false, state: "turned-away")
    app.otherElements["pdfReader"].swipeLeft()
    XCTAssertTrue(app.staticTexts["Page 3 of 3"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Position saved"].waitForExistence(timeout: 10))
    capture("IPAD-E01-A04-pdf-search-return-after-curl")
    try assertPDFSearchHighlight(in: app, page: 3, present: false, state: "returned")
    app.buttons["Close reader"].tap()
    app.buttons["Done"].tap()
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    search.tap()
    search.typeText("Orbit\n")
    XCTAssertTrue(book.waitForExistence(timeout: 10))
    book.tap()
    XCTAssertTrue(read.wait(for: \.isHittable, toEqual: true, timeout: 10))
    read.tap()
    XCTAssertTrue(app.staticTexts["Page 3 of 3"].waitForExistence(timeout: 15))
    XCTAssertTrue(thirdPassage.wait(for: \.isHittable, toEqual: true, timeout: 10))
    capture("IPAD-E01-A04-pdf-search-resumed")
    try assertPDFSearchHighlight(in: app, page: 3, present: false, state: "resumed")
    app.otherElements["pdfReader"].swipeRight()
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Position saved"].waitForExistence(timeout: 10))
    capture("IPAD-E01-A04-pdf-search-subsequent-curl")
    try assertPDFSearchHighlight(in: app, page: 2, present: false, state: "subsequent-curl")
    app.buttons["Close reader"].tap()
    app.buttons["Done"].tap()
    app.buttons["signOut"].tap()
    _ = try await metadataRequest(
      "auth/logout", method: "POST",
      body: JSONSerialization.data(withJSONObject: [
        "refreshToken": try XCTUnwrap(credentials["refreshToken"] as? String)
      ]))
  }

  @MainActor
  func testIPADE01A04PDFContentsAndResume() async throws {
    let login = try await metadataRequest(
      "auth/login", method: "POST",
      body: JSONSerialization.data(withJSONObject: [
        "username": "ipad-reader", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "PDF contents fixture",
      ]))
    let credentials = try XCTUnwrap(JSONSerialization.jsonObject(with: login) as? [String: Any])
    let token = try XCTUnwrap(credentials["accessToken"] as? String)
    _ = try await metadataRequest("books/files/1/progress", method: "DELETE", token: token)
    let app = launchAtServerEntry()
    connect(app)
    signIn(app, username: "ipad-reader")
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    let search = app.searchFields.firstMatch
    search.tap()
    search.typeText("Orbit\n")
    let book = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Orbit")).firstMatch
    XCTAssertTrue(book.waitForExistence(timeout: 10))
    book.tap()
    let read = app.buttons["readFile1"]
    XCTAssertTrue(read.wait(for: \.isHittable, toEqual: true, timeout: 10))
    read.tap()
    XCTAssertTrue(app.staticTexts["Page 1 of 3"].waitForExistence(timeout: 15))
    let contents = app.buttons["pdfContents"]
    XCTAssertTrue(contents.wait(for: \.isHittable, toEqual: true, timeout: 5))
    contents.tap()
    let chapters = app.buttons["pdfOutline0"]
    XCTAssertTrue(chapters.wait(for: \.isHittable, toEqual: true, timeout: 5))
    XCTAssertTrue(chapters.label.contains("Orbit chapters"))
    capture("IPAD-E01-A04-pdf-contents-root")
    try app.performAccessibilityAudit()
    chapters.tap()
    let third = app.buttons["pdfOutline2"]
    XCTAssertTrue(third.wait(for: \.isHittable, toEqual: true, timeout: 5))
    XCTAssertTrue(third.label.contains("Third passage"))
    XCTAssertTrue(third.label.contains("Page 3"))
    capture("IPAD-E01-A04-pdf-contents-chapters")
    try app.performAccessibilityAudit()
    app.buttons["pdfContentsBack"].tap()
    XCTAssertTrue(chapters.wait(for: \.isHittable, toEqual: true, timeout: 5))
    chapters.tap()
    XCTAssertTrue(third.wait(for: \.isHittable, toEqual: true, timeout: 5))
    third.tap()
    XCTAssertTrue(app.staticTexts["Page 3 of 3"].waitForExistence(timeout: 10))
    let passage = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@", "Orbit fixture: passage 3")
    ).firstMatch
    XCTAssertTrue(passage.wait(for: \.isHittable, toEqual: true, timeout: 10))
    XCTAssertTrue(app.staticTexts["Position saved"].waitForExistence(timeout: 10))
    capture("IPAD-E01-A04-pdf-contents-opened-passage")
    try app.performAccessibilityAudit()
    let data = try await metadataRequest("books/files/1/progress", token: token)
    let progress = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(progress["pageNumber"] as? Double, 3)
    XCTAssertEqual(progress["percentage"] as? Double, 100)
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = "IPAD-E01-A04-pdf-contents-public-progress"
    attachment.lifetime = .keepAlways
    add(attachment)
    app.buttons["Close reader"].tap()
    app.buttons["Done"].tap()
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    search.tap()
    search.typeText("Orbit\n")
    XCTAssertTrue(book.waitForExistence(timeout: 10))
    book.tap()
    XCTAssertTrue(read.wait(for: \.isHittable, toEqual: true, timeout: 10))
    read.tap()
    XCTAssertTrue(app.staticTexts["Page 3 of 3"].waitForExistence(timeout: 15))
    XCTAssertTrue(passage.wait(for: \.isHittable, toEqual: true, timeout: 10))
    capture("IPAD-E01-A04-pdf-contents-resumed")
    app.otherElements["pdfReader"].swipeRight()
    XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Position saved"].waitForExistence(timeout: 10))
    let secondPassage = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@", "Orbit fixture: passage 2")
    ).firstMatch
    XCTAssertTrue(secondPassage.wait(for: \.isHittable, toEqual: true, timeout: 10))
    capture("IPAD-E01-A04-pdf-curl-after-contents")
    app.buttons["Close reader"].tap()
    app.buttons["Done"].tap()
    app.buttons["signOut"].tap()
    _ = try await metadataRequest(
      "auth/logout", method: "POST",
      body: JSONSerialization.data(withJSONObject: [
        "refreshToken": try XCTUnwrap(credentials["refreshToken"] as? String)
      ]))
  }

  @MainActor
  private func pdfProgressFault(_ operation: String, method: String = "GET") async throws {
    var request = URLRequest(
      url: URL(string: "http://localhost:16485/__faults/progress/\(operation)")!)
    request.httpMethod = method
    request.timeoutInterval = 15
    let (data, response) = try await URLSession.shared.data(for: request)
    XCTAssertTrue((200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0))
    if method == "GET" { XCTAssertEqual(String(data: data, encoding: .utf8), "held") }
  }

  @MainActor
  func testIPADE01A02CreateCollectionAndReopen() throws {
    let app = launchAtServerEntry()
    connect(app)
    signIn(app)
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    let create = app.buttons["newCollection"]
    XCTAssertTrue(create.waitForExistence(timeout: 5))
    create.tap()
    let name = app.textFields["collectionName"]
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    name.tap()
    name.typeText("Native reading collection")
    app.buttons["saveCollection"].tap()
    XCTAssertTrue(app.staticTexts["0 books"].waitForExistence(timeout: 10))
    capture("IPAD-E01-A02-created-collection")
    create.tap()
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    name.tap()
    name.typeText("Native reading collection")
    app.buttons["saveCollection"].tap()
    XCTAssertTrue(
      app.staticTexts["A collection with this name already exists. Choose another name."]
        .waitForExistence(timeout: 10))
    capture("IPAD-E01-A02-collection-name-conflict")
    replaceText(name, with: "Native reading backup", in: app)
    app.buttons["saveCollection"].tap()
    XCTAssertTrue(app.staticTexts["0 books"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.navigationBars["Native reading backup"].waitForExistence(timeout: 5))
    let collectionSearch = app.textFields["collectionSearch"]
    XCTAssertTrue(collectionSearch.wait(for: \.isHittable, toEqual: true, timeout: 10))
    replaceText(collectionSearch, with: "", in: app)
    collectionSearch.typeText("\n")
    XCTAssertTrue(app.buttons["Native reading collection"].waitForExistence(timeout: 10))
    app.buttons["All books"].tap()
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.tap()
    search.typeText("Orbit fixture\n")
    let book = app.buttons["Orbit fixture"].firstMatch
    XCTAssertTrue(book.waitForExistence(timeout: 10))
    book.tap()
    let add = app.buttons["addToCollection"]
    XCTAssertTrue(add.waitForExistence(timeout: 5))
    add.tap()
    let choice = app.buttons.matching(identifier: "collectionChoice")
      .matching(NSPredicate(format: "label == %@", "Native reading collection")).firstMatch
    XCTAssertTrue(choice.waitForExistence(timeout: 10))
    choice.tap()
    XCTAssertTrue(
      app.staticTexts["Added to Native reading collection"].waitForExistence(timeout: 10))
    app.buttons["Done"].tap()
    app.buttons["Native reading collection"].tap()
    XCTAssertTrue(app.staticTexts["1 book"].waitForExistence(timeout: 10))
    XCTAssertTrue(book.exists)
    let detailNavigation = app.navigationBars["Native reading collection"]
    XCTAssertTrue(detailNavigation.waitForExistence(timeout: 5))
    let detailTitle = detailNavigation.staticTexts["Native reading collection"]
    XCTAssertTrue(detailTitle.waitForExistence(timeout: 5))
    XCTAssertGreaterThanOrEqual(detailTitle.frame.minX, app.buttons["All books"].frame.maxX)
    capture("IPAD-E01-A02-collection-membership")
    app.terminate()
    app.launch()
    let collection = app.buttons["Native reading collection"]
    XCTAssertTrue(collection.waitForExistence(timeout: 20))
    collection.tap()
    XCTAssertTrue(app.staticTexts["1 book"].waitForExistence(timeout: 10))
    XCTAssertTrue(book.exists)
    app.buttons["signOut"].tap()
    XCTAssertTrue(app.buttons["connectServer"].waitForExistence(timeout: 10))
  }

  @MainActor
  func testIPADE01A02EditMetadataAndReopen() throws {
    let app = launchAtServerEntry()
    connect(app)
    signIn(app)
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.tap()
    search.typeText("Orbit fixture\n")
    let book = app.buttons["Orbit fixture"].firstMatch
    XCTAssertTrue(book.waitForExistence(timeout: 10))
    book.tap()
    let edit = app.buttons["editMetadata"]
    XCTAssertTrue(edit.waitForExistence(timeout: 5))
    edit.tap()
    let title = app.descendants(matching: .any)["metadataTitle"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    replaceMetadataText(title, with: "Orbit corrected", in: app)
    let subtitle = app.descendants(matching: .any)["metadataSubtitle"]
    subtitle.tap()
    subtitle.typeText("A native correction")
    let description = app.textViews["metadataDescription"]
    description.tap()
    description.typeText("Description preserved while clearing the subtitle.")
    capture("IPAD-E01-A02-metadata-editor")
    app.buttons["saveMetadata"].tap()
    XCTAssertTrue(edit.wait(for: \.isHittable, toEqual: true, timeout: 10))
    XCTAssertTrue(app.staticTexts["Orbit corrected"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["A native correction"].exists)
    XCTAssertTrue(app.staticTexts["Description preserved while clearing the subtitle."].exists)
    capture("IPAD-E01-A02-metadata-saved")
    edit.tap()
    XCTAssertTrue(subtitle.waitForExistence(timeout: 5))
    replaceMetadataText(subtitle, with: "", in: app)
    app.buttons["saveMetadata"].tap()
    XCTAssertTrue(edit.wait(for: \.isHittable, toEqual: true, timeout: 10))
    XCTAssertTrue(app.staticTexts["Orbit corrected"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["A native correction"].exists)
    XCTAssertTrue(app.staticTexts["Description preserved while clearing the subtitle."].exists)
    capture("IPAD-E01-A02-metadata-cleared")
    app.buttons["Done"].tap()
    XCTAssertTrue(app.staticTexts["0 books"].waitForExistence(timeout: 10))
    XCTAssertFalse(book.exists)
    capture("IPAD-E01-A02-metadata-search-refreshed")
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    search.tap()
    search.typeText("Orbit corrected\n")
    let corrected = app.buttons["Orbit corrected"].firstMatch
    XCTAssertTrue(corrected.waitForExistence(timeout: 10))
    corrected.tap()
    XCTAssertTrue(app.staticTexts["Orbit corrected"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["A native correction"].exists)
    app.buttons["Done"].tap()
    app.buttons["signOut"].tap()
    XCTAssertTrue(app.buttons["connectServer"].waitForExistence(timeout: 10))
  }

  @MainActor
  func testIPADE01A02EditBibliographicMetadataAndReopen() async throws {
    let login = try await metadataRequest(
      "auth/login", method: "POST",
      body: JSONSerialization.data(withJSONObject: [
        "username": "ipad-editor", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "Bibliographic fixture control",
      ]))
    let credentials = try XCTUnwrap(JSONSerialization.jsonObject(with: login) as? [String: Any])
    let token = try XCTUnwrap(credentials["accessToken"] as? String)
    _ = try await metadataRequest(
      "books/3/metadata-and-locks", method: "PATCH", token: token,
      body: JSONSerialization.data(withJSONObject: [
        "metadata": [
          "publisher": "Original imprint", "publishedDate": "2020-01-01", "publishedYear": 2020,
          "pageCount": 120, "language": "urd", "isbn10": "0000000000", "isbn13": "0000000000000",
          "authors": ["Original author"], "genres": ["Original genre"], "tags": ["Original tag"],
        ], "lockedFields": [],
      ]))
    let app = launchAtServerEntry()
    connect(app)
    signIn(app, username: "ipad-editor")
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    let search = app.searchFields.firstMatch
    search.tap()
    search.typeText("Library book 00002\n")
    XCTAssertTrue(app.staticTexts["1 book"].waitForExistence(timeout: 10))
    let book = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Library book 00002")
    ).firstMatch
    XCTAssertTrue(book.waitForExistence(timeout: 10))
    book.tap()
    let edit = app.buttons["editMetadata"]
    XCTAssertTrue(edit.waitForExistence(timeout: 10))
    edit.tap()
    let fields = [
      ("metadataPublisher", "Orbit Press"), ("metadataPublishedYear", "2024"),
      ("metadataPublishedDate", "2024-02-29"), ("metadataPageCount", "321"),
      ("metadataLanguage", "eng"), ("metadataISBN10", "0140449138"),
      ("metadataISBN13", "9780140449136"), ("metadataAuthors", "Reader, One\nLéa Noor"),
      ("metadataGenres", "Science Fiction"), ("metadataTags", "Imported\nRead soon"),
    ]
    for (identifier, value) in fields {
      let field = app.descendants(matching: .any)[identifier]
      revealMetadataElement(field, in: app)
      replaceMetadataText(field, with: value, in: app)
      app.buttons["metadataDismissKeyboard"].tap()
      if identifier == "metadataPublishedDate" {
        let publicationLock = app.switches["metadataPublishedDateLock"].switches.firstMatch
        revealMetadataElement(publicationLock, in: app)
        publicationLock.tap()
        XCTAssertFalse(app.descendants(matching: .any)["metadataPublishedYear"].isEnabled)
      }
      if identifier == "metadataISBN13" { capture("IPAD-E01-A02-bibliographic-publication") }
    }
    capture("IPAD-E01-A02-bibliographic-editor")
    app.buttons["saveMetadata"].tap()
    XCTAssertTrue(edit.wait(for: \.isHittable, toEqual: true, timeout: 10))
    let data = try await metadataRequest("books/3", token: token)
    let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(saved["publisher"] as? String, "Orbit Press")
    XCTAssertEqual(saved["publishedDate"] as? String, "2024-02-29")
    XCTAssertEqual(saved["publishedYear"] as? Int, 2024)
    XCTAssertEqual(saved["pageCount"] as? Int, 321)
    XCTAssertEqual(saved["language"] as? String, "eng")
    XCTAssertEqual(saved["isbn10"] as? String, "0140449138")
    XCTAssertEqual(saved["isbn13"] as? String, "9780140449136")
    XCTAssertEqual(saved["lockedFields"] as? [String], ["publishedYear"])
    XCTAssertEqual(
      (saved["authors"] as? [[String: Any]])?.compactMap { $0["name"] as? String },
      ["Reader, One", "Léa Noor"])
    XCTAssertEqual(saved["genres"] as? [String], ["Science Fiction"])
    XCTAssertEqual(saved["tags"] as? [String], ["Imported", "Read soon"])
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = "IPAD-E01-A02-bibliographic-public-record"
    attachment.lifetime = .keepAlways
    add(attachment)
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    search.tap()
    search.typeText("Library book 00002\n")
    XCTAssertTrue(app.staticTexts["1 book"].waitForExistence(timeout: 10))
    XCTAssertTrue(book.waitForExistence(timeout: 10))
    book.tap()
    XCTAssertTrue(edit.waitForExistence(timeout: 10))
    edit.tap()
    for (identifier, value) in fields {
      let field = app.descendants(matching: .any)[identifier]
      revealMetadataElement(field, in: app)
      XCTAssertEqual(field.value as? String, value)
    }
    capture("IPAD-E01-A02-bibliographic-reopened")
    app.buttons["Cancel"].tap()
    app.buttons["Done"].tap()
    app.buttons["signOut"].tap()
    _ = try await metadataRequest(
      "auth/logout", method: "POST",
      body: JSONSerialization.data(withJSONObject: [
        "refreshToken": try XCTUnwrap(credentials["refreshToken"] as? String)
      ]))
  }

  @MainActor
  func testIPADE01A05MetadataRelationNameValidation() async throws {
    let login = try await metadataRequest(
      "auth/login", method: "POST",
      body: JSONSerialization.data(withJSONObject: [
        "username": "ipad-editor", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "Relation name fixture control",
      ]))
    let credentials = try XCTUnwrap(JSONSerialization.jsonObject(with: login) as? [String: Any])
    let token = try XCTUnwrap(credentials["accessToken"] as? String)
    _ = try await metadataRequest(
      "books/5/metadata-and-locks", method: "PATCH", token: token,
      body: JSONSerialization.data(withJSONObject: [
        "metadata": ["authors": [], "genres": [], "tags": []], "lockedFields": [],
      ]))
    let app = launchAtServerEntry()
    connect(app)
    signIn(app, username: "ipad-editor")
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    let search = app.searchFields.firstMatch
    search.tap()
    search.typeText("Library book 00004\n")
    XCTAssertTrue(app.staticTexts["1 book"].waitForExistence(timeout: 10))
    let book = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Library book 00004")
    ).firstMatch
    XCTAssertTrue(book.waitForExistence(timeout: 10))
    book.tap()
    let edit = app.buttons["editMetadata"]
    XCTAssertTrue(edit.waitForExistence(timeout: 10))
    edit.tap()
    let cases = [
      ("metadataAuthors", "e\u{0301}", 250, "Each author must be no longer than 500 characters."),
      ("metadataGenres", "😀", 200, "Each genre must be no longer than 200 characters."),
      ("metadataTags", "☕\u{FE0F}", 100, "Each tag must be no longer than 200 characters."),
    ]
    let save = app.buttons["saveMetadata"]
    for (identifier, character, count, message) in cases {
      let field = app.descendants(matching: .any)[identifier]
      replaceMetadataText(field, with: String(repeating: character, count: count + 1), in: app)
      XCTAssertTrue(save.wait(for: \.isEnabled, toEqual: false, timeout: 5))
      XCTAssertTrue(app.staticTexts[message].exists)
      app.buttons["metadataDismissKeyboard"].tap()
      capture("IPAD-E01-A05-invalid-\(identifier)")
      replaceMetadataText(field, with: String(repeating: character, count: count), in: app)
      XCTAssertTrue(save.wait(for: \.isEnabled, toEqual: true, timeout: 5))
      XCTAssertFalse(app.staticTexts[message].exists)
      app.buttons["metadataDismissKeyboard"].tap()
    }
    capture("IPAD-E01-A05-valid-relation-name-boundaries")
    continueAfterFailure = true
    try app.performAccessibilityAudit()
    continueAfterFailure = false
    app.buttons["Cancel"].tap()
    XCTAssertTrue(edit.wait(for: \.isHittable, toEqual: true, timeout: 10))
    let data = try await metadataRequest("books/5", token: token)
    let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertTrue((saved["authors"] as? [[String: Any]])?.isEmpty == true)
    XCTAssertEqual(saved["genres"] as? [String], [])
    XCTAssertEqual(saved["tags"] as? [String], [])
    app.buttons["Done"].tap()
    app.buttons["signOut"].tap()
    _ = try await metadataRequest(
      "auth/logout", method: "POST",
      body: JSONSerialization.data(withJSONObject: [
        "refreshToken": try XCTUnwrap(credentials["refreshToken"] as? String)
      ]))
  }

  @MainActor
  func testIPADE01A02ClearBibliographicMetadataAndReopen() async throws {
    let login = try await metadataRequest(
      "auth/login", method: "POST",
      body: JSONSerialization.data(withJSONObject: [
        "username": "ipad-editor", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "Clearing fixture control",
      ]))
    let credentials = try XCTUnwrap(JSONSerialization.jsonObject(with: login) as? [String: Any])
    let token = try XCTUnwrap(credentials["accessToken"] as? String)
    _ = try await metadataRequest(
      "books/7/metadata-and-locks", method: "PATCH", token: token,
      body: JSONSerialization.data(withJSONObject: [
        "metadata": [
          "publisher": "Clear this imprint", "publishedDate": "2020-01-01", "publishedYear": 2020,
          "pageCount": 120, "language": "eng", "isbn10": "0000000000", "isbn13": "0000000000000",
          "authors": ["Clear this author"], "genres": ["Clear this genre"],
          "tags": ["Clear this tag"],
        ], "lockedFields": [],
      ]))
    let app = launchAtServerEntry()
    connect(app)
    signIn(app, username: "ipad-editor")
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    let search = app.searchFields.firstMatch
    search.tap()
    search.typeText("Library book 00006\n")
    XCTAssertTrue(app.staticTexts["1 book"].waitForExistence(timeout: 10))
    let book = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Library book 00006")
    ).firstMatch
    XCTAssertTrue(book.waitForExistence(timeout: 10))
    book.tap()
    let edit = app.buttons["editMetadata"]
    XCTAssertTrue(edit.waitForExistence(timeout: 10))
    edit.tap()
    let identifiers = [
      "metadataPublisher", "metadataPublishedDate", "metadataPublishedYear", "metadataPageCount",
      "metadataLanguage", "metadataISBN10", "metadataISBN13", "metadataAuthors", "metadataGenres",
      "metadataTags",
    ]
    for identifier in identifiers {
      let field = app.descendants(matching: .any)[identifier]
      let clear = app.buttons["\(identifier)Clear"]
      revealMetadataElement(clear, in: app)
      XCTAssertTrue(clear.isEnabled)
      clear.tap()
      let value = field.value as? String
      XCTAssertTrue(value == nil || value == "" || value == field.placeholderValue)
      XCTAssertFalse(clear.isEnabled)
      if identifier == "metadataPublishedDate" {
        XCTAssertEqual(app.textFields["metadataPublishedYear"].value as? String, "2020")
      }
      if identifier == "metadataISBN13" {
        capture("IPAD-E01-A02-cleared-publication")
        continueAfterFailure = true
        try app.performAccessibilityAudit()
        continueAfterFailure = false
      }
    }
    capture("IPAD-E01-A02-cleared-relations")
    app.buttons["saveMetadata"].tap()
    XCTAssertTrue(edit.wait(for: \.isHittable, toEqual: true, timeout: 10))
    let data = try await metadataRequest("books/7", token: token)
    let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    for key in [
      "publisher", "publishedDate", "publishedYear", "pageCount", "language", "isbn10", "isbn13",
    ] {
      XCTAssertTrue(saved[key] is NSNull, "Cleared \(key) must persist as null")
    }
    XCTAssertEqual(saved["title"] as? String, "Library book 00006")
    XCTAssertTrue((saved["authors"] as? [[String: Any]])?.isEmpty == true)
    XCTAssertEqual(saved["genres"] as? [String], [])
    XCTAssertEqual(saved["tags"] as? [String], [])
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = "IPAD-E01-A02-cleared-public-record"
    attachment.lifetime = .keepAlways
    add(attachment)
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    search.tap()
    search.typeText("Library book 00006\n")
    XCTAssertTrue(app.staticTexts["1 book"].waitForExistence(timeout: 10))
    XCTAssertTrue(book.waitForExistence(timeout: 10))
    book.tap()
    XCTAssertTrue(edit.waitForExistence(timeout: 10))
    edit.tap()
    for identifier in identifiers {
      let field = app.descendants(matching: .any)[identifier]
      revealMetadataElement(field, in: app)
      let value = field.value as? String
      XCTAssertTrue(value == nil || value == "" || value == field.placeholderValue)
      XCTAssertFalse(app.buttons["\(identifier)Clear"].isEnabled)
    }
    capture("IPAD-E01-A02-cleared-reopened")
    app.buttons["Cancel"].tap()
    app.buttons["Done"].tap()
    app.buttons["signOut"].tap()
    _ = try await metadataRequest(
      "auth/logout", method: "POST",
      body: JSONSerialization.data(withJSONObject: [
        "refreshToken": try XCTUnwrap(credentials["refreshToken"] as? String)
      ]))
  }

  @MainActor
  private func replaceMetadataText(
    _ field: XCUIElement, with text: String, in app: XCUIApplication
  ) {
    let existing = field.value as? String ?? ""
    if !existing.isEmpty && existing != field.placeholderValue {
      let clear = app.buttons["\(field.identifier)Clear"]
      XCTAssertTrue(clear.exists || clear.waitForExistence(timeout: 5))
      revealMetadataElement(clear, in: app)
      clear.tap()
      let value = field.value as? String
      XCTAssertTrue(value == nil || value == "" || value == field.placeholderValue)
    }
    revealMetadataElement(field, in: app)
    field.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    revealMetadataElement(field, in: app)
    field.tap()
    field.typeText(text)
    XCTAssertEqual(field.value as? String, text)
  }

  @MainActor
  private func revealMetadataElement(_ element: XCUIElement, in app: XCUIApplication) {
    XCTAssertTrue(element.exists || element.waitForExistence(timeout: 5))
    let form = app.scrollViews.containing(.any, identifier: "metadataTitle").firstMatch
    for _ in 0..<12 {
      let window = app.windows.firstMatch.frame
      let heading = app.staticTexts["metadataHeading"]
      let top = max(
        window.minY, heading.exists ? heading.frame.maxY : app.navigationBars.firstMatch.frame.maxY)
      let bottom = min(window.maxY, app.buttons["saveMetadata"].frame.minY)
      let visible = CGRect(x: window.minX, y: top, width: window.width, height: bottom - top)
      if element.isHittable && visible.contains(element.frame) { return }
      let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.6))
      let end = form.coordinate(
        withNormalizedOffset: CGVector(dx: 0.01, dy: element.frame.minY < top ? 0.85 : 0.35))
      start.press(forDuration: 0.01, thenDragTo: end)
    }
    XCTFail("Metadata control is not fully visible: \(element.identifier)")
  }

  @MainActor
  private func metadataRequest(
    _ path: String, method: String = "GET", token: String? = nil, body: Data? = nil
  ) async throws -> Data {
    var request = URLRequest(url: URL(string: "http://localhost:16482/api/v1/\(path)")!)
    request.httpMethod = method
    request.timeoutInterval = 15
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = body
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    XCTAssertTrue((200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0))
    return data
  }

  @MainActor
  func testIPADE01A02MetadataLocksAndReopen() throws {
    let app = launchAtServerEntry()
    connect(app)
    signIn(app)
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    let search = app.searchFields.firstMatch
    search.tap()
    search.typeText("Orbit\n")
    let book = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Orbit")).firstMatch
    XCTAssertTrue(book.waitForExistence(timeout: 10))
    book.tap()
    let edit = app.buttons["editMetadata"]
    XCTAssertTrue(edit.waitForExistence(timeout: 10))
    edit.tap()
    let title = app.descendants(matching: .any)["metadataTitle"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    let lock = app.switches["metadataTitleLock"]
    XCTAssertTrue(lock.waitForExistence(timeout: 5))
    let control = lock.switches.firstMatch
    XCTAssertTrue(control.waitForExistence(timeout: 5))
    control.tap()
    XCTAssertTrue(title.wait(for: \.isEnabled, toEqual: false, timeout: 5))
    app.buttons["saveMetadata"].tap()
    XCTAssertTrue(edit.wait(for: \.isHittable, toEqual: true, timeout: 10))
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    search.tap()
    search.typeText("Orbit\n")
    XCTAssertTrue(book.waitForExistence(timeout: 10))
    book.tap()
    XCTAssertTrue(edit.waitForExistence(timeout: 10))
    edit.tap()
    XCTAssertTrue(lock.waitForExistence(timeout: 5))
    XCTAssertEqual(lock.value as? String, "1")
    XCTAssertFalse(title.isEnabled)
    capture("IPAD-E01-A02-metadata-lock-reopened")
    app.buttons["Cancel"].tap()
    app.buttons["Done"].tap()
    app.buttons["signOut"].tap()
    XCTAssertTrue(app.buttons["connectServer"].waitForExistence(timeout: 10))
  }

  @MainActor
  func testIPADE01A05CoverLocksAndReadOnlyControls() async throws {
    let login = try await metadataRequest(
      "auth/login", method: "POST",
      body: JSONSerialization.data(withJSONObject: [
        "username": "ipad-editor", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "Cover locks fixture control",
      ]))
    let credentials = try XCTUnwrap(JSONSerialization.jsonObject(with: login) as? [String: Any])
    let token = try XCTUnwrap(credentials["accessToken"] as? String)
    _ = try await metadataRequest(
      "books/6/metadata-and-locks", method: "PATCH", token: token,
      body: JSONSerialization.data(withJSONObject: ["metadata": [:], "lockedFields": ["cover"]]))
    let originalData = try await metadataRequest("books/6", token: token)
    let original = try XCTUnwrap(JSONSerialization.jsonObject(with: originalData) as? [String: Any])

    var app = launchAtServerEntry()
    connect(app)
    signIn(app, username: "ipad-reader")
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    var search = app.searchFields.firstMatch
    search.tap()
    search.typeText("Library book 00005\n")
    var book = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Library book 00005")
    ).firstMatch
    XCTAssertTrue(book.waitForExistence(timeout: 10))
    book.tap()
    XCTAssertTrue(app.staticTexts["M4A"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["editCovers"].exists)
    XCTAssertFalse(app.buttons["editMetadata"].exists)
    capture("IPAD-E01-A05-read-only-cover-controls")
    app.buttons["Done"].tap()
    app.buttons["signOut"].tap()

    app = launchAtServerEntry()
    connect(app)
    signIn(app, username: "ipad-editor")
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    search = app.searchFields.firstMatch
    search.tap()
    search.typeText("Library book 00005\n")
    book =
      app.buttons.matching(
        NSPredicate(format: "label BEGINSWITH %@", "Library book 00005")
      ).firstMatch
    XCTAssertTrue(book.waitForExistence(timeout: 10))
    book.tap()
    XCTAssertTrue(app.buttons["editCovers"].waitForExistence(timeout: 10))
    app.buttons["editCovers"].tap()
    XCTAssertTrue(app.buttons["chooseEbookCover"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["chooseEbookCover"].isEnabled)
    XCTAssertTrue(app.buttons["chooseAudioCover"].isEnabled)
    XCTAssertTrue(
      app.staticTexts["This cover is locked. Unlock it in metadata before editing."].exists)
    capture("IPAD-E01-A05-ebook-cover-locked")
    app.buttons["closeCoverEditor"].tap()
    XCTAssertTrue(app.buttons["editMetadata"].waitForExistence(timeout: 10))
    app.buttons["editMetadata"].tap()
    let ebookLock = app.switches["metadataCoverLock"].switches.firstMatch
    let audioLock = app.switches["metadataAudioCoverLock"].switches.firstMatch
    revealMetadataElement(ebookLock, in: app)
    XCTAssertEqual(ebookLock.value as? String, "1")
    ebookLock.tap()
    revealMetadataElement(audioLock, in: app)
    XCTAssertEqual(audioLock.value as? String, "0")
    audioLock.tap()
    capture("IPAD-E01-A05-cover-locks-staged")
    let staged = try await metadataRequest("books/6", token: token)
    let stagedRecord = try XCTUnwrap(JSONSerialization.jsonObject(with: staged) as? [String: Any])
    XCTAssertEqual(stagedRecord["lockedFields"] as? [String], ["cover"])
    continueAfterFailure = true
    try app.performAccessibilityAudit()
    continueAfterFailure = false
    app.buttons["saveMetadata"].tap()
    XCTAssertTrue(app.buttons["editCovers"].waitForExistence(timeout: 15))
    let savedData = try await metadataRequest("books/6", token: token)
    let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: savedData) as? [String: Any])
    XCTAssertEqual(saved["lockedFields"] as? [String], ["audioCover"])
    XCTAssertEqual(saved["covers"] as? NSDictionary, original["covers"] as? NSDictionary)

    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    search.tap()
    search.typeText("Library book 00005\n")
    XCTAssertTrue(book.waitForExistence(timeout: 10))
    book.tap()
    XCTAssertTrue(app.buttons["editCovers"].waitForExistence(timeout: 10))
    app.buttons["editCovers"].tap()
    XCTAssertTrue(app.buttons["chooseEbookCover"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["chooseEbookCover"].isEnabled)
    XCTAssertFalse(app.buttons["chooseAudioCover"].isEnabled)
    capture("IPAD-E01-A05-audio-cover-lock-reopened")
    continueAfterFailure = true
    try app.performAccessibilityAudit()
    continueAfterFailure = false
    app.buttons["closeCoverEditor"].tap()
    XCTAssertTrue(app.buttons["editMetadata"].waitForExistence(timeout: 10))
    app.buttons["editMetadata"].tap()
    revealMetadataElement(ebookLock, in: app)
    XCTAssertEqual(ebookLock.value as? String, "0")
    revealMetadataElement(audioLock, in: app)
    XCTAssertEqual(audioLock.value as? String, "1")
    app.buttons["Cancel"].tap()
    app.buttons["Done"].tap()
    app.buttons["signOut"].tap()
    _ = try await metadataRequest(
      "books/6/metadata-and-locks", method: "PATCH", token: token,
      body: JSONSerialization.data(withJSONObject: ["metadata": [:], "lockedFields": []]))
    _ = try await metadataRequest(
      "auth/logout", method: "POST",
      body: JSONSerialization.data(withJSONObject: [
        "refreshToken": try XCTUnwrap(credentials["refreshToken"] as? String)
      ]))
  }

  @MainActor
  func testIPADE01A05ReadOnlyMetadataControls() throws {
    let app = launchAtServerEntry()
    connect(app)
    signIn(app, username: "ipad-reader")
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    let search = app.searchFields.firstMatch
    search.tap()
    search.typeText("Orbit\n")
    let book = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Orbit")).firstMatch
    XCTAssertTrue(book.waitForExistence(timeout: 10))
    book.tap()
    XCTAssertTrue(app.staticTexts["PDF"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["editMetadata"].exists)
    capture("IPAD-E01-A05-read-only-record")
    app.buttons["Done"].tap()
    app.buttons["signOut"].tap()
    XCTAssertTrue(app.buttons["connectServer"].waitForExistence(timeout: 10))
  }

  @MainActor
  func testIPADE01A05PermittedEditorMetadataControls() throws {
    let app = launchAtServerEntry()
    connect(app)
    signIn(app, username: "ipad-editor")
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    let search = app.searchFields.firstMatch
    search.tap()
    search.typeText("Orbit\n")
    let book = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Orbit")).firstMatch
    XCTAssertTrue(book.waitForExistence(timeout: 10))
    book.tap()
    let edit = app.buttons["editMetadata"]
    XCTAssertTrue(edit.waitForExistence(timeout: 10))
    edit.tap()
    XCTAssertTrue(app.descendants(matching: .any)["metadataTitle"].waitForExistence(timeout: 5))
    capture("IPAD-E01-A05-permitted-editor")
    continueAfterFailure = true
    try app.performAccessibilityAudit()
    continueAfterFailure = false
    let descriptionLock = app.switches["metadataDescriptionLock"].switches.firstMatch
    revealMetadataElement(descriptionLock, in: app)
    XCTAssertTrue(descriptionLock.wait(for: \.isHittable, toEqual: true, timeout: 5))
    capture("IPAD-E01-A05-editor-description-lock")
    continueAfterFailure = true
    try app.performAccessibilityAudit()
    continueAfterFailure = false
    app.buttons["Cancel"].tap()
    app.buttons["Done"].tap()
    app.buttons["signOut"].tap()
    XCTAssertTrue(app.buttons["connectServer"].waitForExistence(timeout: 10))
  }

  @MainActor
  func testIPADE01A05MetadataUnicodeValidation() throws {
    let app = launchAtServerEntry()
    connect(app)
    signIn(app, username: "ipad-editor")
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    let search = app.searchFields.firstMatch
    search.tap()
    search.typeText("Orbit\n")
    let book = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Orbit")).firstMatch
    XCTAssertTrue(book.waitForExistence(timeout: 10))
    book.tap()
    let edit = app.buttons["editMetadata"]
    XCTAssertTrue(edit.wait(for: \.isHittable, toEqual: true, timeout: 10))
    edit.tap()
    let title = app.descendants(matching: .any)["metadataTitle"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    let originalTitle = title.value as? String
    XCTAssertNotNil(originalTitle)
    if !title.isEnabled {
      app.switches["metadataTitleLock"].switches.firstMatch.tap()
      XCTAssertTrue(title.wait(for: \.isEnabled, toEqual: true, timeout: 5))
    }
    replaceMetadataText(title, with: String(repeating: "e\u{0301}", count: 501), in: app)
    let save = app.buttons["saveMetadata"]
    XCTAssertTrue(save.wait(for: \.isEnabled, toEqual: false, timeout: 5))
    XCTAssertTrue(
      app.staticTexts["Title and subtitle must be no longer than 1,000 characters."].exists)
    capture("IPAD-E01-A05-invalid-unicode-title")
    app.buttons["Cancel"].tap()
    XCTAssertTrue(edit.wait(for: \.isHittable, toEqual: true, timeout: 5))
    edit.tap()
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    XCTAssertEqual(title.value as? String, originalTitle)
    if !title.isEnabled {
      app.switches["metadataTitleLock"].switches.firstMatch.tap()
      XCTAssertTrue(title.wait(for: \.isEnabled, toEqual: true, timeout: 5))
    }
    replaceMetadataText(title, with: String(repeating: "☕\u{FE0F}", count: 750), in: app)
    XCTAssertTrue(save.wait(for: \.isEnabled, toEqual: false, timeout: 5))
    XCTAssertTrue(
      app.staticTexts["Title and subtitle must be no longer than 1,000 characters."].exists)
    XCTAssertLessThanOrEqual(
      title.frame.height, 140, "Four editable lines must leave the form reachable")
    XCTAssertLessThanOrEqual(
      app.switches["metadataTitleLock"].frame.minY - title.frame.minY, 180,
      "The title lock must follow the four-line editor without excess blank space")
    capture("IPAD-E01-A05-invalid-presentation-title")
    let hideKeyboard = app.buttons["metadataDismissKeyboard"]
    XCTAssertTrue(hideKeyboard.isHittable)
    hideKeyboard.tap()
    XCTAssertTrue(app.keyboards.firstMatch.wait(for: \.exists, toEqual: false, timeout: 5))
    capture("IPAD-E01-A05-invalid-title-keyboard-dismissed")
    continueAfterFailure = true
    try app.performAccessibilityAudit()
    continueAfterFailure = false
    app.buttons["Cancel"].tap()
    XCTAssertTrue(edit.wait(for: \.isHittable, toEqual: true, timeout: 5))
    edit.tap()
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    XCTAssertEqual(title.value as? String, originalTitle)
    if !title.isEnabled {
      app.switches["metadataTitleLock"].switches.firstMatch.tap()
      XCTAssertTrue(title.wait(for: \.isEnabled, toEqual: true, timeout: 5))
    }
    replaceMetadataText(title, with: String(repeating: "😀", count: 750), in: app)
    XCTAssertTrue(save.wait(for: \.isEnabled, toEqual: true, timeout: 5))
    XCTAssertFalse(
      app.staticTexts["Title and subtitle must be no longer than 1,000 characters."].exists)
    capture("IPAD-E01-A05-valid-unicode-title")
    app.buttons["Cancel"].tap()
    app.buttons["Done"].tap()
    app.buttons["signOut"].tap()
    XCTAssertTrue(app.buttons["connectServer"].waitForExistence(timeout: 10))
  }

  @MainActor
  func testIPADE01A01OIDCLoginAndRelaunch() throws {
    let app = launchAtServerEntry()
    connect(app)
    let provider = app.buttons["oidc-ipad-fixture"]
    XCTAssertTrue(provider.waitForExistence(timeout: 10))
    provider.tap()
    let consent = app.buttons["Continue"]
    if consent.waitForExistence(timeout: 5) { consent.tap() }
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 30))
    capture("IPAD-E01-A01-oidc-library")
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["50,000 books"].waitForExistence(timeout: 20))
    app.buttons["signOut"].tap()
    XCTAssertTrue(app.buttons["connectServer"].waitForExistence(timeout: 10))
  }

  @MainActor
  private func launchAtServerEntry() -> XCUIApplication {
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    let server = app.textFields["serverURL"]
    if !server.waitForExistence(timeout: 5) {
      if app.buttons["signOut"].exists { app.buttons["signOut"].tap() }
      if app.buttons["Change server"].exists { app.buttons["Change server"].tap() }
    }
    XCTAssertTrue(server.waitForExistence(timeout: 10))
    return app
  }

  @MainActor
  private func connect(_ app: XCUIApplication, serverURL: String = "http://localhost:16482") {
    let server = app.textFields["serverURL"]
    XCTAssertTrue(server.waitForExistence(timeout: 10))
    server.tap()
    let existing = server.value as? String ?? ""
    if existing != serverURL {
      server.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
      server.typeText(serverURL)
    }
    let connect = app.buttons["connectServer"]
    XCTAssertTrue(connect.wait(for: \.isEnabled, toEqual: true, timeout: 10))
    XCTAssertTrue(connect.wait(for: \.isHittable, toEqual: true, timeout: 10))
    connect.tap()
  }

  @MainActor
  private func replaceText(_ field: XCUIElement, with text: String, in app: XCUIApplication) {
    field.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    let existing = field.value as? String ?? ""
    if !existing.isEmpty && existing != field.placeholderValue {
      field.typeKey("a", modifierFlags: .command)
      field.typeText(XCUIKeyboardKey.delete.rawValue)
      let value = field.value as? String
      XCTAssertTrue(value == nil || value == "" || value == field.placeholderValue)
    }
    field.typeText(text.isEmpty ? XCUIKeyboardKey.delete.rawValue : text)
    if text.isEmpty {
      let value = field.value as? String
      XCTAssertTrue(value == nil || value == "" || value == field.placeholderValue)
    } else {
      XCTAssertEqual(field.value as? String, text)
    }
  }

  @MainActor
  private func signIn(_ app: XCUIApplication, username usernameValue: String = "ipad-owner") {
    let username = app.textFields["username"]
    XCTAssertTrue(username.waitForExistence(timeout: 10))
    XCTAssertTrue(username.wait(for: \.isEnabled, toEqual: true, timeout: 10))
    XCTAssertTrue(username.wait(for: \.isHittable, toEqual: true, timeout: 10))
    username.tap()
    username.typeText(usernameValue)
    app.secureTextFields["password"].tap()
    app.secureTextFields["password"].typeText("IpadFixture123")
    app.buttons["signIn"].tap()
  }

  @MainActor
  private func revokeNativeSession() async throws {
    func request(
      _ path: String, method: String = "GET", token: String? = nil, body: [String: String]? = nil
    ) async throws -> Data {
      var request = URLRequest(url: URL(string: "http://localhost:16482/api/v1/\(path)")!)
      request.httpMethod = method
      request.timeoutInterval = 10
      if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
      if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
      if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
      let (data, response) = try await URLSession.shared.data(for: request)
      XCTAssertTrue((200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0))
      return data
    }
    let data = try await request(
      "auth/login", method: "POST",
      body: [
        "username": "ipad-owner", "password": "IpadFixture123", "clientKind": "native",
        "deviceLabel": "XCUITest control session",
      ])
    let credentials = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let token = try XCTUnwrap(credentials["accessToken"] as? String)
    let sessionsData = try await request("auth/sessions", token: token)
    let sessions = try XCTUnwrap(
      JSONSerialization.jsonObject(with: sessionsData) as? [[String: Any]])
    let native = sessions.filter { ($0["deviceLabel"] as? String) == "BookOrbit private iPad" }
    XCTAssertEqual(native.count, 1)
    let id = try XCTUnwrap(native.first?["id"] as? Int)
    _ = try await request("auth/sessions/\(id)", method: "DELETE", token: token)
    _ = try await request(
      "auth/logout", method: "POST",
      body: ["refreshToken": try XCTUnwrap(credentials["refreshToken"] as? String)])
  }

  @MainActor
  private func capture(_ name: String) {
    let screenshot = XCUIScreen.main.screenshot()
    if XCUIDevice.shared.orientation.isLandscape {
      XCTAssertGreaterThan(screenshot.image.size.width, screenshot.image.size.height)
    }
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
