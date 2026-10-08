import SwiftUI

struct BookDeletionView: View {
  @Bindable var model: BookDeletionModel
  let resolved: (BookDeletionOutcome) -> Void
  var closed: (BookDeletionModel) -> Void = { _ in }
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          if let book = model.book {
            Text(book.title ?? "Untitled book").font(.title2.bold())
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("deleteBookTitle")
            Text(book.libraryName).font(.body)
            Text(
              "Delete this book from the server library, including its \(book.files.count.formatted()) files, covers, and saved reading data? This affects everyone using this library and cannot be undone."
            )
            .font(.body).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("deleteBookWarning")
          }
          if let message = model.message {
            Label(message, systemImage: "exclamationmark.triangle")
              .font(.body).fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("deleteBookStatus")
          }
          if model.isBusy {
            ProgressView(model.phase == .deleting ? "Deleting book…" : "Checking book…")
              .accessibilityIdentifier("deleteBookProgress")
          }
          if model.canConfirm {
            Button(role: .destructive, action: confirm) {
              Label("Delete book and files", systemImage: "trash")
                .font(.body).frame(minHeight: 44)
            }
            .accessibilityIdentifier("confirmDeleteBook")
          }
          if model.canReload {
            Button("Reload book status", action: reload)
              .font(.body).frame(minHeight: 44)
              .accessibilityIdentifier("reloadDeleteBookStatus")
          }
        }.foregroundStyle(.primary).padding().frame(maxWidth: .infinity, alignment: .leading)
      }
      .navigationTitle("Delete book")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(model.didAttemptDeletion ? "Close" : "Cancel", action: dismiss.callAsFunction)
            .disabled(model.phase == .deleting)
            .accessibilityIdentifier("cancelDeleteBook")
        }
      }
    }
    .interactiveDismissDisabled(model.phase == .deleting)
    .task { await model.prepare() }
    .onChange(of: model.outcome) { _, outcome in
      if let outcome { resolved(outcome) }
    }
    .onDisappear {
      closed(model)
      model.detach()
    }
  }

  private func confirm() { Task { await model.confirm() } }
  private func reload() {
    Task {
      if model.didAttemptDeletion { await model.reload() } else { await model.prepare() }
    }
  }
}
