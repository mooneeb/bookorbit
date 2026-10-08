import SwiftUI

struct BookWriteAndRenameView: View {
  @Bindable var model: BookWriteAndRenameModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          if let book = model.book {
            Text(book.title ?? "Untitled book").font(.title2.bold())
              .accessibilityIdentifier("bookFileWriteSavedTitle")
            Text(book.libraryName)
            Text(
              "This operation uses the latest saved server metadata. Unsaved editor changes and selected covers are not sent. Save them separately before opening a new review if you want them included."
            )
            .accessibilityIdentifier("bookFileWriteSavedMetadataWarning")
            Text(
              "The server will attempt to embed configured metadata into the primary file, or its audiobook tracks, then apply configured naming rules to this book's files and folders. This changes source files used by everyone with library access. Enabled formats, size limits and naming rules still apply. A write or rename may be skipped or fail."
            )
            .accessibilityIdentifier("bookFileWriteSourceWarning")
            Text(
              "Manual writing and renaming override the library's automatic enable switches. This does not change those switches."
            )
            .accessibilityIdentifier("bookFileWriteManualOverrideWarning")
            DisclosureGroup("Current saved files (\(book.files.count.formatted()))") {
              LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(book.files) { file in
                  Text(file.filename ?? "Book file \(file.id)")
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("bookFileWriteCurrentFile\(file.id)")
                }
              }
            }
            BookFileWriteStatusView(book: book)
          }
          if let result = model.result {
            BookWriteAndRenameResultView(result: result)
          }
          if let message = model.message {
            Label(message, systemImage: "info.circle")
              .accessibilityIdentifier("bookFileWriteMessage")
          }
          if model.isBusy {
            ProgressView(progressLabel)
              .accessibilityIdentifier("bookFileWriteProgress")
          }
          if model.canConfirm {
            if model.isDeliberateRepeat {
              Text(
                "Repeat the entire operation even though the earlier request may already have run or may still be running? Both metadata writing and renaming will be attempted again. This does not confirm the earlier outcome."
              )
              .accessibilityIdentifier("bookFileWriteRepeatWarning")
            } else if model.result != nil {
              Text(
                "This new request repeats both stages, including any stage that succeeded earlier."
              )
              .accessibilityIdentifier("bookFileWriteRepeatWarning")
            }
            Button(role: .destructive, action: model.confirm) {
              Text(
                model.isDeliberateRepeat
                  ? "Confirm repeat of entire operation" : "Write saved metadata and rename"
              )
              .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("confirmBookFileWrite")
          }
          if model.canReload {
            Button("Reload current book status", action: reload)
              .frame(minHeight: 44).accessibilityIdentifier("reloadBookFileWriteStatus")
          }
          if model.canReviewAgain {
            Button(
              model.hasUnconfirmedWrite ? "Review explicit repeat" : "Review another run",
              action: reviewAgain
            )
            .frame(minHeight: 44).accessibilityIdentifier("reviewBookFileWriteAgain")
          }
        }
        .foregroundStyle(.primary)
        .padding().frame(maxWidth: .infinity, alignment: .leading)
      }
      .navigationTitle("Write metadata and rename")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(
            model.phase == .writing ? "Stop waiting" : (model.didAttemptWrite ? "Close" : "Cancel"),
            action: close
          )
          .accessibilityIdentifier("closeBookFileWrite")
        }
      }
    }
    .task { await model.prepare() }
    .onDisappear { model.stopWaiting() }
  }

  private var progressLabel: String {
    switch model.phase {
    case .writing: "Waiting for server file-write and rename result…"
    case .readingBack: "Reloading current file details…"
    default: "Checking current account and saved book…"
    }
  }

  private func reload() { Task { await model.reload() } }
  private func reviewAgain() { Task { await model.reviewAgain() } }
  private func close() {
    model.stopWaiting()
    dismiss()
  }
}
