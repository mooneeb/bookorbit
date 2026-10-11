import SwiftUI

struct CatalogSettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: CatalogSettingsModel
  @State private var scopePicker: CatalogScopeKind?
  @State private var removeKOReader = false
  @State private var removeOPDS: OpdsUser?

  init(api: BookOrbitAPI, user: AuthUser, book: BookDetail? = nil) {
    _model = State(initialValue: CatalogSettingsModel(api: api, user: user, book: book))
  }

  var body: some View {
    NavigationStack {
      Form {
        if let error = model.error {
          Section {
            Text(error).foregroundStyle(.red).accessibilityIdentifier("catalogError")
            Button("Retry", action: reload).accessibilityIdentifier("catalogRetry")
          }
        }
        if let result = model.result {
          Section { Text(result).accessibilityIdentifier("catalogResult") }
        }
        if model.canKOReader { koreaderSection }
        if model.canOPDS { opdsSection }
        if model.canKOReader || model.canOPDS { subscriptionsSection }
        if model.book != nil {
          CatalogBookSection(model: model)
        }
        if !model.canKOReader && !model.canOPDS {
          ContentUnavailableView(
            "Catalog access unavailable", systemImage: "lock",
            description: Text("Your account needs KOReader sync or OPDS access permission."))
        }
      }
      .disabled(model.isMutating)
      .overlay { if model.isBusy { ProgressView().accessibilityLabel("Loading catalog settings") } }
      .navigationTitle("KOReader and OPDS")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", action: close).disabled(model.isMutating)
        }
        ToolbarItem(placement: .topBarLeading) {
          Button("Refresh", systemImage: "arrow.clockwise", action: reload)
            .disabled(model.isBusy || model.isMutating)
        }
      }
      .task { await model.load() }
      .sheet(item: $scopePicker) { kind in
        CatalogScopePickerView(api: model.api, kind: kind) { id, name in
          Task { await model.selectScope(id: id, name: name, smart: kind == .smartScope) }
        }
      }
      .confirmationDialog("Remove KOReader credentials?", isPresented: $removeKOReader) {
        Button("Remove credentials", role: .destructive, action: deleteKOReader)
      } message: {
        Text("Devices using these credentials will lose access to sync and catalogs.")
      }
      .confirmationDialog(
        "Remove OPDS account?",
        isPresented: Binding(
          get: { removeOPDS != nil }, set: { if !$0 { removeOPDS = nil } })
      ) {
        Button("Remove account", role: .destructive, action: deleteOPDS)
      } message: {
        Text("Readers using this account will lose catalog access.")
      }
    }
  }

  private var koreaderSection: some View {
    Section("KOReader") {
      if let credentials = model.koreader?.credentials {
        LabeledContent("Sync", value: credentials.syncEnabled ? "Enabled" : "Disabled")
        Button(credentials.syncEnabled ? "Disable sync" : "Enable sync", action: toggleSync)
          .accessibilityIdentifier("catalogKOReaderToggle")
      }
      TextField("KOReader username", text: $model.koreaderUsername)
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .accessibilityIdentifier("catalogKOReaderUsername")
      SecureField(
        model.koreader?.credentials == nil ? "KOReader password" : "New password (optional)",
        text: $model.koreaderPassword
      ).accessibilityIdentifier("catalogKOReaderPassword")
      Button(
        model.koreader?.credentials == nil
          ? "Create KOReader credentials" : "Save KOReader credentials", action: saveKOReader
      )
      .disabled(!model.canSaveKOReader).accessibilityIdentifier("catalogKOReaderSave")
      Button("Test KOReader connection", action: testKOReader)
        .disabled(model.koreaderPassword.isEmpty || model.koreader?.credentials == nil)
        .accessibilityIdentifier("catalogKOReaderTest")
      if let syncURL = model.syncURL { CatalogURLRow(title: "Sync server", url: syncURL) }
      if let rootURL = model.rootURL { CatalogURLRow(title: "Plugin catalog", url: rootURL) }
      Text(
        "Use these credentials in the BookOrbit KOReader plugin. Enter the password again to test the connection."
      )
      .font(.footnote).foregroundStyle(.secondary)
      if let status = model.koreader {
        LabeledContent("Synced books", value: String(status.totalSyncedBooks))
        LabeledContent("Last sync", value: status.lastSyncAt ?? "No sync yet")
        ForEach(status.devices, id: \.deviceId) { device in
          VStack(alignment: .leading) {
            Text(device.device).font(.headline)
            Text(device.lastBookTitle ?? "No book reported").foregroundStyle(.secondary)
            Text(device.lastSyncAt).font(.caption)
            if device.retiredAt != nil { Text("Retired").font(.caption) }
          }
        }
      }
      if model.koreader?.credentials != nil {
        NavigationLink {
          KOReaderManagementView(api: model.api, user: model.user)
        } label: {
          Label("Plugin setup and device management", systemImage: "gearshape")
        }
        .accessibilityIdentifier("catalogKOReaderManagement")
        Button("Remove KOReader credentials", role: .destructive, action: confirmRemoveKOReader)
          .accessibilityIdentifier("catalogKOReaderRemove")
      }
    }
  }

  private var opdsSection: some View {
    Section("OPDS accounts") {
      if let opdsURL = model.opdsURL { CatalogURLRow(title: "Catalog", url: opdsURL) }
      Text(
        "Each account uses its own username and password. Catalogs follow your library access and content restrictions."
      )
      .font(.footnote).foregroundStyle(.secondary)
      ForEach(model.opdsAccounts, id: \.id) { account in
        VStack(alignment: .leading, spacing: 12) {
          Text(account.username).font(.headline)
            .accessibilityIdentifier("catalogOPDSAccount\(account.id)")
          Picker(
            "Sort order",
            selection: Binding(
              get: { account.sortOrder },
              set: { value in Task { await model.updateOPDS(account, sortOrder: value) } }
            )
          ) {
            ForEach(CatalogSortOrder.choices, id: \.value) { choice in
              Text(choice.label).tag(choice.value)
            }
          }
          Button("Remove \(account.username)", role: .destructive) { removeOPDS = account }
        }
      }
      TextField("OPDS username", text: $model.opdsUsername)
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .accessibilityIdentifier("catalogOPDSUsername")
      SecureField("OPDS password", text: $model.opdsPassword)
        .accessibilityIdentifier("catalogOPDSPassword")
      Picker("New account sort order", selection: $model.opdsSortOrder) {
        ForEach(CatalogSortOrder.choices, id: \.value) { choice in
          Text(choice.label).tag(choice.value)
        }
      }
      Button("Create OPDS account", action: createOPDS)
        .disabled(!model.canCreateOPDS).accessibilityIdentifier("catalogOPDSCreate")
      Button("Test OPDS connection", action: testOPDS)
        .disabled(model.opdsUsername.isEmpty || model.opdsPassword.isEmpty)
        .accessibilityIdentifier("catalogOPDSTest")
    }
  }

  private var subscriptionsSection: some View {
    Section("Collection and smart scope catalogs") {
      LabeledContent("Selection", value: model.scopeName)
        .accessibilityIdentifier("catalogScopeSelection")
      Button("Choose collection", action: chooseCollection)
        .accessibilityIdentifier("catalogChooseCollection")
      Button("Choose smart scope", action: chooseSmartScope)
        .accessibilityIdentifier("catalogChooseSmartScope")
      Button("All books", action: chooseAllBooks)
      if model.canOPDS, let url = model.selectedScopeURL {
        CatalogURLRow(title: "OPDS subscription", url: url)
      }
      if model.canKOReader, let url = model.selectedKOReaderURL {
        CatalogURLRow(title: "KOReader bulk catalog", url: url)
      }
      Text(
        "Add the selected URL in your reader. Its contents update as the collection or smart scope changes. Credentials are entered separately."
      )
      .font(.footnote).foregroundStyle(.secondary)
    }
  }

  private func close() { dismiss() }
  private func reload() { Task { await model.load() } }
  private func saveKOReader() { Task { await model.saveKOReader() } }
  private func testKOReader() { Task { await model.testKOReader() } }
  private func confirmRemoveKOReader() { removeKOReader = true }
  private func deleteKOReader() { Task { await model.deleteKOReader() } }
  private func toggleSync() {
    Task { await model.setKOReaderEnabled(!(model.koreader?.credentials?.syncEnabled ?? false)) }
  }
  private func createOPDS() { Task { await model.createOPDS() } }
  private func testOPDS() { Task { await model.testOPDS() } }
  private func deleteOPDS() {
    guard let account = removeOPDS else { return }
    removeOPDS = nil
    Task { await model.deleteOPDS(account) }
  }
  private func chooseCollection() { scopePicker = .collection }
  private func chooseSmartScope() { scopePicker = .smartScope }
  private func chooseAllBooks() {
    Task { await model.selectScope(id: nil, name: "All books", smart: false) }
  }
}

struct CatalogURLRow: View {
  let title: String
  let url: URL

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.headline)
      Text(url.absoluteString).font(.footnote).textSelection(.enabled)
      ShareLink("Share \(title)", item: url)
        .accessibilityIdentifier("catalogShare\(title.replacingOccurrences(of: " ", with: ""))")
    }
  }
}

enum CatalogSortOrder {
  static let choices: [(value: String, label: String)] = [
    ("recent", "Recently added"), ("title_asc", "Title, ascending"),
    ("title_desc", "Title, descending"), ("author_asc", "Author, ascending"),
    ("author_desc", "Author, descending"), ("series_asc", "Series, ascending"),
    ("series_desc", "Series, descending"),
  ]
}
