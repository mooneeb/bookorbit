import SwiftUI

struct EmailSettingsView: View {
  @State private var model: EmailSettingsModel
  @State private var providerEditor: ProviderEditorDestination?
  @State private var recipientEditor = false
  @State private var editingRecipient: EmailRecipient?
  @State private var providerID = 0
  @State private var recipientID = 0
  @Environment(\.dismiss) private var dismiss

  init(api: BookOrbitAPI, user: AuthUser) {
    _model = State(initialValue: EmailSettingsModel(api: api, user: user))
  }

  var body: some View {
    NavigationStack {
      List {
        if model.canSend {
          Section("Defaults") {
            Picker("Mail provider", selection: $providerID) {
              Text("No default provider").tag(0)
              ForEach(model.providers) { provider in Text(provider.name).tag(provider.id) }
            }.accessibilityIdentifier("emailDefaultProvider")
            Picker("Recipient", selection: $recipientID) {
              Text("No default recipient").tag(0)
              ForEach(model.recipients) { recipient in Text(recipient.name).tag(recipient.id) }
            }.accessibilityIdentifier("emailDefaultRecipient")
            VStack(alignment: .leading, spacing: 12) {
              Button("Save defaults", action: saveDefaults)
                .accessibilityIdentifier("emailSaveDefaults")
              if model.feedbackContext == .defaults { feedback(retry: saveDefaults) }
            }
          }
          Section("Mail providers") {
            ForEach(model.providers) { provider in
              VStack(alignment: .leading, spacing: 8) {
                Text(provider.name).font(.headline)
                Text("\(provider.host):\(provider.port)").font(.subheadline)
                if provider.isShared { Text("Shared provider").font(.caption) }
                if model.canManage {
                  Button("Test connection") { Task { await model.test(provider) } }
                    .accessibilityIdentifier("emailTestProvider\(provider.id)")
                  if provider.userId == model.user.id {
                    Button("Edit provider") {
                      providerEditor = ProviderEditorDestination(provider: provider)
                    }.accessibilityIdentifier("emailEditProvider\(provider.id)")
                    if !provider.isSystemProvider {
                      Button("Delete provider", role: .destructive) {
                        Task { await model.delete(provider) }
                      }
                    }
                  }
                }
              }
            }
            if model.canManage {
              Button("Add mail provider") {
                providerEditor = ProviderEditorDestination(provider: nil)
              }.accessibilityIdentifier("emailAddProvider")
            }
          }
          Section("Recipients and Kindle") {
            ForEach(model.recipients) { recipient in
              VStack(alignment: .leading, spacing: 8) {
                Text(recipient.name).font(.headline)
                Text(recipient.email)
                Text(
                  recipient.deviceType == "kindle"
                    ? "Kindle conversion subject enabled" : "Email attachment"
                )
                .font(.caption)
                Button("Edit recipient") {
                  editingRecipient = recipient
                  recipientEditor = true
                }.accessibilityIdentifier("emailEditRecipient\(recipient.id)")
                Button("Delete recipient", role: .destructive) {
                  Task { await model.delete(recipient) }
                }
              }
            }
            Button("Add recipient") {
              editingRecipient = nil
              recipientEditor = true
            }.accessibilityIdentifier("emailAddRecipient")
            Text(
              "For Kindle, add the provider's sender address to your Amazon approved sender list. The mail server accepting a message does not confirm Kindle delivery."
            )
            .font(.footnote)
          }
          Section("Send history") {
            ForEach(model.history) { entry in
              EmailHistoryRow(entry: entry) { Task { await model.resend(entry) } }
            }
            HStack {
              Button("Previous") { Task { await model.historyPage(model.historyPage - 1) } }
                .disabled(model.historyPage == 0)
              Spacer()
              Text("Page \(model.historyPage + 1)")
              Spacer()
              Button("Next") { Task { await model.historyPage(model.historyPage + 1) } }.disabled(
                model.history.count < 20)
            }
            Button("Refresh history") { Task { await model.load() } }.accessibilityIdentifier(
              "emailRefreshHistory")
          }
          if model.busy { ProgressView("Contacting mail settings…") }
        } else {
          Text("Your account cannot send books by email.")
        }
      }
      .disabled(model.busy)
      .safeAreaInset(edge: .bottom) {
        if model.feedbackContext != .defaults, model.notice != nil || model.error != nil {
          feedback(retry: reload)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .systemBackground))
            .disabled(model.busy)
        }
      }
      .navigationTitle("Email and Kindle")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done", action: dismiss.callAsFunction)
        }
      }
      .task {
        await model.load()
        providerID = model.preferences?.defaultProviderId ?? 0
        recipientID = model.preferences?.defaultRecipientId ?? 0
      }
      .sheet(item: $providerEditor, onDismiss: reload) { destination in
        EmailProviderEditor(api: model.api, provider: destination.provider)
      }
      .sheet(isPresented: $recipientEditor, onDismiss: reload) {
        EmailRecipientEditor(api: model.api, recipient: editingRecipient)
      }
    }
  }
  private struct ProviderEditorDestination: Identifiable {
    let provider: EmailProvider?
    var id: Int { provider?.id ?? 0 }
  }

  @ViewBuilder
  private func feedback(retry: @escaping () -> Void) -> some View {
    if let notice = model.notice {
      Text(notice).accessibilityIdentifier("emailSettingsNotice")
    }
    if let error = model.error {
      Text(error).accessibilityIdentifier("emailSettingsError")
      Button("Try again", action: retry)
    }
  }
  private func saveDefaults() {
    Task { await model.setDefaults(providerID: providerID, recipientID: recipientID) }
  }
  private func reload() { Task { await model.load() } }
}

struct EmailHistoryRow: View {
  let entry: EmailSendLogEntry
  let resend: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(entry.toName ?? entry.toEmail).font(.headline)
      Text(entry.toEmail)
      Text(entry.statusLabel).accessibilityIdentifier("emailStatus\(entry.id)")
      Text(
        "Book \(entry.bookId.map(String.init) ?? "removed"), file \(entry.bookFileId.map(String.init) ?? "removed")"
      ).font(.caption)
      if let sentAt = entry.sentAt { Text("Accepted: \(sentAt)").font(.caption) }
      if let retry = entry.nextRetryAt { Text("Next retry: \(retry)").font(.caption) }
      if let error = entry.errorMessage { Text(error).font(.caption) }
      if entry.status == "failed" {
        Button("Retry email", action: resend).accessibilityIdentifier("emailRetry\(entry.id)")
      }
    }
  }
}
