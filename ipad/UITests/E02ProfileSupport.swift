import UIKit
import XCTest

@MainActor
enum E02ProfileSupport {
  static func criticalOnly(_ test: XCTestCase) -> Bool {
    let selected = [
      "testIPADE02A04CompleteEPUBAndRecordedReadAlongPlayAfterOfflineRestart",
      "testIPADE02A05AuthoritativeDeletionPreservesOfflineEditAsRecoveryDraft",
      "testIPADE02A06DeletedSourceKeepsProtectedCompleteVersionForExport",
      "testIPADE02A06ProtectedRetainedPDFExportAfterSourceDeletion",
      "testIPADE02A07HubDeepLinkExportTrashRestoreAndExplicitRepair",
    ]
    return ProcessInfo.processInfo.environment["IPAD_E02_CRITICAL_ONLY"] == "1"
      && selected.contains { test.name.contains($0) }
  }

  static func reportDeferred(_ test: XCTestCase, check: String, observed: String) {
    let attachment = XCTAttachment(
      string: "status=DEFERRED severity=P2 scope=critical-only check=\(check)\n\(observed)")
    attachment.name = "IPAD-E02-deferred-\(check)"
    attachment.lifetime = .keepAlways
    test.add(attachment)
    print("IPAD-E02 status=DEFERRED severity=P2 check=\(check)")
  }

  static func reveal(
    _ element: XCUIElement, in list: XCUIElement, app: XCUIApplication,
    towardTop: Bool = false
  ) -> Bool {
    for _ in 0..<12 {
      let viewport = list.frame.intersection(app.frame)
      if element.exists && viewport.contains(element.frame) && element.isHittable { return true }
      if element.exists ? element.frame.minY < viewport.minY : towardTop {
        list.swipeDown()
      } else {
        list.swipeUp()
      }
    }
    return element.exists && list.frame.intersection(app.frame).contains(element.frame)
      && element.isHittable
  }

  static func retainedPDFVersionID(
    in list: XCUIElement, bookID: Int, fileID: Int, revision: String
  ) -> String? {
    let provenance = "Book \(bookID), file \(fileID), PDF"
    let cells = list.cells.allElementsBoundByIndex
    guard
      let index = cells.firstIndex(where: {
        $0.staticTexts.matching(identifier: "sourceRecoveryProvenance")
          .matching(NSPredicate(format: "label == %@", provenance)).count == 1
      })
    else {
      XCTFail("The current retained PDF provenance must identify one native row.")
      return nil
    }
    for cell in cells.prefix(index + 1).reversed() {
      let titles = cell.staticTexts.matching(
        NSPredicate(format: "identifier BEGINSWITH %@", "sourceRecoveryVersion"))
      if titles.count == 0 { continue }
      guard titles.count == 1 else {
        XCTFail("The current retained PDF section must have one version identity.")
        return nil
      }
      let identity = String(titles.element.identifier.dropFirst("sourceRecoveryVersion".count))
      guard identity.hasSuffix("-\(revision)") else {
        XCTFail("The current retained PDF identity must match its original source revision.")
        return nil
      }
      return identity
    }
    XCTFail("The current retained PDF provenance has no preceding version heading.")
    return nil
  }

  static func openSaveToFiles(app: XCUIApplication, test: XCTestCase) -> Bool {
    let save = app.buttons["Save to Files"]
    if save.wait(for: \.isHittable, toEqual: true, timeout: 3) {
      XCTAssertTrue(save.isEnabled)
      save.tap()
      return true
    }
    let more = app.cells.matching(
      NSPredicate(format: "identifier == %@ AND label == %@", "actionGroupCell", "More"))
    guard more.element.wait(for: \.isHittable, toEqual: true, timeout: 10), more.count == 1,
      more.element.isEnabled
    else {
      XCTFail("Expected the compact share sheet's unique More actions control.")
      return false
    }
    let attachment = XCTAttachment(string: app.debugDescription)
    attachment.name = "IPAD-E02-native-share-sheet-before-More-actions"
    attachment.lifetime = .keepAlways
    test.add(attachment)
    more.element.tap()
    for _ in 0..<6 {
      let cells = app.cells.matching(NSPredicate(format: "label == %@", "Save to Files"))
      if save.exists && save.isHittable {
        XCTAssertTrue(save.isEnabled)
        save.tap()
        return true
      }
      if cells.count == 1 && cells.element.isHittable {
        XCTAssertTrue(cells.element.isEnabled)
        cells.element.tap()
        return true
      }
      let lists =
        app.tables.allElementsBoundByIndex
        + app.collectionViews.matching(identifier: "activityCollectionView").allElementsBoundByIndex
      let visible = lists.filter { $0.isHittable }
      guard visible.count == 1, let list = visible.first else {
        XCTFail("Expected one visible native share actions list for Save to Files.")
        return false
      }
      list.swipeUp()
    }
    XCTFail("Save to Files remained unavailable after six bounded public share-action scrolls.")
    return false
  }

  static func waitForEPUBReader(app: XCUIApplication, test: XCTestCase) async throws {
    let tools = app.buttons.matching(identifier: "epubReaderTools")
    if tools.element.wait(for: \.isEnabled, toEqual: true, timeout: 20) {
      XCTAssertEqual(tools.count, 1)
      return
    }
    for (attempt, timeout) in [5.0, 10.0, 20.0].enumerated() {
      let retries = app.buttons.matching(identifier: "epubRetryOpen")
      let hierarchy = app.debugDescription
      guard retries.count == 1, hierarchy.contains("NSURLErrorDomain"),
        hierarchy.contains("-1001"),
        retries.element.wait(for: \.isHittable, toEqual: true, timeout: 5),
        retries.element.isEnabled
      else {
        XCTFail(
          "Reader did not become ready; only the observed transient opening timeout can retry.")
        return
      }
      let attachment = XCTAttachment(string: hierarchy)
      attachment.name = "IPAD-E02-reader-transient-timeout-before-retry-\(attempt + 1)"
      attachment.lifetime = .keepAlways
      test.add(attachment)
      retries.element.tap()
      if tools.element.wait(for: \.isEnabled, toEqual: true, timeout: timeout) {
        XCTAssertEqual(tools.count, 1)
        XCTAssertFalse(app.buttons["epubRetryOpen"].exists)
        return
      }
    }
    XCTFail(
      "Reader remained unavailable after three public Retry opening actions (5/10/20 seconds).")
  }

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

  static func closeOfflineResources(app: XCUIApplication) -> Bool {
    let resources = app.navigationBars.matching(identifier: "Offline resources")
    guard resources.count == 1,
      resources.element.wait(for: \.isHittable, toEqual: true, timeout: 10)
    else {
      XCTFail("Expected one active Offline resources navigation bar.\n\(app.debugDescription)")
      return false
    }
    let buttons = resources.element.buttons.matching(identifier: "Done")
    guard buttons.count == 1,
      buttons.element.wait(for: \.isEnabled, toEqual: true, timeout: 10),
      buttons.element.wait(for: \.isHittable, toEqual: true, timeout: 10)
    else {
      XCTFail("Expected one available Done control in Offline resources.\n\(app.debugDescription)")
      return false
    }
    buttons.element.tap()
    let details = app.navigationBars.matching(identifier: "Book details")
    guard resources.element.wait(for: \.exists, toEqual: false, timeout: 10),
      details.count == 1, details.element.wait(for: \.isHittable, toEqual: true, timeout: 10)
    else {
      XCTFail("Closing Offline resources must reveal Book details.\n\(app.debugDescription)")
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
    let motions = settings.cells.matching(identifier: "MOTION_TITLE")
    let motionTables = settings.tables.containing(.cell, identifier: "MOTION_TITLE")
    let motionWindows = settings.windows.containing(.cell, identifier: "MOTION_TITLE")
    let accessibilityHeadings = settings.navigationBars.matching(identifier: "Accessibility")
    guard motions.firstMatch.waitForExistence(timeout: 10), motions.count == 1,
      motionTables.count == 1, motionWindows.count == 1, accessibilityHeadings.count == 1
    else {
      XCTFail("Expected one Motion row, Accessibility table, window and navigation heading.")
      return
    }
    let motion = motions.element
    let table = motionTables.element
    let motionVisible = table.frame.intersection(motionWindows.element.frame)
    let motionTop = max(motionVisible.minY, accessibilityHeadings.element.frame.maxY)
    let motionViewport = CGRect(
      x: motionVisible.minX, y: motionTop, width: motionVisible.width,
      height: motionVisible.maxY - motionTop)
    let motionX = motion.frame.midX
    guard motionViewport.width > 0, motionViewport.height > 0,
      motionX > motionViewport.minX, motionX < motionViewport.maxX
    else {
      XCTFail("Accessibility table must have a visible Motion column below its navigation heading.")
      return
    }
    for _ in 0..<6 {
      guard motions.count <= 1 else {
        XCTFail("Expected one Motion row in the Accessibility table.")
        return
      }
      if motion.exists && motion.isHittable && motionViewport.contains(motion.frame) { break }
      let scrollDown = motion.exists && motion.frame.minY < motionViewport.minY
      let start = table.coordinate(
        withNormalizedOffset: CGVector(
          dx: (motionX - table.frame.minX) / table.frame.width,
          dy: (motionViewport.minY + motionViewport.height * 0.65 - table.frame.minY)
            / table.frame.height))
      let end = start.withOffset(
        CGVector(dx: 0, dy: motionViewport.height * (scrollDown ? 0.25 : -0.25)))
      start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
    }
    guard motions.count == 1, motion.wait(for: \.isHittable, toEqual: true, timeout: 5),
      motionViewport.contains(motion.frame),
      motion.wait(for: \.isEnabled, toEqual: true, timeout: 5)
    else {
      XCTFail("Settings Motion row is unreachable; Reduce Motion was not applied.")
      return
    }
    motion.tap()
    let reduceMotionRows = settings.cells.matching(identifier: "REDUCE_MOTION")
    let toggles = settings.switches.matching(identifier: "REDUCE_MOTION")
    guard reduceMotionRows.firstMatch.waitForExistence(timeout: 5), reduceMotionRows.count == 1,
      toggles.count == 1
    else {
      XCTFail("Expected one Reduce Motion row and its labeled switch value.")
      return
    }
    let row = reduceMotionRows.element
    let toggle = toggles.element
    let controls = settings.switches.matching(NSPredicate(format: "identifier == %@", ""))
      .allElementsBoundByIndex.filter { !$0.frame.isEmpty && row.frame.contains($0.frame) }
    guard controls.count == 1, let control = controls.first,
      control.wait(for: \.isEnabled, toEqual: true, timeout: 5),
      control.wait(for: \.isHittable, toEqual: true, timeout: 5)
    else {
      XCTFail("Expected one enabled, hittable physical switch inside the exact Reduce Motion row.")
      return
    }
    let expected = reducedMotion ? "1" : "0"
    if toggle.value as? String != expected { control.tap() }
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
