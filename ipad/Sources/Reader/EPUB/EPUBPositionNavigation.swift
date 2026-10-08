import Foundation
import Observation

enum EPUBProgrammaticMovement: String, Codable, CaseIterable, Identifiable {
  case smooth
  case immediate

  var id: String { rawValue }
  var label: String { self == .smooth ? "Smooth" : "Immediate" }
}

enum EPUBPositionJumpResult {
  case saved
  case pendingSave
  case failed
}

@MainActor @Observable
final class EPUBPositionNavigation {
  var input: String
  private(set) var percentage: Double
  private(set) var failure: String?
  private(set) var isCommitting = false
  private(set) var needsSaveConfirmation = false

  init(percentage: Double) {
    self.percentage = percentage
    input = Self.percentageInput(percentage)
  }

  func setPercentage(_ value: Double) {
    guard !isCommitting, !needsSaveConfirmation, value.isFinite, (0...100).contains(value) else {
      return
    }
    percentage = value
    input = Self.percentageInput(value)
    failure = nil
  }

  func commit(
    locationTotal: Int?, action: @MainActor (Double) async -> EPUBPositionJumpResult,
    retrySave: @MainActor () async -> Bool, failureMessage: @MainActor () -> String?
  ) async -> Bool {
    guard !isCommitting else { return false }
    isCommitting = true
    failure = nil
    defer { isCommitting = false }
    if needsSaveConfirmation {
      if await retrySave() { return true }
      failure = failureMessage() ?? "The reading position is not confirmed. Retry Save."
      return false
    }
    guard let fraction = fraction(locationTotal: locationTotal) else { return false }
    switch await action(fraction) {
    case .saved:
      return true
    case .pendingSave:
      needsSaveConfirmation = true
      failure =
        failureMessage() ?? "The jump completed. Retry Save to confirm the reading position."
    case .failed:
      failure = failureMessage() ?? "The jump could not finish. Retry when the reader is ready."
    }
    return false
  }

  private func fraction(locationTotal: Int?) -> Double? {
    let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty, raw.utf16.count <= 32 else {
      failure = "Enter a percentage from 0 to 100 or a location such as p1."
      return nil
    }
    if raw.lowercased().hasPrefix("p") {
      guard let locationTotal, locationTotal > 0 else {
        failure = "Location numbers are unavailable for this publication. Use a percentage."
        return nil
      }
      let digits = String(raw.dropFirst())
      guard digits.range(of: "^[0-9]+$", options: .regularExpression) != nil,
        let number = Int(digits), (1...locationTotal).contains(number)
      else {
        failure = "Enter a location from p1 to p\(locationTotal)."
        return nil
      }
      return Double(number - 1) / Double(locationTotal)
    }
    let digits = raw.hasSuffix("%") ? String(raw.dropLast()) : raw
    guard
      digits.range(of: "^(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)$", options: .regularExpression)
        != nil,
      let value = Double(digits), value.isFinite, (0...100).contains(value)
    else {
      failure = "Enter a percentage from 0 to 100."
      return nil
    }
    return value / 100
  }

  private static func percentageInput(_ value: Double) -> String {
    String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
  }
}

extension EPUBReaderModel {
  var canGoToPreviousSection: Bool {
    canNavigate && (visibleLocation?.chapterIndex ?? 0) > 0
  }

  var canGoToNextSection: Bool {
    canNavigate && (visibleLocation?.chapterIndex ?? chapterCount) < chapterCount - 1
  }
}
