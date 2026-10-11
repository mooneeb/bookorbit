import Foundation

extension BookOrbitAPI {
  func emailProviders() async throws -> [EmailProvider] { try await send("email/providers") }
  func emailRecipients() async throws -> [EmailRecipient] { try await send("email/recipients") }
  func emailPreferences() async throws -> EmailPreferences { try await send("email/preferences") }
  func emailHistory(bookID: Int? = nil, page: Int = 0) async throws -> [EmailSendLogEntry] {
    var query = [
      URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "size", value: "20"),
    ]
    if let bookID { query.append(URLQueryItem(name: "bookId", value: String(bookID))) }
    return try await send("email/log", query: query)
  }
  func saveEmailProvider(_ payload: CreateEmailProviderPayload, id: Int?) async throws
    -> EmailProvider
  {
    try await send(
      id.map { "email/providers/\($0)" } ?? "email/providers", method: id == nil ? "POST" : "PUT",
      body: JSONEncoder().encode(payload))
  }
  func saveEmailRecipient(_ payload: CreateEmailRecipientPayload, id: Int?) async throws
    -> EmailRecipient
  {
    var body =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any] ?? [:]
    if id != nil && payload.preferredFormat == nil { body["preferredFormat"] = NSNull() }
    return try await send(
      id.map { "email/recipients/\($0)" } ?? "email/recipients", method: id == nil ? "POST" : "PUT",
      body: JSONSerialization.data(withJSONObject: body))
  }
  func deleteEmailProvider(id: Int) async throws {
    try await sendEmpty("email/providers/\(id)", method: "DELETE", expectedStatus: 204)
  }
  func deleteEmailRecipient(id: Int) async throws {
    try await sendEmpty("email/recipients/\(id)", method: "DELETE", expectedStatus: 204)
  }
  func testEmailProvider(id: Int) async throws -> EmailProviderTestResponse {
    try await send("email/providers/\(id)/test", method: "POST")
  }
  func saveEmailPreferences(_ payload: UpdateEmailPreferencesPayload) async throws
    -> EmailPreferences
  {
    try await send(
      "email/preferences", method: "PUT",
      body: JSONSerialization.data(withJSONObject: [
        "defaultProviderId": payload.defaultProviderId as Any? ?? NSNull(),
        "defaultRecipientId": payload.defaultRecipientId as Any? ?? NSNull(),
      ]))
  }
  func sendEmailBook(_ payload: EmailSelectedBookSendPayload) async throws
    -> EmailSendAcceptedResponse
  {
    try await send("email/send", method: "POST", body: JSONEncoder().encode(payload))
  }
  func resendEmail(logID: Int) async throws -> EmailSendAcceptedResponse {
    try await send("email/log/\(logID)/resend", method: "POST")
  }
}

func emailFailureMessage(_ error: Error) -> String {
  switch error {
  case ConnectionError.expiredSession: "Your session expired. Sign in again to continue."
  case ConnectionError.denied: "Your account cannot perform this email action."
  case ConnectionError.http(400):
    "Check the selected file, recipient, provider, and required settings."
  case ConnectionError.http(409): "That name already exists. Choose another name."
  case ConnectionError.http(404):
    "The book, file, or email setting is no longer available. Refresh and try again."
  default: "Could not contact the server. Check your connection and try again."
  }
}

extension EmailSendLogEntry {
  var statusLabel: String {
    switch status {
    case "sent": "Accepted by mail server"
    case "failed": "Failed"
    default: nextRetryAt == nil ? "Queued" : "Retry scheduled"
    }
  }
}
