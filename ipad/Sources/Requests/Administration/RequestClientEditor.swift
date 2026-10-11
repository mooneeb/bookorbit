import SwiftUI

struct RequestClientEditor: View {
  @Bindable var model: RequestAdministrationModel
  let client: DownloadClientItem?
  @Environment(\.dismiss) private var dismiss
  @State private var color: String
  @State private var name: String
  @State private var adapter: String
  @State private var baseURL: String
  @State private var username: String
  @State private var password = ""
  @State private var replacePassword = false
  @State private var enabled: Bool
  @State private var priority: Double
  @State private var category: String
  @State private var privateAddress: Bool
  @State private var hardlinks: Bool
  @State private var mappings: [RequestPathMappingDraft]

  init(model: RequestAdministrationModel, client: DownloadClientItem?) {
    self.model = model
    self.client = client
    _color = State(initialValue: client?.color ?? "")
    _name = State(initialValue: client?.name ?? "")
    _adapter = State(initialValue: client?.adapterType ?? "qbittorrent")
    _baseURL = State(initialValue: client?.baseUrl ?? "")
    _username = State(initialValue: client?.username ?? "")
    _enabled = State(initialValue: client?.enabled ?? true)
    _priority = State(initialValue: client?.priority ?? 1)
    _category = State(initialValue: client?.category ?? "bookorbit")
    _privateAddress = State(initialValue: client?.allowPrivateAddress ?? false)
    _hardlinks = State(initialValue: client?.useHardlinks ?? true)
    _mappings = State(
      initialValue: client?.pathMappings.map {
        RequestPathMappingDraft(remote: $0.remotePath, local: $0.localPath)
      } ?? [RequestPathMappingDraft(remote: "", local: "")])
  }

  var body: some View {
    Form {
      Section("Connection") {
        TextField("Client name", text: $name).accessibilityIdentifier("requestClientName")
        Picker("Adapter", selection: $adapter) {
          ForEach(["qbittorrent", "transmission", "deluge", "nzbget", "sabnzbd"], id: \.self) {
            Text($0).tag($0)
          }
        }.disabled(client != nil)
        TextField("Base URL", text: $baseURL).textInputAutocapitalization(.never)
          .autocorrectionDisabled().keyboardType(.URL).accessibilityIdentifier("requestClientURL")
        if adapter != "sabnzbd" {
          TextField("Username", text: $username).textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        if client?.hasPassword == true {
          Toggle("Replace stored credential", isOn: $replacePassword)
        }
        if client?.hasPassword != true || replacePassword {
          SecureField(adapter == "sabnzbd" ? "API key" : "Password", text: $password).disabled(
            !model.encryptionConfigured)
        }
        if replacePassword { Text("An empty value clears the stored credential.").font(.caption) }
        RequestColorPicker(selection: $color, identifier: "requestClientColor")
        Toggle("Enabled", isOn: $enabled)
        Toggle("Allow private network address", isOn: $privateAddress).accessibilityIdentifier(
          "requestClientPrivateAddress")
      }
      Section("Delivery") {
        Stepper("Priority: \(Int(priority))", value: $priority, in: 1...100, step: 1)
        TextField("Category", text: $category).textInputAutocapitalization(.never)
        Toggle("Use hardlinks when available", isOn: $hardlinks)
      }
      Section("Server path mappings") {
        Text("Map the download client's paths to directories the BookOrbit server can read.").font(
          .caption)
        ForEach($mappings) { $mapping in
          TextField("Remote path", text: $mapping.remote).textInputAutocapitalization(.never)
            .autocorrectionDisabled().accessibilityIdentifier("requestClientRemotePath")
          TextField("Server local path", text: $mapping.local).textInputAutocapitalization(.never)
            .autocorrectionDisabled().accessibilityIdentifier("requestClientLocalPath")
        }.onDelete(perform: deleteMapping)
        Button("Add path mapping", action: addMapping).disabled(mappings.count >= 20)
      }
      if let error = model.error {
        Section { Text(error).accessibilityIdentifier("requestAdminError") }
      }
      Button("Save download client", action: save).accessibilityIdentifier("requestClientSave")
        .disabled(name.isEmpty || baseURL.isEmpty || mappings.isEmpty || model.busy)
    }
    .navigationTitle(client == nil ? "Add download client" : "Edit download client")
    .disabled(model.busy)
  }

  private func deleteMapping(_ offsets: IndexSet) { mappings.remove(atOffsets: offsets) }
  private func addMapping() { mappings.append(RequestPathMappingDraft(remote: "", local: "")) }
  private func save() {
    Task {
      guard !model.busy else { return }
      await model.perform {
        guard mappings.allSatisfy({ $0.remote.hasPrefix("/") && $0.local.hasPrefix("/") }) else {
          throw ConnectionError.invalidResponse
        }
        var body: [String: Any] = [
          "name": name, "baseUrl": baseURL, "username": username, "enabled": enabled,
          "priority": Int(priority), "category": category, "allowPrivateAddress": privateAddress,
          "useHardlinks": hardlinks,
          "pathMappings": mappings.map { ["remotePath": $0.remote, "localPath": $0.local] },
        ]
        body["color"] = color.isEmpty ? NSNull() : color as Any
        if client == nil { body["adapterType"] = adapter }
        if client == nil || replacePassword { body["password"] = password }
        _ = try await model.api.saveRequestDownloadClient(
          id: client?.id, body: JSONSerialization.data(withJSONObject: body))
        password = ""
      }
      if model.error == nil {
        await model.load()
        dismiss()
      }
    }
  }
}

private struct RequestPathMappingDraft: Identifiable {
  let id = UUID()
  var remote: String
  var local: String
}

struct RequestClientReconciliationView: View {
  let api: BookOrbitAPI
  let clientID: Int
  @State private var result: DownloadClientReconciliationResult?
  @State private var error: String?
  @State private var busy = false
  @State private var pendingRemoval: String?
  @State private var deleteFiles = false

  var body: some View {
    List {
      if let result {
        if !result.supported { Text("This client does not support reconciliation.") }
        if result.supported && result.items.isEmpty && result.missingAttempts.isEmpty {
          Text("No owned downloads to reconcile.")
            .accessibilityIdentifier("requestClientReconciliationEmpty")
        }
        if result.truncated {
          Text("Only a bounded subset is shown. Reconcile again after resolving these items.")
        }
        ForEach(result.items, id: \.clientKey) { item in
          Section(item.name) {
            Text("\(item.state): \(Int(item.progressPercent))%")
            if let attempt = item.trackedAttempt {
              Text("Request: \(attempt.requestTitle)")
            } else {
              ForEach(item.adoptableAttempts, id: \.downloadId) { attempt in
                Button("Adopt for \(attempt.requestTitle)") {
                  adopt(key: item.clientKey, id: attempt.downloadId)
                }
              }
              Button("Remove orphaned download", role: .destructive) {
                pendingRemoval = item.clientKey
              }
            }
          }
        }
        ForEach(result.missingAttempts, id: \.downloadId) { attempt in
          Text("Missing: \(attempt.requestTitle)")
        }
      }
      if let error {
        Text(error)
        Button("Retry", action: reload)
      }
      if busy { ProgressView("Checking download client") }
    }
    .navigationTitle("Client reconciliation")
    .disabled(busy)
    .task { await load() }
    .refreshable { await load() }
    .sheet(
      isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    ) {
      NavigationStack {
        Form {
          Text("Remove this orphaned download from the configured client?")
          Toggle("Also delete downloaded files", isOn: $deleteFiles)
          Button("Remove", role: .destructive, action: remove)
            .accessibilityIdentifier("requestClientRemoveOrphan")
          Button("Cancel") { pendingRemoval = nil }
        }.navigationTitle("Remove orphan")
      }.presentationDetents([.medium])
    }
  }
  private func reload() { Task { await load() } }
  private func load() async {
    guard !busy else { return }
    busy = true
    error = nil
    defer { busy = false }
    do {
      result = try await api.boundedJSON("admin/download-clients/\(clientID)/reconciliation")
    } catch { self.error = error.localizedDescription }
  }
  private func keyPath(_ key: String) -> String {
    "admin/download-clients/\(clientID)/reconciliation/\(key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?%#"))) ?? "")"
  }
  private func adopt(key: String, id: Int) {
    Task {
      guard !busy else { return }
      busy = true
      error = nil
      do {
        try await api.sendEmpty(
          keyPath(key) + "/adopt", method: "POST",
          body: JSONSerialization.data(withJSONObject: ["downloadId": id]))
      } catch { self.error = error.localizedDescription }
      busy = false
      if error == nil { await load() }
    }
  }
  private func remove() {
    guard let key = pendingRemoval else { return }
    pendingRemoval = nil
    Task {
      guard !busy else { return }
      busy = true
      error = nil
      do {
        try await api.sendEmpty(
          keyPath(key), method: "DELETE",
          body: JSONSerialization.data(withJSONObject: ["deleteFiles": deleteFiles]),
          expectedStatus: 204)
      } catch { self.error = error.localizedDescription }
      busy = false
      if error == nil { await load() }
    }
  }
}
