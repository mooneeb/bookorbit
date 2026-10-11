import SwiftUI

struct ReadwiseSettingsView: View {
  @State private var model: ReadwiseModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @State private var confirmingDisconnect = false

  init(api: BookOrbitAPI) { _model = State(initialValue: ReadwiseModel(api: api)) }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text(
            "Export your text highlights and their text notes to Readwise. Book titles, authors, highlight dates, and links are mapped automatically. Handwriting and PDF ink stay in BookOrbit."
          )
          .fixedSize(horizontal: false, vertical: true)
        }
        Section("Connection") {
          LabeledContent(
            "Token",
            value: model.settings?.tokenConfigured == true ? "Configured" : "Not configured"
          )
          .accessibilityIdentifier("readwiseTokenStatus")
          SecureField("Readwise access token", text: $model.token)
            .textContentType(.password)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("readwiseToken")
          Toggle("Automatically export new highlights", isOn: $model.enabled)
            .accessibilityIdentifier("readwiseEnabled")
          Toggle("Include existing highlights when saving", isOn: $model.includeExistingHighlights)
            .accessibilityIdentifier("readwiseIncludeExisting")
          Text(
            "Only your eligible highlights from books you can currently access are exported. Repeated delivery uses the same highlight identity."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          Button("Validate token", action: validate)
            .disabled(
              model.isBusy || (model.token.isEmpty && model.settings?.tokenConfigured != true)
            )
            .accessibilityIdentifier("readwiseValidateToken")
          Button("Save settings", action: save)
            .disabled(!model.canSave)
            .accessibilityIdentifier("readwiseSaveSettings")
          if model.settings?.tokenConfigured == true {
            Button("Disconnect Readwise", role: .destructive, action: confirmDisconnect)
              .disabled(model.isBusy)
              .accessibilityIdentifier("readwiseDisconnect")
          }
        }
        if model.settings?.disabledReason == "invalid_token" {
          Section {
            Text(
              "Readwise rejected your token. Enter a valid token and enable automatic export to reconnect."
            )
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("readwiseReconnectMessage")
          }
        }
        Section("Sync status") {
          Text(model.stateLabel).accessibilityIdentifier("readwiseSyncState")
          if let status = model.status {
            LabeledContent("Confirmed in this batch job", value: String(status.exportedHighlights))
              .accessibilityIdentifier("readwiseExportedHighlights")
            LabeledContent("Eligible highlights pending", value: String(status.pendingHighlights))
              .accessibilityIdentifier("readwisePendingHighlights")
            if !status.receivedBookIds.isEmpty {
              Text(
                "Latest confirmed Readwise book IDs: \(status.receivedBookIds.map(String.init).joined(separator: ", "))"
              )
              .font(.footnote)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("readwiseReceivedBookIds")
            }
            if let error = status.error {
              Text(error).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("readwiseDeliveryError")
            }
          }
          Button("Sync now", action: sync)
            .disabled(!model.canSync)
            .accessibilityIdentifier("readwiseSyncNow")
          Button("Refresh status", action: refresh)
            .disabled(model.isBusy)
            .accessibilityIdentifier("readwiseRefreshStatus")
        }
        if let feedback = model.feedback {
          Section { Text(feedback).accessibilityIdentifier("readwiseFeedback") }
        }
        if let error = model.error {
          Section {
            Text(error).fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("readwiseError")
            Button("Retry connection", action: refresh).accessibilityIdentifier("readwiseRetry")
          }
        }
      }
      .navigationTitle("Readwise")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", action: dismiss.callAsFunction)
        }
      }
      .task { await model.monitor() }
      .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
      .confirmationDialog("Disconnect Readwise?", isPresented: $confirmingDisconnect) {
        Button("Disconnect", role: .destructive, action: disconnect)
      } message: {
        Text("Your saved token is removed. Highlights already delivered to Readwise remain there.")
      }
    }
  }

  private func save() { Task { await model.save() } }
  private func validate() { Task { await model.validate() } }
  private func sync() { Task { await model.sync() } }
  private func refresh() { Task { await model.refresh() } }
  private func confirmDisconnect() { confirmingDisconnect = true }
  private func disconnect() { Task { await model.disconnect() } }
}
