import SwiftUI

struct RequestAdministrationView: View {
  let session: SessionModel

  var body: some View {
    if let api = session.api, let user = session.user, user.hasPermission(.manageAppSettings) {
      RequestAdministrationContent(api: api, user: user)
        .id(
          "\(ObjectIdentifier(api))-\(user.id)-\(user.isSuperuser)-\(user.permissions.sorted().joined(separator: ","))"
        )
    } else {
      ContentUnavailableView(
        "Request settings unavailable", systemImage: "lock",
        description: Text("Your account needs permission to manage application settings."))
    }
  }
}

private struct RequestAdministrationContent: View {
  @State private var model: RequestAdministrationModel
  @State private var newSource = false
  @State private var newClient = false
  @State private var newManager = false
  @State private var pendingDeletion: String?

  init(api: BookOrbitAPI, user: AuthUser) {
    _model = State(initialValue: RequestAdministrationModel(api: api, user: user))
  }

  var body: some View {
    List {
      if !model.encryptionConfigured {
        Section {
          Text("The server needs BOOK_REQUEST_ENCRYPTION_KEY before credentials can be saved.")
            .foregroundStyle(.red)
        }
      }
      if let error = model.error {
        Section {
          Text(error).accessibilityIdentifier("requestAdminError")
          Button("Retry", action: reload)
        }
      }
      if let feedback = model.feedback {
        Section { Text(feedback).accessibilityIdentifier("requestAdminFeedback") }
      }
      Section("Sources") {
        ForEach(model.sources) { source in
          NavigationLink {
            RequestSourceEditor(model: model, source: source)
          } label: {
            VStack(alignment: .leading) {
              Text(source.name)
              Text(source.enabled ? source.adapterType : "Disabled").font(.caption).foregroundStyle(
                .secondary)
            }
          }
          .accessibilityIdentifier("requestSource\(source.id)")
          .swipeActions {
            Button("Delete", role: .destructive) {
              pendingDeletion = "admin/request-indexers/\(source.id)"
            }
          }
          Button("Test \(source.name)") { Task { await model.testSource(source) } }
        }
        Button("Add source", action: addSource).accessibilityIdentifier("requestAdminAddSource")
      }
      Section("Download clients") {
        ForEach(model.clients) { client in
          NavigationLink(client.name) { RequestClientEditor(model: model, client: client) }
            .swipeActions {
              Button("Delete", role: .destructive) {
                pendingDeletion = "admin/download-clients/\(client.id)"
              }
            }
          Button("Test \(client.name)") { Task { await model.testClient(client) } }
          ForEach(client.pathMappings) { mapping in
            Button("Test hardlink: \(mapping.remotePath)") {
              Task { await model.testMapping(clientID: client.id, mappingID: mapping.id) }
            }
          }
          NavigationLink("Reconcile \(client.name)") {
            RequestClientReconciliationView(api: model.api, clientID: client.id)
          }
        }
        Button("Add download client", action: addClient).accessibilityIdentifier(
          "requestAdminAddClient")
      }
      Section("Source managers") {
        ForEach(model.managers) { manager in
          NavigationLink(manager.name) { RequestManagerEditor(model: model, manager: manager) }
            .swipeActions {
              Button("Delete", role: .destructive) {
                pendingDeletion = "admin/request-indexer-managers/\(manager.id)"
              }
            }
        }
        Button("Add Prowlarr manager", action: addManager).accessibilityIdentifier(
          "requestAdminAddManager")
      }
      Section {
        NavigationLink("Automation and destinations") { RequestAutomationView(api: model.api) }
          .accessibilityIdentifier("requestAdminAutomation")
        if model.canManagePlugins {
          NavigationLink("Indexer plugins") { RequestPluginsView(model: model) }
            .accessibilityIdentifier("requestAdminPlugins")
        }
      }
      if !model.pluginFailures.isEmpty {
        Section("Plugin load failures") {
          ForEach(model.pluginFailures.indices, id: \.self) { index in
            Text(model.pluginFailures[index].reason)
          }
        }
      }
      if model.busy { ProgressView("Updating request settings") }
    }
    .navigationTitle("Request administration")
    .disabled(model.busy)
    .refreshable { await model.load() }
    .task { await model.load() }
    .navigationDestination(isPresented: $newSource) {
      RequestSourceEditor(model: model, source: nil)
    }
    .navigationDestination(isPresented: $newClient) {
      RequestClientEditor(model: model, client: nil)
    }
    .navigationDestination(isPresented: $newManager) {
      RequestManagerEditor(model: model, manager: nil)
    }
    .confirmationDialog(
      "Delete this configuration?", isPresented: deletionPresented, titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive, action: delete)
    } message: {
      Text("Active requests may need a replacement source or download client.")
    }
  }

  private var deletionPresented: Binding<Bool> {
    Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
  }
  private func delete() {
    guard let path = pendingDeletion else { return }
    pendingDeletion = nil
    Task { await model.remove(path: path) }
  }
  private func reload() { Task { await model.load() } }
  private func addSource() { newSource = true }
  private func addClient() { newClient = true }
  private func addManager() { newManager = true }
}
