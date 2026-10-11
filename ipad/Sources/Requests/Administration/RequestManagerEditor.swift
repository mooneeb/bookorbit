import SwiftUI

struct RequestManagerEditor: View {
  @Bindable var model: RequestAdministrationModel
  let manager: IndexerManagerItem?
  @Environment(\.dismiss) private var dismiss
  @State private var color: String
  @State private var network: RequestNetworkProfileDraft
  @State private var name: String
  @State private var url: String
  @State private var credential = ""
  @State private var replace = false
  @State private var enabled: Bool
  @State private var privateAddress: Bool
  @State private var syncNew: Bool
  @State private var expand: Bool
  @State private var inheritSeed: Bool
  @State private var timeout: Double
  @State private var budget: Double

  init(model: RequestAdministrationModel, manager: IndexerManagerItem?) {
    self.model = model
    self.manager = manager
    _color = State(initialValue: manager?.color ?? "")
    _network = State(
      initialValue: RequestNetworkProfileDraft(
        resolvers: manager?.networkProfile?.resolvers, proxyURL: manager?.networkProfile?.proxyUrl))
    _name = State(initialValue: manager?.name ?? "")
    _url = State(initialValue: manager?.baseUrl ?? "")
    _enabled = State(initialValue: manager?.enabled ?? true)
    _privateAddress = State(initialValue: manager?.allowPrivateAddress ?? false)
    _syncNew = State(initialValue: manager?.syncNewIndexers ?? true)
    _expand = State(initialValue: manager?.autoExpandCategories ?? true)
    _inheritSeed = State(initialValue: manager?.inheritSeedLimits ?? true)
    _timeout = State(initialValue: manager?.perIndexerTimeoutSeconds ?? 15)
    _budget = State(initialValue: manager?.overallSearchBudgetSeconds ?? 30)
  }
  var body: some View {
    Form {
      TextField("Manager name", text: $name).accessibilityIdentifier("requestManagerName")
      TextField("Prowlarr URL", text: $url).keyboardType(.URL).textInputAutocapitalization(.never)
        .autocorrectionDisabled().accessibilityIdentifier("requestManagerURL")
      if manager?.hasCredential == true { Toggle("Replace API key", isOn: $replace) }
      if manager?.hasCredential != true || replace {
        SecureField("API key", text: $credential).disabled(!model.encryptionConfigured)
          .accessibilityIdentifier("requestManagerCredential")
      }
      RequestColorPicker(selection: $color, identifier: "requestManagerColor")
      Toggle("Enabled", isOn: $enabled)
      Toggle("Allow private network address", isOn: $privateAddress)
        .accessibilityIdentifier("requestManagerPrivateAddress")
      Toggle("Enable newly discovered sources", isOn: $syncNew)
      Toggle("Expand categories automatically", isOn: $expand)
      Toggle("Inherit tracker seed limits", isOn: $inheritSeed)
      Stepper("Source timeout: \(Int(timeout)) seconds", value: $timeout, in: 5...180)
      Stepper("Search budget: \(Int(budget)) seconds", value: $budget, in: 5...300)
      RequestNetworkProfileFields(draft: $network)
      if let manager {
        Button("Test manager", action: test).accessibilityIdentifier("requestManagerTest")
        Button("Sync sources", action: sync).accessibilityIdentifier("requestManagerSync")
        Section("Managed sources") {
          ForEach(manager.sources) { source in
            Button("\(source.enabled ? "Disable" : "Enable") \(source.name)") { toggle(source) }
            if !source.available { Text("Unavailable at the last sync").font(.caption) }
          }
        }
      }
      if let feedback = model.feedback { Text(feedback) }
      if let error = model.error { Text(error) }
      Button("Save manager", action: save).accessibilityIdentifier("requestManagerSave").disabled(
        name.isEmpty || url.isEmpty || (manager == nil && credential.isEmpty))
    }
    .navigationTitle(manager == nil ? "Add Prowlarr" : "Edit Prowlarr")
    .disabled(model.busy)
  }
  private func save() {
    Task {
      guard !model.busy else { return }
      await model.perform {
        var body: [String: Any] = [
          "name": name, "baseUrl": url, "enabled": enabled, "allowPrivateAddress": privateAddress,
          "syncNewIndexers": syncNew, "autoExpandCategories": expand,
          "inheritSeedLimits": inheritSeed, "perIndexerTimeoutSeconds": Int(timeout),
          "overallSearchBudgetSeconds": Int(budget),
        ]
        body["color"] = color.isEmpty ? NSNull() : color as Any
        body["networkProfile"] = try network.jsonObject()
        if manager == nil { body["type"] = "prowlarr" }
        if manager == nil || replace { body["credential"] = credential }
        _ = try await model.api.saveRequestIndexerManager(
          id: manager?.id, body: JSONSerialization.data(withJSONObject: body))
        credential = ""
      }
      if model.error == nil {
        await model.load()
        dismiss()
      }
    }
  }
  private func test() {
    guard let manager else { return }
    Task {
      await model.perform {
        let result = try await model.api.testRequestIndexerManager(id: manager.id)
        model.feedback =
          result.success ? "Manager connection verified." : result.error ?? "Manager test failed."
      }
    }
  }
  private func sync() {
    guard let manager else { return }
    Task {
      await model.perform {
        let result = try await model.api.syncRequestIndexerManager(id: manager.id)
        model.feedback =
          "Discovered \(result.discovered), created \(result.created), updated \(result.updated)."
      }
      if model.error == nil {
        await model.load()
        dismiss()
      }
    }
  }
  private func toggle(_ source: IndexerManagerSourceItem) {
    guard let manager else { return }
    Task {
      await model.perform {
        _ = try await model.api.setManagedRequestSource(
          managerID: manager.id, sourceID: source.id, enabled: !source.enabled)
      }
      if model.error == nil {
        await model.load()
        dismiss()
      }
    }
  }
}
