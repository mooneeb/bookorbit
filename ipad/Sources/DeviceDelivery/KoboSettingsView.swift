import SwiftUI

struct KoboSettingsView: View {
  let user: AuthUser
  @State private var model: KoboSettingsModel
  @State private var deviceName = ""
  @State private var editingDevice: KoboDevice?
  @State private var revokingDevice: KoboDevice?
  @Environment(\.dismiss) private var dismiss

  init(api: BookOrbitAPI, user: AuthUser) {
    self.user = user
    _model = State(initialValue: KoboSettingsModel(api: api))
  }

  var body: some View {
    NavigationStack {
      Form {
        if user.hasPermission(.koboSync) {
          Section {
            NavigationLink("Collection and scope subscriptions") {
              KoboSubscriptionsView(api: model.api)
            }.accessibilityIdentifier("koboSubscriptions")
            NavigationLink("Sync and delivery history") {
              KoboHistoryView(api: model.api)
            }.accessibilityIdentifier("koboHistory")
          } footer: {
            Text(
              "Kobo pulls subscribed books when you sync the device. History records requests received by BookOrbit."
            )
          }
          if model.isBusy { ProgressView("Updating Kobo…") }
          if model.settings != nil { settingsSection }
          Section("Devices") {
            ForEach(model.devices, id: \.id) { device in
              VStack(alignment: .leading, spacing: 8) {
                Text(device.name).font(.headline)
                Text(device.lastSeenAt.map { "Last seen: \($0)" } ?? "Has not connected yet")
                  .font(.caption).foregroundStyle(.secondary)
                HStack {
                  Button("Rename") {
                    editingDevice = device
                    deviceName = device.name
                  }
                  .accessibilityIdentifier("koboRename\(device.id)")
                  Button("Revoke credential", role: .destructive) { revokingDevice = device }
                    .accessibilityIdentifier("koboRevoke\(device.id)")
                }
              }
            }
            TextField("New Kobo device name", text: $deviceName)
              .accessibilityIdentifier("koboDeviceName")
            Button("Register Kobo device", action: register)
              .disabled(
                deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy
              )
              .accessibilityIdentifier("koboRegister")
          }
        } else {
          Text("Your account does not have permission to configure Kobo sync.")
        }
      }
      .accessibilityIdentifier("koboSettingsContent")
      .disabled(model.isBusy)
      .safeAreaInset(edge: .bottom) {
        if model.notice != nil || model.error != nil {
          VStack(alignment: .leading, spacing: 8) {
            if let notice = model.notice {
              Text(notice).accessibilityIdentifier("koboNotice")
            }
            if let error = model.error {
              Text(error).accessibilityIdentifier("koboError")
              Button("Reload Kobo settings", action: reload)
            }
          }
          .padding()
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color(uiColor: .systemBackground))
          .disabled(model.isBusy)
        }
      }
      .navigationTitle("Kobo")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done", action: dismiss.callAsFunction)
        }
      }
      .task { if user.hasPermission(.koboSync) { await model.load() } }
      .sheet(
        isPresented: Binding(
          get: { model.credentialURL != nil }, set: { if !$0 { model.credentialURL = nil } })
      ) {
        if let url = model.credentialURL { KoboCredentialView(url: url) }
      }
      .alert(
        "Rename Kobo device",
        isPresented: Binding(get: { editingDevice != nil }, set: { if !$0 { editingDevice = nil } })
      ) {
        TextField("Device name", text: $deviceName)
        Button("Cancel", role: .cancel) { editingDevice = nil }
        Button("Save", action: rename)
      }
      .confirmationDialog(
        "Revoke this Kobo credential?",
        isPresented: Binding(
          get: { revokingDevice != nil }, set: { if !$0 { revokingDevice = nil } }),
        titleVisibility: .visible
      ) {
        Button("Revoke credential", role: .destructive, action: revoke)
      } message: {
        Text("This Kobo will lose access. Register a new device to connect it again.")
      }
      .onDisappear { model.credentialURL = nil }
    }
  }

  private var settingsSection: some View {
    Section("Sync settings") {
      Toggle("Convert EPUB to KEPUB", isOn: setting(\.convertToKepub))
        .disabled(
          model.settings?.twoWayProgressSync == true
            || model.settings?.syncBookOrbitAnnotationsToKobo == true)
      Toggle("Enable hyphenation", isOn: setting(\.forceEnableHyphenation))
      Toggle("Two-way reading progress", isOn: setting(\.twoWayProgressSync))
        .accessibilityIdentifier("koboTwoWayProgress")
      Toggle("Send BookOrbit annotations to Kobo", isOn: setting(\.syncBookOrbitAnnotationsToKobo))
        .accessibilityIdentifier("koboAnnotationSync")
      Toggle("Include Kobo Store sync", isOn: setting(\.storeSync))
      Stepper(
        "Reading threshold: \(model.settings?.readingThreshold ?? 0, specifier: "%.1f")%",
        value: setting(\.readingThreshold), in: 0.5...10, step: 0.5)
      Stepper(
        "Finished threshold: \(model.settings?.finishedThreshold ?? 0, specifier: "%.0f")%",
        value: setting(\.finishedThreshold), in: 75...100)
      Stepper(
        "Conversion limit: \(model.settings?.kepubConversionLimitMb ?? 0) MB",
        value: setting(\.kepubConversionLimitMb), in: 1...500)
      Button("Save Kobo settings", action: save).accessibilityIdentifier("koboSaveSettings")
      Text(
        "Progress and text annotation exchange requires KEPUB conversion. PDF source ink travels in the current PDF file."
      )
      .font(.caption).foregroundStyle(.secondary)
    }
  }

  private func setting<T>(_ key: WritableKeyPath<KoboSyncSettings, T>) -> Binding<T> {
    Binding(get: { model.settings![keyPath: key] }, set: { model.settings?[keyPath: key] = $0 })
  }
  private func reload() { Task { await model.load() } }
  private func save() { Task { await model.save() } }
  private func register() {
    Task {
      await model.register(name: deviceName)
      if model.credentialURL != nil { deviceName = "" }
    }
  }
  private func rename() {
    guard let device = editingDevice else { return }
    editingDevice = nil
    Task {
      await model.rename(device, name: deviceName)
      deviceName = ""
    }
  }
  private func revoke() {
    guard let device = revokingDevice else { return }
    revokingDevice = nil
    Task { await model.revoke(device) }
  }
}

private struct KoboCredentialView: View {
  let url: URL
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text(
            "Use this URL as api_endpoint in your Kobo configuration. Save it now; BookOrbit will not display it again."
          )
          Text(url.absoluteString).font(.system(.body, design: .monospaced))
            .textSelection(.enabled).accessibilityIdentifier("koboCredentialURL")
          ShareLink("Share device setup URL", item: url)
        } header: {
          Text("One-time device setup URL")
        } footer: {
          Text(
            "Anyone with this credential can access your permitted Kobo content. Revoke the device if it is exposed."
          )
        }
      }
      .navigationTitle("Kobo credential")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done", action: dismiss.callAsFunction)
        }
      }
    }
  }
}
