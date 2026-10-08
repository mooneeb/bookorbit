import SwiftUI

struct NativeTTSSettingsView: View {
  let model: NativeTTSModel
  @Environment(\.dismiss) private var dismiss
  @State private var speed: Double
  @State private var voiceIdentifier: String
  @State private var providerID: String
  @State private var voiceID: String
  @State private var asDefault = false

  init(model: NativeTTSModel) {
    self.model = model
    _speed = State(initialValue: model.preferences.speed)
    let installed = model.preferences.voiceIdentifier.flatMap { identifier in
      model.voices.contains(where: { $0.id == identifier }) ? identifier : nil
    }
    _voiceIdentifier = State(initialValue: installed ?? "")
    _providerID = State(
      initialValue: model.preferences.useServer ? model.preferences.providerID ?? "" : "")
    _voiceID = State(initialValue: model.preferences.voiceID ?? "")
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Speech service") {
          Picker("Service", selection: $providerID) {
            Text("System speech on this iPad").tag("")
            ForEach(model.catalog.providers) { provider in
              Text(provider.name).tag(provider.id)
            }
            if !providerID.isEmpty,
              !model.catalog.providers.contains(where: { $0.id == providerID })
            {
              Text("Saved service unavailable").tag(providerID)
            }
          }.accessibilityIdentifier("nativeTTSServicePicker")
          Text(
            providerID.isEmpty
              ? "System speech uses installed voices on this iPad. No microphone permission is needed."
              : "This service synthesizes the spoken passage through your BookOrbit server."
          )
          .font(.caption).foregroundStyle(.secondary)
          if let error = model.catalog.error {
            Text(error).accessibilityIdentifier("nativeTTSCatalogError")
          }
          Button("Refresh available services", action: refreshServices)
            .frame(minHeight: 44).disabled(model.catalog.isLoadingProviders)
            .accessibilityIdentifier("nativeTTSRefreshServices")
        }
        if providerID.isEmpty {
          Section("System voice") {
            Picker("Installed voice", selection: $voiceIdentifier) {
              Text("Automatic for book language").tag("")
              ForEach(model.voices) { voice in
                Text("\(voice.name) (\(voice.language))").tag(voice.id)
              }
            }.accessibilityIdentifier("nativeTTSVoicePicker")
            Text("System voice and speech service choices apply to this iPad and account.")
              .font(.caption).foregroundStyle(.secondary)
          }
        } else {
          Section("Server voice") {
            if model.catalog.isLoadingVoices { ProgressView("Loading voices…") }
            NavigationLink {
              NativeTTSServerVoicePickerView(catalog: model.catalog, voiceID: $voiceID)
            } label: {
              LabeledContent("Voice", value: selectedVoice?.name ?? "Choose a voice")
            }.disabled(model.catalog.isLoadingVoices)
              .accessibilityIdentifier("nativeTTSServerVoicePicker")
            if let voice = selectedVoice {
              Text("\(voice.language) · \(voice.locale) · \(voice.gender)")
                .font(.caption).foregroundStyle(.secondary)
            }
            Button(previewLabel, action: previewVoice)
              .frame(minHeight: 44)
              .disabled(selectedVoice == nil || model.server.isLoadingPreview)
              .accessibilityIdentifier("nativeTTSPreviewVoice")
            if let error = model.server.error {
              Text(error).accessibilityIdentifier("nativeTTSPreviewError")
            }
          }
        }
        Section("Reading speed") {
          Stepper("Speed: \(speed, specifier: "%.2f")x", value: $speed, in: 0.25...4, step: 0.05)
            .accessibilityIdentifier("nativeTTSSpeed")
          if providerID.isEmpty, speed > 2 {
            Text(
              "System speech uses at most 2x on this iPad. The saved speed stays shared with the web reader."
            )
            .font(.callout).foregroundStyle(.secondary)
          }
        }
        Section("Apply settings") {
          Toggle("Use for other books", isOn: $asDefault)
            .accessibilityIdentifier("nativeTTSDefaultSettings")
          Text(
            "Server service, voice, and speed settings are shared with the web reader. Saving System speech preserves your web service and voice."
          )
          .font(.callout).foregroundStyle(.secondary)
          Text(
            model.preferences.isBookOverride
              ? "This book has speech overrides." : "This book uses account defaults."
          )
          .font(.caption).accessibilityIdentifier("nativeTTSOverrideStatus")
          Button("Use account defaults", action: useDefaults)
            .frame(minHeight: 44).disabled(!model.preferences.canSave)
            .accessibilityIdentifier("nativeTTSUseDefaults")
        }
        if !model.preferences.canChangeSettings {
          Section {
            Text("This account can listen, but cannot change speech settings.")
              .accessibilityIdentifier("nativeTTSSettingsPermission")
          }
        }
        if let error = model.preferences.error ?? model.position.message {
          Section { Text(error).accessibilityIdentifier("nativeTTSSettingsSaveError") }
        }
      }
      .disabled(model.preferences.isSaving)
      .navigationTitle("Speech settings")
      .safeAreaInset(edge: .bottom) {
        HStack {
          Button("Cancel", action: cancel)
            .frame(minWidth: 44, minHeight: 44).disabled(model.preferences.isSaving)
            .accessibilityIdentifier("nativeTTSSettingsCancel")
          Spacer()
          Button(model.preferences.isSaving ? "Saving…" : "Save", action: save)
            .frame(minWidth: 44, minHeight: 44)
            .disabled(!canSave).accessibilityIdentifier("nativeTTSSettingsSave")
        }
        .padding(.horizontal).background(Color(uiColor: .systemBackground))
      }
      .task(id: providerID) { await loadVoices() }
      .onChange(of: providerID) { model.stopPreview() }
      .onChange(of: voiceID) { model.stopPreview() }
      .onDisappear { model.stopPreview() }
    }
    .interactiveDismissDisabled(model.preferences.isSaving)
  }

  private var selectedVoice: TtsVoice? {
    guard model.catalog.loadedProviderID == providerID else { return nil }
    return model.catalog.voices.first(where: { $0.id == voiceID })
  }
  private var previewLabel: String {
    if model.server.isLoadingPreview { return "Loading preview…" }
    return model.server.isPreviewing ? "Stop voice preview" : "Preview voice"
  }
  private var canSave: Bool {
    model.canChangeSettings && model.preferences.canSave
      && NativeTTSPreferencesModel.validSpeed(speed)
      && (providerID.isEmpty
        ? voiceIdentifier.isEmpty || model.voices.contains(where: { $0.id == voiceIdentifier })
        : selectedVoice != nil)
  }

  private func loadVoices() async {
    guard !providerID.isEmpty else { return }
    await model.catalog.loadVoices(providerID: providerID)
    if voiceID.isEmpty, let first = model.catalog.voices.first { voiceID = first.id }
  }
  private func refreshServices() {
    Task {
      model.stopPreview()
      await model.catalog.loadProviders()
      await loadVoices()
    }
  }
  private func previewVoice() {
    if model.server.isPreviewing {
      model.stopPreview()
      return
    }
    guard let voice = selectedVoice else { return }
    Task { await model.previewVoice(providerID: providerID, voiceID: voice.id) }
  }
  private func cancel() {
    model.stopPreview()
    dismiss()
  }
  private func save() {
    Task {
      if await model.saveSettings(
        speed: speed, voiceIdentifier: voiceIdentifier.isEmpty ? nil : voiceIdentifier,
        providerID: providerID.isEmpty ? nil : providerID,
        voiceID: providerID.isEmpty ? nil : voiceID,
        useServer: !providerID.isEmpty, asDefault: asDefault)
      {
        dismiss()
      }
    }
  }
  private func useDefaults() {
    Task { if await model.useDefaultSettings() { dismiss() } }
  }
}

private struct NativeTTSServerVoicePickerView: View {
  let catalog: NativeTTSCatalogModel
  @Binding var voiceID: String
  @Environment(\.dismiss) private var dismiss
  @State private var language = ""
  @State private var search = ""
  @State private var page = 0
  private let pageSize = 100

  private var filtered: [TtsVoice] {
    catalog.voices.filter {
      (language.isEmpty || $0.language == language)
        && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
          || $0.id.localizedCaseInsensitiveContains(search)
          || $0.locale.localizedCaseInsensitiveContains(search))
    }
  }
  private var pageVoices: [TtsVoice] { Array(filtered.dropFirst(page * pageSize).prefix(pageSize)) }
  private var languages: [String] { Array(Set(catalog.voices.map(\.language))).sorted() }

  var body: some View {
    List {
      Section {
        Picker("Language", selection: $language) {
          Text("All languages").tag("")
          ForEach(languages, id: \.self) { Text($0).tag($0) }
        }.accessibilityIdentifier("nativeTTSServerLanguagePicker")
      }
      Section {
        ForEach(pageVoices) { voice in
          Button {
            voiceID = voice.id
            dismiss()
          } label: {
            HStack {
              VStack(alignment: .leading) {
                Text(voice.name)
                Text("\(voice.language) · \(voice.locale) · \(voice.id)")
                  .font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              if voiceID == voice.id { Image(systemName: "checkmark") }
            }.frame(minHeight: 44)
          }.accessibilityIdentifier("nativeTTSServerVoice-\(voice.id)")
        }
        if filtered.isEmpty { Text("No voices match this language or search.") }
      }
      Section {
        Text("\(filtered.count) voices · page \(page + 1)")
          .accessibilityIdentifier("nativeTTSVoicePage")
        HStack {
          Button("Previous voices", action: previous).disabled(page == 0)
          Spacer()
          Button("Next voices", action: next).disabled((page + 1) * pageSize >= filtered.count)
        }.frame(minHeight: 44)
      }
    }
    .navigationTitle("Server voices")
    .searchable(text: $search, prompt: "Find voice or locale")
    .onChange(of: search) { page = 0 }
    .onChange(of: language) { page = 0 }
    .onChange(of: catalog.loadedProviderID) { page = 0 }
  }

  private func previous() { page = max(0, page - 1) }
  private func next() { page += 1 }
}
