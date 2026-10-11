import SwiftUI

struct HardcoverSettingsView: View {
  @State private var model: HardcoverSettingsModel
  @Environment(\.scenePhase) private var scenePhase
  @State private var confirmDisconnect = false

  init(api: BookOrbitAPI) { _model = State(initialValue: HardcoverSettingsModel(api: api)) }

  var body: some View {
    Form {
      Section("Connection") {
        Text(
          model.settings?.tokenConfigured == true
            ? "Token saved on your server" : "Connect your Hardcover account")
        SecureField("Hardcover API token", text: $model.token)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
          .accessibilityIdentifier("hardcoverToken")
        Button("Verify token") { Task { await model.validate() } }
          .accessibilityIdentifier("hardcoverValidate")
        Toggle("Enable Hardcover", isOn: $model.enabled).accessibilityIdentifier("hardcoverEnabled")
      }
      Section("Reading records sent to Hardcover") {
        Picker("Books to sync", selection: $model.mode) {
          Text("All eligible books").tag("all_eligible")
          Text("Only selected books").tag("selected_only")
        }.accessibilityIdentifier("hardcoverBookMode")
        Picker("Privacy on Hardcover", selection: $model.privacy) {
          Text("Private").tag(3)
          Text("Followers").tag(2)
          Text("Public").tag(1)
        }.accessibilityIdentifier("hardcoverPrivacy")
        Text(
          "Sends your eligible reading status, rating, dates and progress. Personal notes and highlights are excluded."
        )
        .fixedSize(horizontal: false, vertical: true)
        Toggle("Sync status changes", isOn: $model.statusChanges)
        Toggle("Sync progress changes", isOn: $model.progressChanges)
        Toggle("Sync rating changes", isOn: $model.ratingChanges)
        Button("Save settings") { Task { await model.save() } }
          .disabled(
            model.settings == nil
              || (model.settings?.tokenConfigured != true && model.token.isEmpty)
          )
          .accessibilityIdentifier("hardcoverSave")
      }
      Section("Synchronization") {
        if let outcome = model.outcome {
          Text(outcome.status.capitalized).accessibilityIdentifier("hardcoverSyncStatus")
          Text(
            "\(outcome.processedBooks) visited, \(outcome.syncedBooks) confirmed, \(outcome.failedBooks) failed, \(outcome.skippedBooks) skipped"
          )
          .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(
            "hardcoverSyncCounts")
          if let error = outcome.error { Text(error).fixedSize(horizontal: false, vertical: true) }
        }
        Button(
          model.outcome?.status == "failed" ? "Retry eligible records" : "Sync eligible records"
        ) {
          Task { await model.startSync() }
        }.disabled(model.settings?.effectiveEnabled != true || model.running)
          .accessibilityIdentifier("hardcoverSync")
        if model.running {
          ProgressView("Syncing on your server")
          Button("Cancel sync") { Task { await model.cancel() } }.accessibilityIdentifier(
            "hardcoverCancel")
        }
        Button("Refresh confirmed status") { Task { await model.load() } }
          .accessibilityIdentifier("hardcoverRefresh")
        NavigationLink("Import reading records") { HardcoverImportView(api: model.api) }
          .disabled(model.settings?.effectiveEnabled != true).accessibilityIdentifier(
            "hardcoverImport")
      }
      if let linked = model.linkedBooks {
        Section("Currently reading") {
          ForEach(linked.books, id: \.bookId) { book in
            NavigationLink {
              HardcoverBookView(api: model.api, bookID: book.bookId, title: book.title ?? "Book")
            } label: {
              VStack(alignment: .leading) {
                Text(book.title ?? "Book")
                Text(book.hardcoverBookId.map { "Hardcover book \($0)" } ?? "Awaiting match")
                  .font(.caption)
                if let error = book.matchError { Text(error).font(.caption) }
              }
            }.accessibilityIdentifier("hardcoverBook\(book.bookId)")
          }
          if linked.truncated {
            Text(
              "Showing the first 200 reading books. Open any other book's Hardcover controls from its details."
            )
          }
        }
      }
      if let message = model.message {
        Section { Text(message).accessibilityIdentifier("hardcoverMessage") }
      }
      if let error = model.error {
        Section { Text(error).accessibilityIdentifier("hardcoverError") }
      }
      if model.settings?.tokenConfigured == true {
        Section {
          Button("Disconnect Hardcover", role: .destructive) { confirmDisconnect = true }
            .accessibilityIdentifier("hardcoverDisconnect")
        }
      }
    }.disabled(model.busy).navigationTitle("Hardcover")
      .overlay { if model.busy { ProgressView("Contacting BookOrbit") } }
      .confirmationDialog("Disconnect Hardcover?", isPresented: $confirmDisconnect) {
        Button("Disconnect", role: .destructive) { Task { await model.disconnect() } }
      } message: {
        Text(
          "Stops future sync and removes the saved token. Records already sent remain on Hardcover."
        )
      }
      .task { await model.load() }
      .task(id: model.running) {
        guard model.running else { return }
        while !Task.isCancelled && model.running {
          do { try await Task.sleep(for: .seconds(2)) } catch { return }
          await model.reconcile()
        }
      }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { Task { await model.reconcile() } }
      }
  }
}
