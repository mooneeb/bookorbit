import UIKit
import XCTest

@MainActor
enum E03ProfileSupport {
  static func environment(_ key: String) -> String? {
    ProcessInfo.processInfo.environment["TEST_RUNNER_\(key)"]
      ?? ProcessInfo.processInfo.environment[key]
  }

  static var name: String { environment("IPAD_E03_PROFILE") ?? "pro13-portrait-light" }

  static func configure(_ app: XCUIApplication) {
    XCUIDevice.shared.orientation = name.contains("landscape") ? .landscapeLeft : .portrait
  }

  static func assertNativeBounds(_ app: XCUIApplication) {
    let landscape = name.contains("landscape")
    let bounds = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        MainActor.assumeIsolated {
          app.frame.width > 0 && app.frame.height > 0
            && (app.frame.width > app.frame.height) == landscape
        }
      }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [bounds], timeout: 10), .completed,
      "Native bounds must match requested profile \(name) before capture")
  }

  static func capture(_ name: String, test: XCTestCase) {
    assertNativeBounds(XCUIApplication())
    let screenshot = XCUIScreen.main.screenshot()
    XCTAssertEqual(screenshot.image.size.width > screenshot.image.size.height,
      self.name.contains("landscape"), "Native screenshot dimensions must match the profile")
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    test.add(attachment)
  }

  static func audit(_ app: XCUIApplication) throws {
    assertNativeBounds(app)
    try app.performAccessibilityAudit(for: [
      .hitRegion, .elementDetection, .sufficientElementDescription,
    ])
  }
}
