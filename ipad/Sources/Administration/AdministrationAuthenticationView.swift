import SwiftUI

struct AdministrationAuthenticationView: View {
  let api: BookOrbitAPI
  let user: AuthUser
  @State private var providers: [OidcProviderConfig] = []
  @State private var registration = false
  @State private var hasRegistrationPolicy = false
  @State private var passwordEnabled: Bool?
  @State private var busy = false
  @State private var message: String?
  @State private var creating = false

  var body: some View {
    List {
      AdministrationNotice(message: message)
      Section("Account policy") {
        if let passwordEnabled {
          LabeledContent(
            "Password login", value: passwordEnabled ? "Enabled" : "Disabled by server")
        }
        Toggle("Allow registration", isOn: $registration)
          .disabled(busy || !hasRegistrationPolicy)
          .accessibilityIdentifier("adminRegistrationEnabled")
        Text(
          "Password login is controlled by server deployment policy. Registration also requires password login to be enabled."
        )
        .font(.caption)
        Button("Save registration policy", action: saveRegistration)
          .disabled(busy || !hasRegistrationPolicy)
          .accessibilityIdentifier("adminSaveRegistration")
      }
      Section("OpenID Connect providers") {
        ForEach(providers) { provider in
          NavigationLink {
            AdministrationOIDCEditor(api: api, user: user, provider: provider)
          } label: {
            VStack(alignment: .leading) {
              Text(provider.displayName)
              Text(provider.enabled ? "Enabled" : "Disabled").font(.caption)
            }
          }.accessibilityIdentifier("adminOIDC_\(provider.slug)")
        }
        Button("Add OIDC provider", action: create).disabled(busy)
          .accessibilityIdentifier("adminCreateOIDC")
      }
      if user.isSuperuser {
        Section("Shared account policy") {
          Text(
            "Magic links are limited to shared accounts and are managed by superusers. Their active state and expiry are enforced by the server."
          )
        }
      }
    }.navigationTitle("Authentication")
      .toolbar {
        Button("Reload", action: reload).disabled(busy).accessibilityIdentifier(
          "adminReloadAuthentication")
      }
      .sheet(isPresented: $creating, onDismiss: reload) {
        NavigationStack { AdministrationOIDCEditor(api: api, user: user, provider: nil) }
      }
      .task { await load() }
  }

  private func create() { creating = true }
  private func reload() { Task { await load() } }
  private func load() async {
    guard user.hasPermission(.manageAppSettings), !busy else { return }
    busy = true
    defer { busy = false }
    do {
      let settings = try await api.administrationSettings()
      let policy = settings.first { $0.key == "allow_registration" }
      hasRegistrationPolicy = policy != nil
      registration = policy?.value == "true"
      passwordEnabled = try await api.loginOptions().passwordLoginEnabled
      providers = try await api.administrationOIDC()
      message = nil
    } catch {
      providers = []
      message = error.localizedDescription
    }
  }
  private func saveRegistration() {
    guard user.hasPermission(.manageAppSettings), !busy, hasRegistrationPolicy else { return }
    busy = true
    Task {
      defer { busy = false }
      do {
        try await api.saveAdministrationPolicy(key: "allow_registration", enabled: registration)
        message = "Registration policy saved."
      } catch { message = error.localizedDescription }
    }
  }
}

struct AdministrationOIDCEditor: View {
  let api: BookOrbitAPI
  let user: AuthUser
  let provider: OidcProviderConfig?
  @Environment(\.dismiss) private var dismiss
  @State private var slug: String
  @State private var name: String
  @State private var issuer: String
  @State private var clientID: String
  @State private var secret = ""
  @State private var scopes: String
  @State private var enabled: Bool
  @State private var provision: Bool
  @State private var linking: Bool
  @State private var busy = false
  @State private var message: String?
  @State private var deleting = false

  init(api: BookOrbitAPI, user: AuthUser, provider: OidcProviderConfig?) {
    self.api = api
    self.user = user
    self.provider = provider
    _slug = State(initialValue: provider?.slug ?? "")
    _name = State(initialValue: provider?.displayName ?? "")
    _issuer = State(initialValue: provider?.issuerUri ?? "")
    _clientID = State(initialValue: provider?.clientId ?? "")
    _scopes = State(initialValue: provider?.scopes ?? "openid profile email")
    _enabled = State(initialValue: provider?.enabled ?? false)
    _provision = State(initialValue: provider?.autoProvision.enabled ?? false)
    _linking = State(initialValue: provider?.autoProvision.allowLocalLinking ?? false)
  }

  var body: some View {
    Form {
      AdministrationNotice(message: message)
      Section("Provider") {
        TextField("Slug", text: $slug).disabled(provider != nil)
          .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier(
            "adminOIDCSlug")
        TextField("Display name", text: $name).accessibilityIdentifier("adminOIDCName")
        TextField("Issuer URL", text: $issuer).keyboardType(.URL)
          .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier(
            "adminOIDCIssuer")
        TextField("Client ID", text: $clientID).textInputAutocapitalization(.never)
          .autocorrectionDisabled().accessibilityIdentifier("adminOIDCClientID")
        SecureField("New client secret (optional)", text: $secret)
          .accessibilityIdentifier("adminOIDCSecret")
        Text("Leave the secret empty to retain the existing secret.").font(.caption)
        TextField("Scopes", text: $scopes).textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Toggle("Enabled", isOn: $enabled).accessibilityIdentifier("adminOIDCEnabled")
      }
      Section("Account provisioning") {
        Toggle("Automatically create accounts", isOn: $provision)
        Toggle("Allow linking local accounts", isOn: $linking)
        Text(
          "Existing claim mappings and default permission names are retained when updating this provider."
        )
        .font(.caption)
      }
      Section {
        Button("Save provider", action: save).disabled(
          busy || slug.count < 2 || name.isEmpty || clientID.isEmpty
            || URL(string: issuer)?.host == nil
        )
        .accessibilityIdentifier("adminSaveOIDC")
        if provider != nil {
          Button("Delete provider", role: .destructive, action: reviewDelete).disabled(busy)
        }
      }
    }.disabled(busy).navigationTitle(provider?.displayName ?? "Add OIDC provider")
      .confirmationDialog(
        "Delete this OIDC provider? Linked accounts must be unlinked first.", isPresented: $deleting
      ) {
        Button("Delete provider", role: .destructive, action: remove)
        Button("Cancel", role: .cancel) {}
      }
  }

  private func save() {
    guard user.hasPermission(.manageAppSettings), !busy else { return }
    busy = true
    Task {
      defer { busy = false }
      do {
        var values: [String: JSONValue] = [
          "displayName": .string(name), "issuerUri": .string(issuer), "clientId": .string(clientID),
          "enabled": .boolean(enabled), "scopes": .string(scopes),
          "autoProvision": .object([
            "enabled": .boolean(provision), "allowLocalLinking": .boolean(linking),
            "defaultPermissionNames": .array(
              (provider?.autoProvision.defaultPermissionNames ?? []).map(JSONValue.string)),
          ]),
        ]
        if !secret.isEmpty { values["clientSecret"] = .string(secret) }
        try await api.saveAdministrationOIDC(slug: slug, existing: provider != nil, values: values)
        secret = ""
        message = "Provider saved."
        if provider == nil { dismiss() }
      } catch { message = error.localizedDescription }
    }
  }
  private func reviewDelete() { deleting = true }
  private func remove() {
    guard user.hasPermission(.manageAppSettings), let provider, !busy else { return }
    busy = true
    Task {
      defer { busy = false }
      do {
        try await api.sendEmpty(
          "app-settings/oidc/providers/\(provider.slug)", method: "DELETE", expectedStatus: 204)
        dismiss()
      } catch { message = error.localizedDescription }
    }
  }
}
