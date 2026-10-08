import UIKit
import XCTest

@MainActor
enum E02ProfileSupport {
  static var name: String {
    ProcessInfo.processInfo.environment["IPAD_E02_PROFILE"] ?? "pro13-portrait-light"
  }

  static var reducedMotion: Bool {
    name == "pro11-portrait-large" || name == "pro13-landscape-dark-large"
  }

  static var contentSize: UIContentSizeCategory {
    switch name {
    case "pro11-portrait-large": .accessibilityExtraExtraExtraLarge
    case "pro13-landscape-dark-large": .extraExtraExtraLarge
    default: .large
    }
  }

  static func configure(_ app: XCUIApplication) {
    XCUIDevice.shared.orientation = name.contains("landscape") ? .landscapeLeft : .portrait
    let removed = Set(["-AppleInterfaceStyle", "-UIPreferredContentSizeCategoryName"])
    var arguments: [String] = []
    var index = 0
    while index < app.launchArguments.count {
      if removed.contains(app.launchArguments[index]) {
        index += 2
      } else {
        arguments.append(app.launchArguments[index])
        index += 1
      }
    }
    app.launchArguments = arguments
  }

  static func ensureSignInForm(app: XCUIApplication, serverURL: String) -> Bool {
    let username = app.textFields["username"]
    let connectionReady = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        MainActor.assumeIsolated {
          username.isHittable || app.buttons["signOut"].isHittable
        }
      }, object: nil)
    guard XCTWaiter.wait(for: [connectionReady], timeout: 15) == .completed else {
      XCTFail("Connecting must show the sign-in form or a session that can be signed out.")
      return false
    }
    let signOuts = app.buttons.matching(identifier: "signOut")
    if signOuts.count > 0 {
      guard signOuts.count == 1,
        signOuts.element.wait(for: \.isHittable, toEqual: true, timeout: 5),
        signOuts.element.wait(for: \.isEnabled, toEqual: true, timeout: 10)
      else {
        XCTFail("Expected one available Sign out control for the restored session.")
        return false
      }
      signOuts.element.tap()
      let server = app.textFields["serverURL"]
      guard server.wait(for: \.isHittable, toEqual: true, timeout: 10) else {
        XCTFail("Signing out the restored session must return to the server connection form.")
        return false
      }
      server.tap()
      let existing = server.value as? String ?? ""
      server.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
      server.typeText(serverURL)
      app.buttons["connectServer"].tap()
    }
    guard username.wait(for: \.isHittable, toEqual: true, timeout: 10) else {
      XCTFail("The requested server must show the sign-in form after removing a restored session.")
      return false
    }
    return true
  }

  static func applyMotionInSettings(_ test: XCTestCase) {
    let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    settings.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    settings.launch()
    let accessibility = settings.cells.containing(.staticText, identifier: "Accessibility")
      .firstMatch
    for _ in 0..<6 where !accessibility.isHittable {
      let back = settings.navigationBars.buttons.element(boundBy: 0)
      if back.exists && back.label != "Edit" { back.tap() } else { settings.swipeUp() }
    }
    guard accessibility.wait(for: \.isHittable, toEqual: true, timeout: 5) else {
      XCTFail("Settings Accessibility entry is unreachable; Reduce Motion was not applied.")
      return
    }
    accessibility.tap()
    let motion = settings.cells.containing(.staticText, identifier: "Motion").firstMatch
    XCTAssertTrue(motion.wait(for: \.isHittable, toEqual: true, timeout: 5))
    motion.tap()
    let toggle = settings.switches["Reduce Motion"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    let expected = reducedMotion ? "1" : "0"
    if toggle.value as? String != expected { toggle.tap() }
    let value = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", expected), object: toggle)
    XCTAssertEqual(XCTWaiter.wait(for: [value], timeout: 5), .completed)
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "IPAD-E02-system-reduce-motion-\(name)"
    attachment.lifetime = .keepAlways
    test.add(attachment)
    settings.terminate()
    let predicate = NSPredicate { _, _ in UIAccessibility.isReduceMotionEnabled == reducedMotion }
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 5), .completed
    )
  }

  static func assertSystemProfile(app: XCUIApplication) {
    XCTAssertEqual(UIApplication.shared.preferredContentSizeCategory, contentSize)
    XCTAssertEqual(UIAccessibility.isReduceMotionEnabled, reducedMotion)
    let frame = app.frame
    XCTAssertGreaterThan(max(frame.width, frame.height), 1100)
    if name.contains("landscape") {
      XCTAssertGreaterThan(frame.width, frame.height)
    } else {
      XCTAssertGreaterThan(frame.height, frame.width)
    }
    if contentSize == .accessibilityExtraExtraExtraLarge {
      XCTAssertGreaterThanOrEqual(UIFont.preferredFont(forTextStyle: .body).pointSize, 40)
    }
  }
}
