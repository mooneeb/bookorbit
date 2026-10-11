import Foundation
import XCTest

final class E03AcceptancePerformanceTests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  @MainActor
  func testIPADE03A01LaunchToUsableLibraryPerformance() {
    let app = signedInApp()
    measured("launch-to-library", app: app, provisionalBudget: 8,
      metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true), XCTClockMetric()]) {
      app.terminate()
    } operation: {
      app.launch()
      XCTAssertTrue(app.buttons["acquisitionEntry"].wait(for: \.isHittable, toEqual: true, timeout: 20))
    }
  }

  @MainActor
  func testIPADE03A01AcquisitionReviewNavigationPerformance() {
    navigation("acquisition-review-navigation", entry: "acquisitionEntry",
      ready: "acquisitionSelectFile", provisionalBudget: 5)
  }

  @MainActor
  func testIPADE03A02RequestListNavigationPerformance() {
    navigation("request-list-navigation", entry: "openRequests", ready: "requestNew",
      provisionalBudget: 5)
  }

  @MainActor
  func testIPADE03A03MigrationReviewNavigationPerformance() {
    navigation("migration-review-navigation", entry: "migrationImportEntry",
      ready: "migrationProvider", provisionalBudget: 5)
  }

  @MainActor
  func testIPADE03A05BoundedMaintenancePreviewPerformance() {
    navigation("bounded-maintenance-preview", entry: "maintenanceEntry",
      ready: "maintenanceRefresh", provisionalBudget: 5)
  }

  @MainActor
  private func navigation(_ name: String, entry: String, ready: String,
    provisionalBudget: Double) {
    let app = signedInApp()
    measured(name, app: app, provisionalBudget: provisionalBudget) {
      XCTAssertTrue(app.buttons[entry].wait(for: \.isHittable, toEqual: true, timeout: 15))
    } operation: {
      app.buttons[entry].tap()
      XCTAssertTrue(app.buttons[ready].wait(for: \.isEnabled, toEqual: true, timeout: 20))
      if name == "bounded-maintenance-preview" {
        XCTAssertLessThanOrEqual(app.buttons.matching(
          NSPredicate(format: "identifier BEGINSWITH %@", "maintenanceMerge")).count, 40)
      }
    } cleanup: {
      let done = app.navigationBars.buttons.matching(identifier: "Done").firstMatch
      XCTAssertTrue(done.wait(for: \.isHittable, toEqual: true, timeout: 10))
      done.tap()
    }
    app.terminate()
  }

  @MainActor
  private func measured(_ name: String, app: XCUIApplication, provisionalBudget: Double,
    metrics: [any XCTMetric] = [XCTClockMetric()], setup: () -> Void,
    operation: () -> Void, cleanup: () -> Void = {}) {
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
      E03ProfileSupport.capture("IPAD-E03-performance-\(name)-sample-\(durations.count)", test: self)
      cleanup()
    }
    let values = "metric=\(name) profile=\(E03ProfileSupport.name) os=\(ProcessInfo.processInfo.operatingSystemVersionString) processors=\(ProcessInfo.processInfo.processorCount) physicalMemoryBytes=\(ProcessInfo.processInfo.physicalMemory) appBounds=\(app.frame) durationsSeconds=\(durations) provisionalBudgetSeconds=\(provisionalBudget) budgetStatus=PENDING_HUMAN_REVIEW measuredIterations=2 warmupIterations=1"
    let attachment = XCTAttachment(string: values)
    attachment.name = "IPAD-E03-performance-\(name)-environment-and-provisional-budget"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor
  private func signedInApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    E03ProfileSupport.configure(app)
    app.launch()
    if app.buttons["signOut"].waitForExistence(timeout: 3) { app.buttons["signOut"].tap() }
    if app.buttons["Change server"].exists { app.buttons["Change server"].tap() }
    fill(app.textFields["serverURL"], E03ProfileSupport.environment("IPAD_E03_SERVER_URL") ?? "http://localhost:16482")
    app.buttons["connectServer"].tap()
    fill(app.textFields["username"], "ipad-owner")
    fill(app.secureTextFields["password"], E03ProfileSupport.environment("IPAD_FIXTURE_PASSWORD") ?? "IpadFixture123")
    app.buttons["signIn"].tap()
    XCTAssertTrue(app.buttons["maintenanceEntry"].wait(for: \.isHittable, toEqual: true, timeout: 30))
    E03ProfileSupport.assertNativeBounds(app)
    return app
  }

  @MainActor
  private func fill(_ field: XCUIElement, _ value: String) {
    XCTAssertTrue(field.wait(for: \.isHittable, toEqual: true, timeout: 15))
    field.tap()
    let old = field.value as? String ?? ""
    if old != field.placeholderValue {
      field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.utf16.count))
    }
    field.typeText(value)
  }
}
