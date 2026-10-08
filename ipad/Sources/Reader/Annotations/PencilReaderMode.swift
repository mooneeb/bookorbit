import Observation
import SwiftUI
import UIKit

@MainActor @Observable
final class PencilReaderMode: NSObject, UIPencilInteractionDelegate {
  var isWriting = false
  var showsPalette = false
  var usesEraser = false

  func toggleWriting() { isWriting.toggle() }

  func pencilInteraction(
    _ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap
  ) {
    perform(UIPencilInteraction.preferredTapAction)
  }

  func pencilInteraction(
    _ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
  ) {
    guard squeeze.phase == .ended else { return }
    perform(UIPencilInteraction.preferredSqueezeAction)
  }

  private func perform(_ action: UIPencilPreferredAction) {
    switch action {
    case .switchPrevious: toggleWriting()
    case .switchEraser: usesEraser.toggle()
    case .showColorPalette, .showInkAttributes, .showContextualPalette: showsPalette.toggle()
    default: break
    }
  }
}

struct PencilModeControls: View {
  let mode: PencilReaderMode

  var body: some View {
    Button(
      mode.isWriting ? "Writing mode" : "Navigation mode",
      systemImage: mode.isWriting ? "pencil.tip" : "hand.draw", action: mode.toggleWriting
    )
    .frame(minHeight: 44)
    .accessibilityIdentifier("pencilWritingMode")
    .accessibilityValue(mode.isWriting ? "Writing" : "Navigation")
    .accessibilityHint("Switch between marking passages and turning pages.")
  }
}
