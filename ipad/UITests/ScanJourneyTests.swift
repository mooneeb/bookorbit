import XCTest

final class ScanJourneyTests: XCTestCase {
  @MainActor
  func testIPADE03A01ScanPreviewHistoryAndReader() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    if app.buttons["signOut"].exists { app.buttons["signOut"].tap() }
    if app.buttons["Change server"].exists { app.buttons["Change server"].tap() }
    let server = app.textFields["serverURL"]
    XCTAssertTrue(server.waitForExistence(timeout: 10))
    server.tap()
    let current = server.value as? String ?? ""
    server.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
    server.typeText("http://localhost:16482")
    app.buttons["connectServer"].tap()
    let username = app.textFields["username"]
    XCTAssertTrue(username.waitForExistence(timeout: 10))
    username.tap()
    username.typeText("ipad-owner")
    app.secureTextFields["password"].tap()
    app.secureTextFields["password"].typeText("IpadFixture123")
    app.buttons["signIn"].tap()
    let scans = app.buttons["openServerScanning"]
    XCTAssertTrue(scans.waitForExistence(timeout: 25))
    scans.tap()
    let fixture = app.buttons["E03 scan fixture"]
    XCTAssertTrue(fixture.waitForExistence(timeout: 15))
    fixture.tap()
    let preview = app.buttons["previewServerScan"]
    XCTAssertTrue(preview.waitForExistence(timeout: 15))
    preview.tap()
    let count = app.descendants(matching: .any)["scanPreviewCount"]
    reveal(count, app: app)
    XCTAssertTrue(count.waitForExistence(timeout: 15))
    capture("IPAD-E03-A01-scan-preview")
    let start = app.buttons["startServerScan"]
    reveal(start, app: app)
    XCTAssertTrue(start.isEnabled)
    start.tap()
    app.buttons["Start scan"].tap()
    let status = app.descendants(matching: .any)["serverScanStatus"]
    reveal(status, app: app)
    XCTAssertTrue(status.waitForExistence(timeout: 20))
    XCTAssertTrue(status.wait(for: \.label, toEqual: "completed", timeout: 30))
    capture("IPAD-E03-A01-scan-completed-history")
    let jobBefore = app.descendants(matching: .any)["serverScanJobID"].label
    app.terminate()
    app.launch()
    XCTAssertTrue(scans.waitForExistence(timeout: 25))
    scans.tap()
    XCTAssertTrue(fixture.waitForExistence(timeout: 15))
    fixture.tap()
    reveal(status, app: app)
    XCTAssertTrue(status.waitForExistence(timeout: 15))
    XCTAssertEqual(app.descendants(matching: .any)["serverScanJobID"].label, jobBefore)
    capture("IPAD-E03-A01-scan-relaunch-reconciled")
    let search = app.textFields["scanBookSearch"]
    reveal(search, app: app)
    let book = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "scanOpenBook_")
    ).firstMatch
    reveal(book, app: app)
    XCTAssertTrue(book.waitForExistence(timeout: 15))
    book.tap()
    let read = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "readFile"))
      .firstMatch
    XCTAssertTrue(read.waitForExistence(timeout: 15))
    read.tap()
    XCTAssertTrue(app.buttons["pdfNavigate"].waitForExistence(timeout: 20))
    capture("IPAD-E03-A01-scanned-pdf-reader")
  }

  @MainActor private func reveal(_ element: XCUIElement, app: XCUIApplication) {
    for _ in 0..<12 {
      if element.exists && element.isHittable { return }
      app.swipeUp()
    }
  }
  @MainActor private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
