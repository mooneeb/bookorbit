import SwiftUI

struct KoboSubscriptionsView: View {
  let api: BookOrbitAPI
  @State private var collections: CollectionModel
  @State private var scopes: SmartScopeModel
  @State private var showScopes = false
  @State private var isUpdating = false
  @State private var error: String?

  init(api: BookOrbitAPI) {
    self.api = api
    _collections = State(initialValue: CollectionModel(api: api, ownedOnly: true))
    _scopes = State(initialValue: SmartScopeModel(api: api))
  }

  var body: some View {
    List {
      Section {
        Picker("Subscription type", selection: $showScopes) {
          Text("Collections").tag(false)
          Text("Smart scopes").tag(true)
        }.pickerStyle(.segmented)
          .accessibilityIdentifier("koboSubscriptionType")
        Text(
          "Subscribed content is available to all your registered Kobo devices on their next sync.")
      }
      if let message = error ?? (showScopes ? scopes.error : collections.error) {
        Section("Could not update subscriptions") {
          Text(message).accessibilityIdentifier("koboSubscriptionError")
          Button("Try again", action: reload)
        }
      }
      if showScopes {
        ForEach(scopes.items) { scope in
          Toggle(
            scope.name,
            isOn: Binding(get: { scope.koboSyncEnabled }, set: { subscribe(scope, enabled: $0) })
          )
          .accessibilityIdentifier("koboScope\(scope.id)")
        }
      } else {
        ForEach(collections.items) { collection in
          Toggle(
            collection.name,
            isOn: Binding(
              get: { collection.syncToKobo }, set: { subscribe(collection, enabled: $0) })
          )
          .accessibilityIdentifier("koboCollection\(collection.id)")
        }
      }
      Section {
        Text(
          "Page \((showScopes ? scopes.page : collections.page) + 1), \(showScopes ? scopes.total : collections.total) results"
        )
        HStack {
          Button("Previous", action: previous).disabled(
            showScopes ? !scopes.canGoBack : !collections.canGoBack)
          Spacer()
          Button("Next", action: next).disabled(
            showScopes ? !scopes.canGoNext : !collections.canGoNext)
        }
      }
    }
    .accessibilityIdentifier("koboSubscriptionsContent")
    .navigationTitle("Kobo subscriptions")
    .disabled(isUpdating || collections.isBusy || scopes.isBusy)
    .searchable(text: search, prompt: "Search subscriptions")
    .onSubmit(of: .search, reload)
    .onChange(of: showScopes) { _, _ in reload() }
    .task {
      await collections.load()
    }
  }

  private var search: Binding<String> {
    Binding(
      get: { showScopes ? scopes.search : collections.search },
      set: {
        if showScopes { scopes.search = $0 } else { collections.search = $0 }
      })
  }
  private func reload() {
    Task { if showScopes { await scopes.load() } else { await collections.load() } }
  }
  private func previous() {
    Task { if showScopes { await scopes.previousPage() } else { await collections.previousPage() } }
  }
  private func next() {
    Task { if showScopes { await scopes.nextPage() } else { await collections.nextPage() } }
  }
  private func subscribe(_ collection: BookCollection, enabled: Bool) {
    Task {
      guard !isUpdating else { return }
      isUpdating = true
      error = nil
      defer { isUpdating = false }
      do {
        let _: BookCollection = try await api.boundedJSON(
          "collections/\(collection.id)", method: "PATCH",
          body: JSONEncoder().encode(UpdateCollectionPayload(syncToKobo: enabled)),
          byteLimit: 32 * 1024)
        await collections.refresh()
      } catch { self.error = error.localizedDescription }
    }
  }
  private func subscribe(_ scope: BookSmartScope, enabled: Bool) {
    Task {
      guard !isUpdating else { return }
      isUpdating = true
      error = nil
      defer { isUpdating = false }
      do { try await scopes.setKoboSync(scope, enabled: enabled) } catch {
        self.error = error.localizedDescription
      }
    }
  }
}
