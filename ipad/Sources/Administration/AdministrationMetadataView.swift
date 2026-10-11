import SwiftUI

struct AdministrationMetadataView: View {
  let api: BookOrbitAPI
  let user: AuthUser
  @State private var providers: [ProviderStatus] = []
  @State private var fields: [String: FieldPreference] = [:]
  @State private var message: String?
  @State private var busy = false

  var body: some View {
    List {
      AdministrationNotice(message: message)
      Section("Metadata providers") {
        ForEach(providers, id: \.key) { provider in
          VStack(alignment: .leading) {
            Toggle(provider.label, isOn: providerBinding(provider)).disabled(busy)
              .accessibilityIdentifier("adminProvider_\(provider.key)")
            if let hint = provider.hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
          }
        }
      }
      Section("Global field rules") {
        Text("Library overrides take precedence. Rules apply to future metadata fetches.")
          .font(.caption)
        ForEach(fields.keys.sorted(), id: \.self) { field in
          if let rule = fields[field] {
            NavigationLink {
              AdministrationMetadataRuleEditor(api: api, user: user, field: field, rule: rule)
            } label: {
              VStack(alignment: .leading) {
                Text(field)
                Text(rule.enabled ? rule.mergeStrategy : "Disabled").font(.caption)
              }
            }.accessibilityIdentifier("adminMetadataRule_\(field)")
          }
        }
      }
    }.navigationTitle("Metadata providers and rules")
      .toolbar { Button("Reload", action: reload).disabled(busy) }
      .task { await load() }
  }
  private func reload() { Task { await load() } }
  private func load() async {
    guard user.hasPermission(.manageMetadataConfig), !busy else { return }
    busy = true
    defer { busy = false }
    do {
      let response: AdminMetadataProviderStatusResponse = try await api.boundedJSONOnline(
        "metadata-preferences/providers", expectedStatus: 200)
      providers = response.statuses
      let result: MetadataFetchPreferences = try await api.boundedJSONOnline(
        "metadata-preferences/global", expectedStatus: 200)
      fields = try JSONDecoder().decode(
        [String: FieldPreference].self, from: JSONEncoder().encode(result.fields))
      message = nil
    } catch {
      providers = []
      fields = [:]
      message = error.localizedDescription
    }
  }
  private func providerBinding(_ provider: ProviderStatus) -> Binding<Bool> {
    Binding(
      get: { providers.first { $0.key == provider.key }?.enabled ?? provider.enabled },
      set: { enabled in
        guard user.hasPermission(.manageMetadataConfig), !busy else { return }
        busy = true
        Task {
          do {
            let body: [String: JSONValue] = [provider.key: .object(["enabled": .boolean(enabled)])]
            try await api.sendEmpty(
              "metadata-preferences/providers", method: "PUT", body: JSONEncoder().encode(body),
              expectedStatus: 200)
            message = "Provider configuration saved."
            if let index = providers.firstIndex(where: { $0.key == provider.key }) {
              providers[index].enabled = enabled
            }
          } catch { message = error.localizedDescription }
          busy = false
        }
      })
  }
}

struct AdministrationMetadataRuleEditor: View {
  let api: BookOrbitAPI
  let user: AuthUser
  let field: String
  @State private var rule: FieldPreference
  @State private var providerOrder: String
  @State private var busy = false
  @State private var message: String?
  init(api: BookOrbitAPI, user: AuthUser, field: String, rule: FieldPreference) {
    self.api = api
    self.user = user
    self.field = field
    _rule = State(initialValue: rule)
    _providerOrder = State(initialValue: rule.providers.joined(separator: ", "))
  }
  var body: some View {
    Form {
      AdministrationNotice(message: message)
      Section("Field rule") {
        Toggle("Fetch this field", isOn: $rule.enabled).accessibilityIdentifier(
          "adminMetadataRuleEnabled")
        Picker("Merge strategy", selection: $rule.mergeStrategy) {
          Text("Fill missing").tag("fillMissing")
          Text("Overwrite").tag("overwrite")
          Text("Overwrite when provided").tag("overwriteIfProvided")
          if field == "genres" { Text("Merge existing").tag("mergeExisting") }
        }
        TextField("Provider keys in order", text: $providerOrder)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
          .accessibilityIdentifier("adminMetadataProviderOrder")
        Text("Separate existing provider keys with commas. The server validates each key.")
          .font(.caption)
        Button("Save rule", action: save).disabled(busy)
          .accessibilityIdentifier("adminSaveMetadataRule")
      }
    }.navigationTitle(field)
  }
  private func save() {
    guard user.hasPermission(.manageMetadataConfig), !busy else { return }
    busy = true
    Task {
      defer { busy = false }
      do {
        rule.providers = providerOrder.split(separator: ",").map {
          $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        var latest: MetadataFetchPreferences = try await api.boundedJSONOnline(
          "metadata-preferences/global", expectedStatus: 200)
        var current = try JSONDecoder().decode(
          [String: FieldPreference].self, from: JSONEncoder().encode(latest.fields))
        current[field] = rule
        latest.fields = try JSONDecoder().decode(
          MetadataFetchPreferencesFields.self, from: JSONEncoder().encode(current))
        try await api.sendEmpty(
          "metadata-preferences/global", method: "PUT", body: JSONEncoder().encode(latest),
          expectedStatus: 200)
        message = "Metadata rule saved."
      } catch { message = error.localizedDescription }
    }
  }
}
