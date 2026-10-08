import SwiftUI

struct BookReadAloudSyncView: View {
  @Bindable var model: BookReadAloudSyncModel
  let saved: @MainActor (BookDetail, UUID) async -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text("This setting belongs to your account and this book on this server.")
            .fixedSize(horizontal: false, vertical: true)
          Text(
            "Auto links matching ebook and audio positions when recorded narration is available. Disabled keeps each format's position separate. Changing this setting does not reset saved positions."
          )
          .fixedSize(horizontal: false, vertical: true)
        }
        if let book = model.book {
          Section("Last confirmed setting") {
            LabeledContent(
              "Mode", value: BookReadAloudSyncPresentation.modeLabel(book.readAloudSync.mode)
            )
            .accessibilityIdentifier("readAloudSyncSavedMode")
            BookReadAloudSyncStatusView(book: book)
          }
          Section("Your choice") {
            Picker("Read-aloud progress sync", selection: $model.selectedMode) {
              Text("Auto").tag("auto")
              Text("Disabled").tag("disabled")
            }
            .pickerStyle(.inline)
            .disabled(
              model.isBusy || model.isDetached || model.isComplete || model.pendingMode != nil
            )
            .accessibilityIdentifier("readAloudSyncMode")
          }
        }
        if model.isBusy {
          ProgressView(
            model.pendingMode == nil ? "Loading your setting…" : "Confirming your setting…"
          )
          .accessibilityIdentifier("readAloudSyncLoading")
        }
        if let error = model.error {
          Section {
            Text(error).fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("readAloudSyncError")
            if model.canRetry {
              Button("Retry same choice", action: retry).frame(minHeight: 44)
                .accessibilityIdentifier("readAloudSyncRetrySave")
            } else if model.book == nil, !model.isDetached, !model.isBusy {
              Button("Reload setting", action: reload).frame(minHeight: 44)
                .accessibilityIdentifier("readAloudSyncRetryLoad")
            }
          }
        }
      }
      .navigationTitle("Read-aloud progress sync").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: cancel).frame(minHeight: 44)
            .disabled(model.isSaving || model.isComplete)
            .accessibilityIdentifier("readAloudSyncCancel")
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save", action: save).frame(minHeight: 44)
            .disabled(!model.canSave).accessibilityIdentifier("readAloudSyncSave")
        }
      }
    }
    .interactiveDismissDisabled(model.isSaving || model.isComplete)
    .task { await model.load() }
    .onDisappear(perform: model.detach)
  }

  private func reload() { Task { await model.load() } }

  private func save() {
    Task {
      await model.save()
      await finish()
    }
  }

  private func retry() {
    Task {
      await model.retry()
      await finish()
    }
  }

  private func finish() async {
    guard model.isComplete, !model.isDetached, let book = model.book, let session = model.session
    else { return }
    await saved(book, session)
    dismiss()
  }

  private func cancel() {
    model.detach()
    dismiss()
  }
}

struct BookReadAloudSyncStatusView: View {
  let book: BookDetail

  var body: some View {
    let presentation = BookReadAloudSyncPresentation(book: book)
    VStack(alignment: .leading, spacing: 8) {
      Text(presentation.state).font(.headline).accessibilityIdentifier("readAloudSyncState")
      Text(presentation.description).accessibilityIdentifier("readAloudSyncDescription")
      if let note = presentation.audiobookNote {
        Text(note).accessibilityIdentifier("readAloudSyncAudiobookNote")
      }
    }
    .fixedSize(horizontal: false, vertical: true)
  }
}
