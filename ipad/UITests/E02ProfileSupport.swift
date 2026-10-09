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

  static func openBookFile(app: XCUIApplication, fileID: Int) -> Bool {
    let containers = app.collectionViews.matching(identifier: "bookDetailContent")
    let content = containers.element
    let navigationBars = app.navigationBars.matching(identifier: "Book details")
    guard content.wait(for: \.isHittable, toEqual: true, timeout: 10), containers.count == 1,
      navigationBars.count == 1
    else {
      XCTFail("Expected one visible Book details collection and navigation bar.")
      return false
    }
    let contentFrame = content.frame.intersection(app.frame)
    let visibleTop = max(contentFrame.minY, navigationBars.element.frame.maxY)
    let viewport = CGRect(
      x: contentFrame.minX, y: visibleTop, width: contentFrame.width,
      height: contentFrame.maxY - visibleTop)
    guard viewport.width > 0, viewport.height > 0 else {
      XCTFail("Book details must have a visible content viewport below its navigation bar.")
      return false
    }
    let matches = content.buttons.matching(identifier: "readFile\(fileID)")
    let read = matches.element
    for _ in 0..<12 {
      guard matches.count <= 1 else {
        XCTFail("Expected one Read action for file \(fileID).")
        return false
      }
      if read.exists && read.isHittable && viewport.contains(read.frame) { break }
      let scrollDown = read.exists && read.frame.minY < viewport.minY
      let start = content.coordinate(
        withNormalizedOffset: CGVector(
          dx: 0.02,
          dy: (viewport.minY + viewport.height * 0.65 - content.frame.minY) / content.frame.height))
      let end = start.withOffset(CGVector(dx: 0, dy: viewport.height * (scrollDown ? 0.25 : -0.25)))
      start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
    }
    guard matches.count == 1, read.wait(for: \.isHittable, toEqual: true, timeout: 10),
      viewport.contains(read.frame), read.wait(for: \.isEnabled, toEqual: true, timeout: 10)
    else {
      XCTFail(
        "File \(fileID) Read action is not fully visible after twelve bounded content scrolls.")
      return false
    }
    read.tap()
    return true
  }

  static func openOfflineResources(app: XCUIApplication) -> Bool {
    let containers = app.collectionViews.matching(identifier: "bookDetailContent")
    let content = containers.element
    let navigationBars = app.navigationBars.matching(identifier: "Book details")
    guard content.wait(for: \.isHittable, toEqual: true, timeout: 10), containers.count == 1,
      navigationBars.count == 1
    else {
      XCTFail("Expected one visible Book details collection and navigation bar.")
      return false
    }
    let contentFrame = content.frame.intersection(app.frame)
    let visibleTop = max(contentFrame.minY, navigationBars.element.frame.maxY)
    let viewport = CGRect(
      x: contentFrame.minX, y: visibleTop, width: contentFrame.width,
      height: contentFrame.maxY - visibleTop)
    guard viewport.width > 0, viewport.height > 0 else {
      XCTFail("Book details must have a visible content viewport below its navigation bar.")
      return false
    }
    let matches = content.buttons.matching(identifier: "offlineResources")
    let resources = matches.element
    for _ in 0..<12 {
      guard matches.count <= 1 else {
        XCTFail("Expected one Offline resources action in Book details.")
        return false
      }
      if resources.exists && resources.isHittable && viewport.contains(resources.frame) { break }
      let scrollDown = resources.exists && resources.frame.minY < viewport.minY
      let start = content.coordinate(
        withNormalizedOffset: CGVector(
          dx: 0.02,
          dy: (viewport.minY + viewport.height * 0.65 - content.frame.minY) / content.frame.height))
      let end = start.withOffset(CGVector(dx: 0, dy: viewport.height * (scrollDown ? 0.25 : -0.25)))
      start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
    }
    guard matches.count == 1, resources.wait(for: \.isHittable, toEqual: true, timeout: 10),
      viewport.contains(resources.frame),
      resources.wait(for: \.isEnabled, toEqual: true, timeout: 10)
    else {
      XCTFail(
        "Offline resources action is not fully visible after twelve bounded content scrolls.")
      return false
    }
    resources.tap()
    let headings = app.navigationBars.matching(identifier: "Offline resources")
    guard headings.element.waitForExistence(timeout: 10), headings.count == 1 else {
      XCTFail("Opening Offline resources must show its unique navigation heading.")
      return false
    }
    return true
  }

  static func applyMotionInSettings(_ test: XCTestCase) {
    let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    settings.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    configure(settings)
    settings.launch()
    let sidebars = settings.collectionViews.matching(NSPredicate(format: "label == %@", "Sidebar"))
    let windows = settings.windows.containing(.collectionView, identifier: "Sidebar")
    let headings = settings.navigationBars.matching(identifier: "Settings")
    guard sidebars.firstMatch.waitForExistence(timeout: 10), sidebars.count == 1,
      windows.count == 1, headings.count == 1
    else {
      XCTFail("Expected one Settings sidebar, window and navigation heading for Accessibility.")
      return
    }
    let sidebar = sidebars.element
    let visible = sidebar.frame.intersection(windows.element.frame)
    let top = max(visible.minY, headings.element.frame.maxY)
    let viewport = CGRect(
      x: visible.minX, y: top, width: visible.width, height: visible.maxY - top)
    guard viewport.width > 0, viewport.height > 0 else {
      XCTFail("Settings sidebar must have a visible viewport below its navigation heading.")
      return
    }
    let entries = sidebar.buttons.matching(identifier: "com.apple.settings.accessibility")
    let accessibility = entries.element
    for _ in 0..<6 {
      guard entries.count <= 1 else {
        XCTFail("Expected one Settings Accessibility entry in the sidebar.")
        return
      }
      if accessibility.exists && accessibility.isHittable && viewport.contains(accessibility.frame)
      {
        break
      }
      let scrollDown = accessibility.exists && accessibility.frame.minY < viewport.minY
      let start = sidebar.coordinate(
        withNormalizedOffset: CGVector(
          dx: 0.5,
          dy: (viewport.minY + viewport.height * 0.65 - sidebar.frame.minY) / sidebar.frame.height))
      let end = start.withOffset(CGVector(dx: 0, dy: viewport.height * (scrollDown ? 0.25 : -0.25)))
      start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
    }
    guard entries.count == 1, accessibility.wait(for: \.isHittable, toEqual: true, timeout: 5),
      viewport.contains(accessibility.frame),
      accessibility.wait(for: \.isEnabled, toEqual: true, timeout: 5)
    else {
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
