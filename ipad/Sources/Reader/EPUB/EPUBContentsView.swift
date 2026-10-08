import SwiftUI

struct EPUBContentsView: View {
  let model: EPUBReaderModel
  let outline: EPUBContentsOutlineModel
  let isPinned: Bool
  let togglePin: () -> Void
  let jump: @MainActor (EPUBContentsEntry) async -> Bool
  @State private var isJumping = false
  @State private var failure: String?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        EPUBContentsList(
          outline: outline, canNavigate: model.canNavigate && !isJumping, open: open)
        if let error = model.error {
          Text(error).font(.caption).fixedSize(horizontal: false, vertical: true).padding()
            .accessibilityIdentifier("epubContentsError")
        }
        if let failure {
          Text(failure).font(.caption).fixedSize(horizontal: false, vertical: true).padding()
            .accessibilityIdentifier("epubContentsJumpFailure")
        }
      }
      .navigationTitle("Contents").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(isPinned ? "Unpin Contents" : "Pin Contents", action: pin)
            .disabled(isJumping || model.isNavigating)
            .accessibilityIdentifier("epubContentsPin")
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", action: dismiss.callAsFunction).disabled(isJumping || model.isNavigating)
            .accessibilityIdentifier("epubContentsDone")
        }
      }
    }
    .interactiveDismissDisabled(isJumping || model.isNavigating)
  }

  private func pin() {
    togglePin()
    dismiss()
  }

  private func open(_ entry: EPUBContentsEntry) {
    guard !isJumping else { return }
    isJumping = true
    failure = nil
    Task {
      if await jump(entry) {
        dismiss()
      } else {
        failure =
          "The passage could not be opened and saved. Return to the reader to review position or narration status, then retry."
      }
      isJumping = false
    }
  }
}
