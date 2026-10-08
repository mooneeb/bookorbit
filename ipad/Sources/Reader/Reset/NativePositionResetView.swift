import SwiftUI

struct NativePositionResetView: View {
  let model: NativePositionResetModel
  let closed: @MainActor (NativePositionResetModel) -> Void

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Text(model.target.label).font(.headline).fixedSize(horizontal: false, vertical: true)
          Text(model.target.explanation).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("positionResetScope")
          if model.isBusy {
            ProgressView(
              model.didAttempt
                ? "Confirming saved position…" : "Stopping reader and checking saved position…"
            )
            .accessibilityIdentifier("positionResetLoading")
          }
          if !model.savedPosition.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
              Text("Current server position").font(.headline)
              Text(model.savedPosition).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("positionResetCurrent")
          }
          if let message = model.message {
            Text(message).fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("positionResetNotice")
          }
          if let error = model.error {
            Text(error).fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("positionResetError")
          }
          if !model.isConfirmed {
            Button("Check current position", action: check).frame(minHeight: 44)
              .disabled(model.isBusy).accessibilityIdentifier("positionResetCheck")
            Button("Clear saved position", role: .destructive, action: reset)
              .frame(minHeight: 44).disabled(!model.canReset)
              .accessibilityIdentifier("positionResetConfirm")
          }
          if model.didAttempt && !model.isConfirmed {
            Text(
              "Closing keeps this reader stopped. Reopen it to check the latest server position."
            )
            .font(.callout).fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding().frame(maxWidth: .infinity, alignment: .leading)
      }
      .navigationTitle("Clear saved position")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(model.isConfirmed ? "Done" : model.didAttempt ? "Close" : "Cancel", action: close)
            .disabled(model.isBusy && model.didAttempt).keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("positionResetClose")
        }
      }
    }
    .task { await model.load() }
    .interactiveDismissDisabled()
  }

  private func check() { Task { await model.load() } }
  private func reset() { Task { await model.reset() } }
  private func close() { closed(model) }
}
