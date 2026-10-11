import Foundation
import Observation

@MainActor @Observable final class EmailSettingsModel {
  enum FeedbackContext { case defaults, providers, recipients, history }
  var feedbackContext: FeedbackContext?
  let api: BookOrbitAPI
  let user: AuthUser
  var providers: [EmailProvider] = []
  var recipients: [EmailRecipient] = []
  var preferences: EmailPreferences?
  var history: [EmailSendLogEntry] = []
  var historyPage = 0
  var busy = false
  var loaded = false
  var error: String?
  var notice: String?

  init(api: BookOrbitAPI, user: AuthUser) {
    self.api = api
    self.user = user
  }
  var canSend: Bool { user.hasPermission(.emailSend) }
  var canManage: Bool { user.hasPermission(.manageEmail) }

  func load() async {
    guard canSend, !busy else { return }
    busy = true
    defer { busy = false }
    error = nil
    do {
      async let availableProviders = api.emailProviders()
      async let ownedRecipients = api.emailRecipients()
      async let defaults = api.emailPreferences()
      async let recent = api.emailHistory(page: historyPage)
      (providers, recipients, preferences, history) = try await (
        availableProviders, ownedRecipients, defaults, recent
      )
      loaded = true
    } catch { self.error = emailFailureMessage(error) }
  }

  func setDefaults(providerID: Int, recipientID: Int) async {
    await perform(context: .defaults) {
      self.preferences = try await self.api.saveEmailPreferences(
        .init(
          defaultProviderId: providerID == 0 ? nil : providerID,
          defaultRecipientId: recipientID == 0 ? nil : recipientID, defaultTemplateId: nil))
      self.notice = "Defaults saved."
    }
  }
  func test(_ provider: EmailProvider) async {
    guard canManage else { return }
    await perform(context: .providers) {
      let result = try await self.api.testEmailProvider(id: provider.id)
      self.notice =
        result.success
        ? "Mail server connection verified."
        : "Mail server test failed: \(result.error ?? "Connection rejected")"
    }
  }
  func delete(_ provider: EmailProvider) async {
    guard canManage, provider.userId == user.id else { return }
    await perform(context: .providers) {
      try await self.api.deleteEmailProvider(id: provider.id)
      self.providers.removeAll { $0.id == provider.id }
    }
  }
  func delete(_ recipient: EmailRecipient) async {
    await perform(context: .recipients) {
      try await self.api.deleteEmailRecipient(id: recipient.id)
      self.recipients.removeAll { $0.id == recipient.id }
    }
  }
  func resend(_ entry: EmailSendLogEntry) async {
    await perform(context: .history) {
      let result = try await self.api.resendEmail(logID: entry.id)
      self.notice = "Queued \(result.queued) email. Mail acceptance will appear in history."
      self.historyPage = 0
      self.history = try await self.api.emailHistory()
    }
  }
  func historyPage(_ page: Int) async {
    guard page >= 0 else { return }
    await perform(context: .history) {
      self.history = try await self.api.emailHistory(page: page)
      self.historyPage = page
    }
  }
  private func perform(context: FeedbackContext, _ action: () async throws -> Void) async {
    guard !busy, canSend else { return }
    busy = true
    feedbackContext = context
    error = nil
    notice = nil
    defer { busy = false }
    do { try await action() } catch { self.error = emailFailureMessage(error) }
  }
}
