import UIKit
import XCTest

final class AnnotationProfilePerformanceTests: XCTestCase {
  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
  }

  @MainActor
  func testIPADE02A01ApplySystemProfile() {
    E02ProfileSupport.applyMotionInSettings(self)
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    E02ProfileSupport.configure(app)
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    E02ProfileSupport.assertSystemProfile(app: app)
    capture("IPAD-E02-profile-applied")
    app.terminate()
  }

  @MainActor
  func testIPADE02A01LaunchToUsableLibraryPerformance() {
    let app = signedInApp()
    measured(
      "launch-to-library", budget: 8,
      metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true), XCTClockMetric()]
    ) {
      app.terminate()
    } operation: {
      app.launch()
      XCTAssertTrue(
        app.buttons["openAnnotationHub"].wait(for: \.isHittable, toEqual: true, timeout: 8))
    }
  }

  @MainActor
  func testIPADE02A01BookDetailNavigationPerformance() {
    let app = signedInApp()
    selectFixture(app)
    measured("book-detail-navigation", budget: 5) {
    } operation: {
      app.buttons["tableOpen1_title"].tap()
      let details = app.buttons["Book details"]
      XCTAssertTrue(details.wait(for: \.isHittable, toEqual: true, timeout: 5))
      details.tap()
      XCTAssertTrue(
        app.descendants(matching: .any).matching(identifier: "bookDetailContent").firstMatch
          .waitForExistence(timeout: 5))
    } cleanup: {
      app.navigationBars["Book details"].buttons.element(boundBy: 0).tap()
      XCTAssertTrue(
        app.buttons["tableOpen1_title"].wait(for: \.isHittable, toEqual: true, timeout: 5))
    }
  }

  @MainActor
  func testIPADE02A02ReaderPageTransitionPerformance() {
    let app = signedInApp()
    selectFixture(app)
    app.buttons["tableOpen1_title"].tap()
    app.buttons["Book details"].tap()
    guard E02ProfileSupport.openBookFile(app: app, fileID: 1) else { return }
    let first = app.staticTexts["Page 1 of 3"]
    XCTAssertTrue(app.buttons["pdfNextPage"].waitForExistence(timeout: 15))
    for _ in 0..<3 where !first.exists && app.buttons["pdfPreviousPage"].isEnabled {
      app.buttons["pdfPreviousPage"].tap()
      _ = first.waitForExistence(timeout: 2)
    }
    XCTAssertTrue(first.waitForExistence(timeout: 5))
    measured("reader-page-transition", budget: 2) {
    } operation: {
      app.buttons["pdfNextPage"].tap()
      XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 2))
      XCTAssertTrue(
        app.buttons["pdfPreviousPage"].wait(for: \.isEnabled, toEqual: true, timeout: 2))
    } cleanup: {
      app.buttons["pdfPreviousPage"].tap()
      XCTAssertTrue(first.waitForExistence(timeout: 5))
    }
  }

  @MainActor
  func testIPADE02A07BoundedHubOpenAndSearchPerformance() {
    let app = signedInApp()
    measured("bounded-hub-open-and-search", budget: 5) {
    } operation: {
      app.buttons["openAnnotationHub"].tap()
      let searchFields = app.textFields.matching(identifier: "annotationHubSearch")
      let search = searchFields.element
      XCTAssertTrue(search.wait(for: \.isHittable, toEqual: true, timeout: 5))
      XCTAssertEqual(searchFields.count, 1)
      XCTAssertLessThanOrEqual(
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "annotationHubItem"))
          .count, 40)
      search.tap()
      search.typeText("PerformanceNoSuchConvertedPassage\n")
      XCTAssertTrue(app.staticTexts["annotationHubEmpty"].waitForExistence(timeout: 5))
      XCTAssertLessThanOrEqual(
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "annotationHubItem"))
          .count, 40)
    } cleanup: {
      app.buttons["annotationHubDone"].tap()
    }
  }

  @MainActor
  private func measured(
    _ name: String, budget: Double, metrics: [any XCTMetric] = [XCTClockMetric()],
    setup: () -> Void, operation: () -> Void, cleanup: () -> Void = {}
  ) {
    let options = XCTMeasureOptions()
    options.iterationCount = 2
    options.invocationOptions = [.manuallyStart, .manuallyStop]
    var durations: [Double] = []
    measure(metrics: metrics, options: options) {
      setup()
      startMeasuring()
      let started = ProcessInfo.processInfo.systemUptime
      operation()
      let duration = ProcessInfo.processInfo.systemUptime - started
      stopMeasuring()
      durations.append(duration)
      XCTAssertLessThanOrEqual(
        duration, budget, "\(name) exceeded documented absolute acceptance budget")
      capture("IPAD-E02-\(name)-measured-sample-\(durations.count)")
      cleanup()
    }
    let text =
      "metric=\(name) profile=\(E02ProfileSupport.name) budgetSeconds=\(budget) durationsSeconds=\(durations) measuredIterations=2 warmupIterations=1"
    let attachment = XCTAttachment(string: text)
    attachment.name = "IPAD-E02-performance-\(name)-\(E02ProfileSupport.name)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor
  private func signedInApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    E02ProfileSupport.configure(app)
    app.launch()
    if app.buttons["signOut"].waitForExistence(timeout: 3) { app.buttons["signOut"].tap() }
    if app.buttons["Change server"].exists { app.buttons["Change server"].tap() }
    let server = app.textFields["serverURL"]
    XCTAssertTrue(server.waitForExistence(timeout: 10))
    replace(server, "http://localhost:16482")
    app.buttons["connectServer"].tap()
    guard E02ProfileSupport.ensureSignInForm(app: app, serverURL: "http://localhost:16482") else {
      return app
    }
    XCTAssertTrue(app.textFields["username"].waitForExistence(timeout: 10))
    replace(app.textFields["username"], "ipad-owner")
    replace(app.secureTextFields["password"], "IpadFixture123")
    app.buttons["signIn"].tap()
    XCTAssertTrue(
      app.buttons["openAnnotationHub"].wait(for: \.isHittable, toEqual: true, timeout: 25))
    E02ProfileSupport.assertSystemProfile(app: app)
    return app
  }

  @MainActor
  private func selectFixture(_ app: XCUIApplication) {
    if app.buttons["All books"].exists { app.buttons["All books"].tap() }
    app.buttons["Table"].tap()
    let search = app.textViews["librarySearch"]
    XCTAssertTrue(search.wait(for: \.isHittable, toEqual: true, timeout: 10))
    replace(search, "Orbit fixture")
    search.typeText("\n")
    XCTAssertTrue(
      app.buttons["tableOpen1_title"].wait(for: \.isHittable, toEqual: true, timeout: 10))
  }

  @MainActor
  private func replace(_ field: XCUIElement, _ text: String) {
    field.tap()
    let old = field.value as? String ?? ""
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
    field.typeText(text)
  }

  @MainActor
  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "\(name)-\(E02ProfileSupport.name)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
