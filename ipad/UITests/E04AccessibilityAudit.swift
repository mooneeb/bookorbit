import Foundation
import XCTest

final class E04AccessibilityAudit {
  private struct Finding {
    let details: [String: String]
    let file: StaticString
    let line: UInt
  }

  private var findings: [Finding] = []
  private var auditedScreens: [String] = []

  @MainActor
  func collect(
    _ app: XCUIApplication, screen: String, testCase: XCTestCase,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    auditedScreens.append(screen)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "E04-accessibility-\(screen)-screen"
    screenshot.lifetime = .keepAlways
    testCase.add(screenshot)
    attach(app.debugDescription, name: "\(screen)-hierarchy", testCase: testCase)
    do {
      try app.performAccessibilityAudit(for: .all) { issue in
        var details = [
          "screen": screen, "test": testCase.name,
          "sourceFile": String(describing: file), "sourceLine": String(line),
          "auditType": String(issue.auditType.rawValue),
          "compactDescription": issue.compactDescription,
          "detailedDescription": issue.detailedDescription,
        ]
        if let element = issue.element {
          details["elementExists"] = String(element.exists)
          if element.exists {
            details["elementType"] = String(element.elementType.rawValue)
            details["elementIdentifier"] = element.identifier
            details["elementLabel"] = element.label
            details["elementValue"] = String(describing: element.value)
            details["elementFrame"] = String(describing: element.frame)
            details["elementDescription"] = element.debugDescription
            let image = XCTAttachment(screenshot: element.screenshot())
            image.name = "E04-accessibility-\(screen)-issue-\(self.findings.count + 1)-element"
            image.lifetime = .keepAlways
            testCase.add(image)
          }
        } else {
          details["element"] = "nil"
        }
        self.record(details, testCase: testCase, file: file, line: line)
        // Every callback finding becomes a test failure after the domain assertions finish.
        return true
      }
    } catch {
      record(
        [
          "screen": screen, "test": testCase.name,
          "sourceFile": String(describing: file), "sourceLine": String(line),
          "compactDescription": "Accessibility audit could not complete",
          "detailedDescription": String(describing: error),
          "errorClass": String(describing: type(of: error)),
        ], testCase: testCase, file: file, line: line)
    }
  }

  func reportFailures(testCase: XCTestCase) {
    guard !auditedScreens.isEmpty else { return }
    let summary: [String: Any] = [
      "test": testCase.name, "auditedScreens": auditedScreens,
      "nativeAccessibilityAudit": findings.isEmpty ? "PASS" : "FAIL",
      "issues": findings.map(\.details),
    ]
    if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]) {
      let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
      attachment.name = "E04-native-accessibility-results"
      attachment.lifetime = .keepAlways
      testCase.add(attachment)
    }
    let previous = testCase.continueAfterFailure
    testCase.continueAfterFailure = true
    defer { testCase.continueAfterFailure = previous }
    for finding in findings {
      XCTFail(
        "Accessibility audit: \(finding.details["screen"] ?? "unknown"): \(finding.details["compactDescription"] ?? "unknown issue"). \(finding.details["detailedDescription"] ?? "")",
        file: finding.file, line: finding.line)
    }
  }

  private func record(
    _ details: [String: String], testCase: XCTestCase, file: StaticString, line: UInt
  ) {
    findings.append(Finding(details: details, file: file, line: line))
    let diagnostic = details.keys.sorted().map { "\($0)=\(details[$0] ?? "")" }.joined(
      separator: "\n")
    attach(
      diagnostic, name: "\(details["screen"] ?? "unknown")-accessibility-issue-\(findings.count)",
      testCase: testCase)
  }

  private func attach(_ text: String, name: String, testCase: XCTestCase) {
    let attachment = XCTAttachment(string: text)
    attachment.name = name
    attachment.lifetime = .keepAlways
    testCase.add(attachment)
  }
}
