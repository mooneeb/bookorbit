import SwiftUI

@MainActor @Observable final class EmailBookDeliveryModel {
  let api: BookOrbitAPI
  let user: AuthUser
  let bookID: Int
  var providers: [EmailProvider] = []
  var recipients: [EmailRecipient] = []
  var history: [EmailSendLogEntry] = []
  var providerID = 0
  var recipientID = 0
  var fileID: Int
  var busy = false
  var loaded = false
  var error: String?
  var notice: String?
  var queuedIDs: Set<Int> = []
  var tracking = false

  init(api: BookOrbitAPI, user: AuthUser, bookID: Int, fileID: Int) {
    self.api = api
    self.user = user
    self.bookID = bookID
    self.fileID = fileID
  }
  func load() async {
    guard user.hasPermission(.emailSend), !busy else { return }
    busy = true
    error = nil
    defer { busy = false }
    do {
      async let allProviders = api.emailProviders()
      async let allRecipients = api.emailRecipients()
      async let pendingPreferences = api.emailPreferences()
      let (providers, recipients, preferences) = try await (
        allProviders, allRecipients, pendingPreferences
      )
      self.providers = providers
      self.recipients = recipients
      if providerID == 0 { providerID = preferences.defaultProviderId ?? providers.first?.id ?? 0 }
      if recipientID == 0 {
        recipientID = preferences.defaultRecipientId ?? recipients.first?.id ?? 0
      }
      history = try await api.emailHistory(bookID: bookID)
      loaded = true
    } catch { self.error = emailFailureMessage(error) }
  }
  func send() async {
    guard !busy, user.hasPermission(.emailSend), fileID > 0, recipientID > 0, providerID > 0 else {
      return
    }
    busy = true
    error = nil
    notice = nil
    defer { busy = false }
    do {
      let accepted = try await api.sendEmailBook(
        .init(
          bookIds: [bookID], recipientIds: [recipientID], fileId: fileID, providerId: providerID,
          templateId: nil))
      queuedIDs = Set(accepted.logIds)
      notice = "Queued \(accepted.queued) email. Waiting for the mail server."
      history = try await api.emailHistory(bookID: bookID)
    } catch { self.error = emailFailureMessage(error) }
  }
  func refresh() async {
    do {
      history = try await api.emailHistory(bookID: bookID)
      let jobs = history.filter { queuedIDs.contains($0.id) }
      if !queuedIDs.isEmpty, jobs.count == queuedIDs.count,
        jobs.allSatisfy({ $0.status != "pending" })
      {
        notice =
          jobs.allSatisfy { $0.status == "sent" }
          ? "Accepted by mail server. Check the recipient device for final delivery."
          : "Email failed. Retry from the send history."
        queuedIDs.removeAll()
      }
      error = nil
    } catch { self.error = emailFailureMessage(error) }
  }
  func resend(_ entry: EmailSendLogEntry) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    do {
      let response = try await api.resendEmail(logID: entry.id)
      queuedIDs = Set(response.logIds)
      notice = "Retry queued."
      await refresh()
    } catch { self.error = emailFailureMessage(error) }
  }
  func track() async {
    guard !tracking else { return }
    tracking = true
    defer { tracking = false }
    for _ in 0..<30 {
      guard !queuedIDs.isEmpty, !Task.isCancelled else { return }
      await refresh()
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
    }
    if !queuedIDs.isEmpty {
      notice = "Email remains queued. Refresh history to check scheduled retries."
    }
  }
}

struct EmailBookDeliveryView: View {
  let bookTitle: String
  let files: [BookDetailFile]
  @State private var model: EmailBookDeliveryModel
  @State private var showingSettings = false
  @Environment(\.dismiss) private var dismiss

  init(
    api: BookOrbitAPI, user: AuthUser, bookID: Int, bookTitle: String, files: [BookDetailFile],
    initialFileID: Int? = nil
  ) {
    self.bookTitle = bookTitle
    self.files = files.filter {
      ["content", "primary"].contains($0.role)
        && !["mp3", "m4a", "m4b", "aac", "ogg", "flac", "wav", "opus"].contains(
          ($0.format ?? "").lowercased())
    }
    let fileID =
      self.files.first(where: { $0.id == initialFileID })?.id ?? self.files.first?.id ?? 0
    _model = State(
      initialValue: EmailBookDeliveryModel(api: api, user: user, bookID: bookID, fileID: fileID))
  }
  var body: some View {
    NavigationStack {
      Form {
        Section(bookTitle) {
          Picker("File to send", selection: $model.fileID) {
            ForEach(files) { file in
              Text("\(file.filename ?? "Book file") (\((file.format ?? "file").uppercased()))").tag(
                file.id)
            }
          }.accessibilityIdentifier("emailBookFile")
          Picker("Mail provider", selection: $model.providerID) {
            ForEach(model.providers) { Text($0.name).tag($0.id) }
          }.accessibilityIdentifier("emailBookProvider")
          Picker("Recipient", selection: $model.recipientID) {
            ForEach(model.recipients) { Text("\($0.name) (\($0.email))").tag($0.id) }
          }.accessibilityIdentifier("emailBookRecipient")
          Text(
            "The selected server file is attached when the send runs. Source PDF ink is included after it has been published to the server."
          ).font(.footnote)
          Button("Send selected file") { Task { await model.send() } }.disabled(
            model.busy || !model.loaded || model.fileID == 0 || model.providerID == 0
              || model.recipientID == 0 || !model.queuedIDs.isEmpty
          ).accessibilityIdentifier("emailSendSelectedFile")
          Button("Email settings") { showingSettings = true }
        }
        if let notice = model.notice { Text(notice).accessibilityIdentifier("emailDeliveryNotice") }
        if let error = model.error {
          Text(error).accessibilityIdentifier("emailDeliveryError")
          Button("Try again") { Task { await model.load() } }
        }
        if model.busy { ProgressView("Contacting mail server…") }
        Section("This book's send history") {
          ForEach(model.history) { entry in
            EmailHistoryRow(entry: entry) { Task { await model.resend(entry) } }
          }
          Button("Refresh history") { Task { await model.refresh() } }.accessibilityIdentifier(
            "emailDeliveryRefresh")
        }
      }
      .navigationTitle("Send by email")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done", action: dismiss.callAsFunction)
        }
      }
      .task { await model.load() }
      .task(id: model.queuedIDs) { await model.track() }
      .sheet(isPresented: $showingSettings, onDismiss: reload) {
        EmailSettingsView(api: model.api, user: model.user)
      }
    }
  }
  private func reload() { Task { await model.load() } }
}
