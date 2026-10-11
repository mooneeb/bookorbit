import SwiftUI

struct EmailProviderEditor: View {
  let api: BookOrbitAPI
  let provider: EmailProvider?
  @State private var name = ""
  @State private var host = ""
  @State private var port = "587"
  @State private var username = ""
  @State private var password = ""
  @State private var fromName = ""
  @State private var fromAddress = ""
  @State private var auth = true
  @State private var ssl = false
  @State private var startTLS = true
  @State private var verifyTLS = true
  @State private var busy = false
  @State private var error: String?
  @Environment(\.dismiss) private var dismiss

  init(api: BookOrbitAPI, provider: EmailProvider?) {
    self.api = api
    self.provider = provider
    _name = State(initialValue: provider?.name ?? "")
    _host = State(initialValue: provider?.host ?? "")
    _port = State(initialValue: provider.map { String($0.port) } ?? "587")
    _username = State(initialValue: provider?.username ?? "")
    _fromName = State(initialValue: provider?.fromName ?? "")
    _fromAddress = State(initialValue: provider?.fromAddress ?? "")
    _auth = State(initialValue: provider?.auth ?? true)
    _ssl = State(initialValue: provider?.ssl ?? false)
    _startTLS = State(initialValue: provider?.startTls ?? true)
    _verifyTLS = State(initialValue: provider?.tlsRejectUnauthorized ?? true)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Mail server") {
          TextField("Provider name", text: $name).accessibilityIdentifier("emailProviderName")
          TextField("SMTP host", text: $host).textInputAutocapitalization(.never)
            .autocorrectionDisabled().accessibilityIdentifier("emailSMTPHost")
          TextField("SMTP port", text: $port).keyboardType(.numberPad).accessibilityIdentifier(
            "emailSMTPPort")
          Toggle("Authentication", isOn: $auth).accessibilityIdentifier("emailSMTPAuthentication")
          if auth {
            TextField("SMTP username", text: $username).textInputAutocapitalization(.never)
              .autocorrectionDisabled()
            SecureField(
              provider?.hasPassword == true
                ? "Password (blank keeps saved password)" : "SMTP password", text: $password)
          }
          Toggle("SSL", isOn: $ssl)
          Toggle("STARTTLS", isOn: $startTLS).accessibilityIdentifier("emailSMTPStartTLS")
          Toggle("Verify TLS certificate", isOn: $verifyTLS)
        }
        Section("Sender") {
          TextField("Sender name", text: $fromName)
          TextField("Sender address", text: $fromAddress).keyboardType(.emailAddress)
            .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier(
              "emailSenderAddress")
        }
        if let error { Text(error).accessibilityIdentifier("emailEditorError") }
      }
      .disabled(busy)
      .navigationTitle(provider == nil ? "Add mail provider" : "Edit mail provider")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: dismiss.callAsFunction).disabled(busy)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save", action: save).disabled(
            busy || name.trimmingCharacters(in: .whitespaces).isEmpty
              || host.trimmingCharacters(in: .whitespaces).isEmpty
              || Int(port).map { !(1...65535).contains($0) } != false
          ).accessibilityIdentifier("emailSaveProvider")
        }
      }
      .interactiveDismissDisabled(busy)
    }
  }
  private func save() {
    guard let number = Int(port), !busy else { return }
    busy = true
    error = nil
    Task {
      defer { busy = false }
      do {
        _ = try await api.saveEmailProvider(
          .init(
            name: name.trimmingCharacters(in: .whitespaces),
            host: host.trimmingCharacters(in: .whitespaces), port: number, username: username,
            password: password.isEmpty && provider != nil ? nil : password, fromName: fromName,
            fromAddress: fromAddress, auth: auth, ssl: ssl, startTls: startTLS,
            tlsRejectUnauthorized: verifyTLS), id: provider?.id)
        password = ""
        dismiss()
      } catch { self.error = emailFailureMessage(error) }
    }
  }
}

struct EmailRecipientEditor: View {
  let api: BookOrbitAPI
  let recipient: EmailRecipient?
  @State private var name = ""
  @State private var email = ""
  @State private var device = "other"
  @State private var format = ""
  @State private var busy = false
  @State private var error: String?
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      Form {
        TextField("Recipient name", text: $name).accessibilityIdentifier("emailRecipientName")
        TextField("Email address", text: $email).keyboardType(.emailAddress)
          .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier(
            "emailRecipientAddress")
        Picker("Device", selection: $device) {
          Text("Email").tag("other")
          Text("Kindle").tag("kindle")
          Text("Kobo").tag("kobo")
        }.accessibilityIdentifier("emailRecipientDevice")
        Picker("Preferred format", selection: $format) {
          Text("Server choice").tag("")
          ForEach(["epub", "pdf", "mobi", "azw3", "cbz", "cbr"], id: \.self) {
            Text($0.uppercased()).tag($0)
          }
        }
        if let error { Text(error).accessibilityIdentifier("emailEditorError") }
      }
      .disabled(busy)
      .navigationTitle(recipient == nil ? "Add recipient" : "Edit recipient")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: dismiss.callAsFunction).disabled(busy)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save", action: save).disabled(busy || name.isEmpty || !email.contains("@"))
            .accessibilityIdentifier("emailSaveRecipient")
        }
      }
      .interactiveDismissDisabled(busy)
      .onAppear {
        guard let recipient else { return }
        name = recipient.name
        email = recipient.email
        device = recipient.deviceType ?? "other"
        format = recipient.preferredFormat ?? ""
      }
    }
  }
  private func save() {
    busy = true
    error = nil
    Task {
      defer { busy = false }
      do {
        _ = try await api.saveEmailRecipient(
          .init(
            name: name.trimmingCharacters(in: .whitespaces),
            email: email.trimmingCharacters(in: .whitespaces), deviceType: device,
            preferredFormat: format.isEmpty ? nil : format, defaultTemplateId: nil),
          id: recipient?.id)
        dismiss()
      } catch { self.error = emailFailureMessage(error) }
    }
  }
}
