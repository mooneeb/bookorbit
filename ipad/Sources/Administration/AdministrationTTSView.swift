import SwiftUI

struct AdministrationTTSView: View {
  let api: BookOrbitAPI
  let user: AuthUser
  @State private var providers: [AdminTtsProvider] = []
  @State private var message: String?
  @State private var busy = false
  @State private var creating = false
  var body: some View {
    List {
      AdministrationNotice(message: message)
      ForEach(providers) { provider in
        NavigationLink {
          AdministrationTTSEditor(api: api, user: user, provider: provider)
        } label: {
          VStack(alignment: .leading) {
            Text(provider.name)
            Text(provider.enabled ? "Enabled" : "Disabled").font(.caption)
          }
        }.accessibilityIdentifier("adminTTS_\(provider.id)")
      }
      Button("Add speech provider", action: create).disabled(busy)
        .accessibilityIdentifier("adminCreateTTS")
    }.navigationTitle("Speech providers")
      .toolbar { Button("Reload", action: reload).disabled(busy) }
      .sheet(isPresented: $creating, onDismiss: reload) {
        NavigationStack { AdministrationTTSEditor(api: api, user: user, provider: nil) }
      }.task { await load() }
  }
  private func create() { creating = true }
  private func reload() { Task { await load() } }
  private func load() async {
    guard user.hasPermission(.manageAppSettings), !busy else { return }
    busy = true
    defer { busy = false }
    do {
      providers = try await api.administrationTTS()
      message = nil
    } catch {
      providers = []
      message = error.localizedDescription
    }
  }
}

struct AdministrationTTSEditor: View {
  let api: BookOrbitAPI
  let user: AuthUser
  let provider: AdminTtsProvider?
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var baseURL: String
  @State private var model: String
  @State private var enabled: Bool
  @State private var discovery: Bool
  @State private var apiKey = ""
  @State private var busy = false
  @State private var message: String?
  @State private var deleting = false
  init(api: BookOrbitAPI, user: AuthUser, provider: AdminTtsProvider?) {
    self.api = api
    self.user = user
    self.provider = provider
    _name = State(initialValue: provider?.name ?? "")
    _baseURL = State(initialValue: provider?.baseUrl ?? "")
    _model = State(initialValue: provider?.defaultModel ?? "")
    _enabled = State(initialValue: provider?.enabled ?? true)
    _discovery = State(initialValue: provider?.supportsVoiceDiscovery ?? true)
  }
  var body: some View {
    Form {
      AdministrationNotice(message: message)
      Section("OpenAI compatible speech service") {
        TextField("Name", text: $name).accessibilityIdentifier("adminTTSName")
        TextField("Base URL", text: $baseURL).keyboardType(.URL)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
          .accessibilityIdentifier("adminTTSBaseURL")
        SecureField("New API key (optional)", text: $apiKey).accessibilityIdentifier(
          "adminTTSAPIKey")
        Text("Leave the API key empty to retain the existing credential.").font(.caption)
        TextField("Default model (optional)", text: $model).textInputAutocapitalization(.never)
          .autocorrectionDisabled().accessibilityIdentifier("adminTTSModel")
        if provider != nil { Toggle("Discover voices from service", isOn: $discovery) }
        if provider != nil { Toggle("Enabled", isOn: $enabled) }
        Button("Save speech provider", action: save).disabled(
          busy || name.isEmpty || URL(string: baseURL)?.host == nil
        )
        .accessibilityIdentifier("adminSaveTTS")
        if provider != nil {
          Button("Test service connection", action: test).disabled(busy)
            .accessibilityIdentifier("adminTestTTS")
          Button("Delete speech provider", role: .destructive, action: reviewDelete).disabled(busy)
        }
      }
    }.disabled(busy).navigationTitle(provider?.name ?? "Add speech provider")
      .confirmationDialog("Delete this speech provider?", isPresented: $deleting) {
        Button("Delete speech provider", role: .destructive, action: remove)
        Button("Cancel", role: .cancel) {}
      }
  }
  private func perform(_ operation: @escaping () async throws -> Void) {
    guard user.hasPermission(.manageAppSettings), !busy else { return }
    busy = true
    Task {
      defer { busy = false }
      do { try await operation() } catch { message = error.localizedDescription }
    }
  }
  private func save() {
    perform {
      var values: [String: JSONValue] = [
        "name": .string(name), "baseUrl": .string(baseURL), "defaultModel": .string(model),
        "supportsVoiceDiscovery": .boolean(discovery),
      ]
      if provider != nil { values["enabled"] = .boolean(enabled) }
      if !apiKey.isEmpty { values["apiKey"] = .string(apiKey) }
      try await api.saveAdministrationTTS(id: provider?.id, values: values)
      apiKey = ""
      message = "Speech provider saved."
      if provider == nil { dismiss() }
    }
  }
  private func test() {
    guard let provider else { return }
    perform {
      let result: TtsProviderStatus = try await api.boundedJSONOnline(
        "tts/admin/providers/\(provider.id)/test", method: "POST", expectedStatus: 201)
      message =
        result.connected
        ? "Connection verified. \(Int(result.voiceCount)) voices available."
        : result.error ?? "Connection failed."
    }
  }
  private func reviewDelete() { deleting = true }
  private func remove() {
    guard let provider else { return }
    perform {
      try await api.sendEmpty(
        "tts/admin/providers/\(provider.id)", method: "DELETE", expectedStatus: 204)
      dismiss()
    }
  }
}
