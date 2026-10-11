import SwiftUI

struct StoryGraphSettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @State private var model: StoryGraphSettingsModel
  @State private var confirmingDisconnect = false

  init(api: BookOrbitAPI) { _model = State(initialValue: StoryGraphSettingsModel(api: api)) }

  var body: some View {
    NavigationStack {
      Form {
        Section("Supported transfer") {
          Text(
            "One-way export of your eligible reading status and progress to StoryGraph. Your library access and book exclusions apply."
          )
          Text(
            "Import, ratings, personal notes, highlights, and book files are not supported by this integration."
          )
          .foregroundStyle(.secondary)
        }
        Section("Connection") {
          LabeledContent(
            "Credentials",
            value: model.settings?.cookiesConfigured == true ? "Stored on server" : "Not configured"
          )
          SecureField("StoryGraph session cookie", text: $model.sessionCookie)
            .textContentType(.password).autocorrectionDisabled().textInputAutocapitalization(.never)
            .accessibilityIdentifier("storygraphSessionCookie")
          SecureField("StoryGraph remember token", text: $model.rememberToken)
            .textContentType(.password).autocorrectionDisabled().textInputAutocapitalization(.never)
            .accessibilityIdentifier("storygraphRememberToken")
          Text(
            "From your own StoryGraph browser session, copy _storygraph_session and remember_user_token. Saved values are never returned to this app. Leave both fields empty to retain saved credentials."
          )
          .font(.footnote).foregroundStyle(.secondary)
          Button("Validate connection", action: validate).disabled(!model.canSave)
            .accessibilityIdentifier("storygraphValidate")
        }
        Section("Export scope") {
          Toggle("Enable StoryGraph sync", isOn: $model.enabled)
          Toggle("Only selected books", isOn: $model.selectedOnly)
          Toggle("Sync when reading status changes", isOn: $model.autoStatus)
          Toggle("Sync when reading progress changes", isOn: $model.autoProgress)
          Text(
            "Turn on only selected books to choose eligible books individually. Sync exports your own record to your StoryGraph account; shared insight privacy does not select this export."
          )
          .font(.footnote).foregroundStyle(.secondary)
          Button("Save settings", action: save).disabled(!model.canSave)
            .accessibilityIdentifier("storygraphSave")
        }
        Section("Sync job") {
          if let pending = model.pending {
            LabeledContent("Eligible books", value: String(pending.totalBooks))
            LabeledContent("Pending changes", value: String(pending.pendingBooks))
          }
          if let job = model.status {
            LabeledContent("Outcome", value: job.status.capitalized)
              .accessibilityIdentifier("storygraphJobOutcome")
            ProgressView(value: Double(job.processedBooks), total: Double(max(1, job.totalBooks)))
              .accessibilityLabel("StoryGraph sync progress")
            Text(
              "\(job.processedBooks) of \(job.totalBooks) processed; \(job.syncedBooks) accepted, \(job.skippedBooks) skipped, \(job.failedBooks) failed"
            )
            .accessibilityIdentifier("storygraphJobCounts")
            if job.status == "failed" {
              Text(
                "The job was interrupted or failed. Sync pending changes again to recover; confirmed book states prevent resending unchanged records."
              )
            }
          } else {
            Text("No sync result recorded.").foregroundStyle(.secondary)
          }
          Button("Sync pending changes", action: sync)
            .disabled(model.isBusy || model.isRunning || model.settings?.effectiveEnabled != true)
            .accessibilityIdentifier("storygraphSync")
          if model.isRunning {
            Button("Cancel sync", role: .destructive, action: cancel).disabled(model.isBusy)
          }
          Button("Refresh results", action: refresh).disabled(model.isBusy || model.isLoading)
            .accessibilityIdentifier("storygraphRefresh")
        }
        if let error = model.error {
          Section("Action needs attention") {
            Text(error).accessibilityIdentifier("storygraphError")
          }
        }
        if let message = model.message {
          Section("Result") { Text(message).accessibilityIdentifier("storygraphResult") }
        }
        if !model.failures.isEmpty {
          Section("Recent failures, up to 100") {
            ForEach(model.failures, id: \.bookId) { failure in
              NavigationLink {
                StoryGraphBookView(api: model.api, bookID: failure.bookId, title: failure.title)
              } label: {
                VStack(alignment: .leading) {
                  Text(failure.title)
                  Text(failure.syncError).font(.footnote).foregroundStyle(.secondary)
                }
              }
            }
          }
        }
        Section("Currently reading matches") {
          Text("Manage any other book from its library detail.").font(.footnote).foregroundStyle(
            .secondary)
          ForEach(model.page?.items ?? [], id: \.bookId) { book in
            NavigationLink {
              StoryGraphBookView(api: model.api, bookID: book.bookId, title: book.title ?? "Book")
            } label: {
              VStack(alignment: .leading) {
                Text(book.title ?? "Book")
                Text(book.storygraphBookId ?? "Not matched").font(.footnote).foregroundStyle(
                  .secondary)
              }
            }.accessibilityIdentifier("storygraphMatch\(book.bookId)")
          }
          HStack {
            Button("Previous matches", action: previous).disabled(
              model.pageNumber == 1 || model.isBusy)
            Spacer()
            Text("Page \(model.pageNumber)")
            Spacer()
            Button("Next matches", action: next).disabled(
              model.page?.nextCursor == nil || model.isBusy)
          }
        }
        if model.settings?.cookiesConfigured == true {
          Section {
            Button("Disconnect StoryGraph", role: .destructive, action: confirmDisconnect).disabled(
              model.isBusy)
          }
        }
      }
      .navigationTitle("StoryGraph")
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: close) } }
      .overlay {
        if model.isLoading && model.settings == nil { ProgressView("Loading StoryGraph") }
      }
      .task { await model.observe() }
      .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
      .confirmationDialog(
        "Remove saved StoryGraph credentials?", isPresented: $confirmingDisconnect
      ) {
        Button("Disconnect StoryGraph", role: .destructive, action: disconnect)
      } message: {
        Text("Existing records already sent to StoryGraph remain there.")
      }
    }
  }

  private func close() {
    model.sessionCookie = ""
    model.rememberToken = ""
    dismiss()
  }
  private func save() { Task { await model.save() } }
  private func validate() { Task { await model.validate() } }
  private func sync() { Task { await model.sync() } }
  private func cancel() { Task { await model.cancel() } }
  private func refresh() { Task { await model.load() } }
  private func next() { Task { await model.nextPage() } }
  private func previous() { Task { await model.previousPage() } }
  private func confirmDisconnect() { confirmingDisconnect = true }
  private func disconnect() { Task { await model.disconnect() } }
}
