import SwiftUI

struct NativeContinuationView: View {
  @Bindable var model: NativeContinuationModel

  var body: some View {
    NavigationStack {
      List {
        if model.isBusy {
          ProgressView("Confirming saved continuation…")
            .accessibilityIdentifier("continuationLoading")
        }
        if let message = model.message {
          Text(message).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("continuationMessage")
        }
        if model.response?.reason == "disabled" {
          Button("Edit progress sync", action: model.openReadAloudSync).frame(minHeight: 44)
            .disabled(model.isBusy).accessibilityIdentifier("continuationEditReadAloudSync")
        }
        if let response = model.response, response.state == "ready" {
          Section {
            Text(model.explanation).fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("continuationAccuracy")
            ForEach(response.targets, id: \.fileId) { target in
              Button {
                Task { await model.choose(target) }
              } label: {
                VStack(alignment: .leading, spacing: 8) {
                  Text(target.filename).font(.headline)
                  if let position = target.positionMs, let track = target.sequence {
                    Text("Track \(track + 1), \(AudioPlaybackModel.clock(Double(position) / 1000))")
                  } else {
                    Text("Matching narrated passage")
                  }
                  Text(model.title)
                }
                .fixedSize(horizontal: false, vertical: true).frame(minHeight: 44)
              }
              .disabled(model.isBusy)
              .accessibilityIdentifier("continuationFile\(target.fileId)")
            }
          }
        }
      }
      .navigationTitle(model.title).navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: model.cancel).frame(minHeight: 44)
            .accessibilityIdentifier("continuationCancel")
        }
      }
    }
    .sheet(item: $model.readAloudSync) { setting in
      BookReadAloudSyncView(model: setting) { book, session in
        await model.readAloudSyncSaved(setting, book: book, session: session)
      }
    }
  }
}
