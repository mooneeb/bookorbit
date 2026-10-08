import Observation
import SwiftUI

@MainActor @Observable
final class ReaderPositionConflictState {
  private(set) var identity = UUID()
  private(set) var isBlocked = false
  private(set) var isVisible = true
  private(set) var local = ""
  private(set) var remote = ""

  func present(local: String, remote: String) {
    identity = UUID()
    self.local = local
    self.remote = remote
    isBlocked = true
    isVisible = true
  }

  func describe(local: String?, remote: String?, identity: UUID) {
    guard isBlocked, self.identity == identity else { return }
    if let local { self.local = self.local.components(separatedBy: "\n")[0] + "\n" + local }
    if let remote { self.remote = self.remote.components(separatedBy: "\n")[0] + "\n" + remote }
  }

  func cancel() { isVisible = false }
  func show() { isVisible = true }
  func clear() { isBlocked = false }
}

struct ReaderPositionChoiceView: View {
  let conflict: ReaderPositionConflictState
  let isSaving: Bool
  let chooseLocal: () -> Void
  let chooseRemote: () -> Void

  var body: some View {
    if conflict.isBlocked {
      VStack(alignment: .leading, spacing: 12) {
        Text("Choose a resume position").font(.headline)
          .accessibilityIdentifier("readerPositionConflict")
        if conflict.isVisible {
          Text(
            "Another reader saved a different position. You can return to an earlier passage. Nothing changes until you choose."
          )
          .fixedSize(horizontal: false, vertical: true)
          Button(action: chooseLocal) {
            VStack(alignment: .leading) {
              Text("Use this iPad position").font(.headline)
              Text(conflict.local).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          }.accessibilityIdentifier("readerPositionChooseLocal")
          Button(action: chooseRemote) {
            VStack(alignment: .leading) {
              Text("Use other reader position").font(.headline)
              Text(conflict.remote).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          }.accessibilityIdentifier("readerPositionChooseRemote")
          Button("Decide later", action: conflict.cancel)
            .frame(minHeight: 44).accessibilityIdentifier("readerPositionCancel")
        } else {
          Text("Both positions are kept. Saving is paused until you choose.")
            .fixedSize(horizontal: false, vertical: true)
          Button("Choose resume position", action: conflict.show)
            .frame(minHeight: 44).accessibilityIdentifier("readerPositionShowChoices")
        }
      }
      .buttonStyle(.bordered).disabled(isSaving)
      .accessibilityElement(children: .contain)
    }
  }
}
