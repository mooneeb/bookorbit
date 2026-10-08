import SwiftUI

struct EPUBReaderHelpView: View {
  let flow: String
  let animation: ReaderTurnAnimation
  let rightToLeft: Bool
  let speechActive: Bool
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section("Reader controls") {
          Text(
            "Pin reader controls to keep the toolbar and navigation footer visible while reading. Unpin them to hide after moving to another passage. Hide reader controls also hides them until you restore them."
          )
          Text(
            "Show reader controls stays at the bottom of the reader. Tap it, press Escape, or use the VoiceOver escape gesture to restore the toolbar. Close reader stays available there."
          )
          Text(
            "Pinned Contents shares the window with the live page. It appears beside the page in wide windows and above it in narrow windows. Expand or collapse a section with its disclosure button, then choose its title to navigate. Unpin Contents returns the space to the page."
          )
        }
        Section("Touch gestures") {
          if flow == "scrolled" {
            Text(
              "Drag the page to scroll through the current section. Use Previous page, Next page or the section controls to move further through the book."
            )
          } else if animation == .verticalSlide {
            Text(
              "Swipe upward at least a short distance to move forward. Swipe downward to move backward."
            )
          } else {
            Text(
              rightToLeft
                ? "Swipe right to move forward. Swipe left to move backward."
                : "Swipe left to move forward. Swipe right to move backward.")
          }
          Text(
            "Touch and hold book text to select a passage with the system selection handles. Page swipes pause while text is selected. Selected passage tools remain visible when reader controls are hidden."
          )
          Text(
            "Page swipes pause during position saves, unresolved resume choices and active narration. Native navigation controls stop narration and confirm its save before moving. Resolve resume choices or retry a failed save before reading further."
          )
        }
        Section("Keyboard with reader controls visible") {
          command(rightToLeft ? "Right Arrow" : "Left Arrow", "Previous page")
          command(rightToLeft ? "Left Arrow" : "Right Arrow", "Next page")
          command("Command + Up Arrow", "Previous section")
          command("Command + Down Arrow", "Next section")
          command("Command + L", "Go to position")
          Text(
            "When reader controls are hidden, press Escape to show them before using navigation shortcuts. Move focus out of a text field before using page arrow keys."
          )
        }
        if speechActive {
          Section("Speech keyboard controls") {
            command("Command + Shift + Space", "Pause or resume speech")
            command("Command + Shift + .", "Stop speech to navigate")
          }
        }
        Section("Accessibility") {
          Text(
            "Narration controls, selected passage tools and resume choices stay available when reader controls are hidden. The reader respects Reduce Motion for page movement. Use the labeled native buttons with VoiceOver or Full Keyboard Access."
          )
        }
      }
      .navigationTitle("Reader help").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", action: dismiss.callAsFunction).accessibilityIdentifier("epubHelpDone")
        }
      }
    }
    .accessibilityIdentifier("epubReaderHelp")
  }

  private func command(_ keys: String, _ action: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(action).font(.headline)
      Text(keys).font(.body)
    }
    .accessibilityElement(children: .combine)
  }
}
