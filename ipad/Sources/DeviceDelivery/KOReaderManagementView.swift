import SwiftUI

struct KOReaderManagementView: View {
  @State private var model: KOReaderManagementModel
  @State private var presentation: BookFileDeliveryPresentation?

  init(api: BookOrbitAPI, user: AuthUser) {
    _model = State(initialValue: KOReaderManagementModel(api: api, user: user))
  }

  var body: some View {
    Form {
      if !model.isPermitted {
        ContentUnavailableView("KOReader access unavailable", systemImage: "lock")
      } else {
        KOReaderFeedbackView(model: model)
        if model.hasCredentials {
          setupSection
          namingSection
          devicesSection
          Section("Book matching") {
            NavigationLink {
              KOReaderHashLinksView(model: model)
            } label: {
              Label("Unmatched books and manual links", systemImage: "link")
            }
            .accessibilityIdentifier("koreaderManageHashLinks")
          }
          if let status = model.status {
            Section("Plugin status") {
              LabeledContent("Latest plugin", value: status.latestPluginVersion ?? "Unknown")
              LabeledContent("Matched books", value: status.pluginTotals.matchedBooks.formatted())
              LabeledContent(
                "Page statistic events", value: status.pluginTotals.pageStatEvents.formatted())
              LabeledContent("Annotations", value: status.pluginTotals.annotations.formatted())
              LabeledContent(
                "Pending deletes", value: status.pluginTotals.pendingDeletes.formatted())
              LabeledContent(
                "Failed positions", value: status.pluginTotals.failedPositions.formatted())
              LabeledContent(
                "Trashed annotations", value: status.pluginTotals.trashedAnnotations.formatted())
              LabeledContent(
                "Unmatched books", value: status.pluginTotals.unmatchedBooks.formatted())
              if status.pluginUpdateAvailable {
                Text("A plugin update is available. Export the latest package above.")
              }
            }
          }
        } else if !model.isBusy {
          Text("Create KOReader credentials in catalog settings before setting up the plugin.")
        }
      }
    }
    .disabled(model.isMutating || presentation != nil)
    .overlay {
      if model.isBusy { ProgressView().accessibilityLabel("Loading KOReader management") }
    }
    .navigationTitle("KOReader setup")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
          .disabled(model.isBusy || model.isMutating)
          .accessibilityIdentifier("koreaderManagementRefresh")
      }
    }
    .task { await model.load() }
    .sheet(item: $presentation, onDismiss: discardPlugin) { presentation in
      BookFileDeliveryView(presentation: presentation, completed: completeExport)
    }
    .onDisappear { if presentation == nil { model.discardPlugin() } }
  }

  private var setupSection: some View {
    Section("Install or update the plugin") {
      Text(
        "Export the configured ZIP, extract bookorbit.koplugin into koreader/plugins, then restart KOReader. Open BookOrbit from its tools menu and sync."
      )
      Text("The package includes your KOReader credentials. Save it to a private location.")
        .font(.footnote).foregroundStyle(.secondary)
      Button("Prepare plugin ZIP", action: preparePlugin)
        .accessibilityIdentifier("koreaderPreparePlugin")
      if model.plugin != nil {
        Button("Save plugin ZIP", systemImage: "square.and.arrow.down", action: savePlugin)
          .accessibilityIdentifier("koreaderSavePlugin")
        Button("Share plugin ZIP", systemImage: "square.and.arrow.up", action: sharePlugin)
          .accessibilityIdentifier("koreaderSharePlugin")
      }
    }
  }

  private var namingSection: some View {
    Section("Default file naming") {
      TextField("Default naming pattern", text: $model.defaultPattern, axis: .vertical)
        .autocorrectionDisabled().textInputAutocapitalization(.never)
        .accessibilityIdentifier("koreaderDefaultPattern")
      KOReaderPatternHelp()
      Button("Save default pattern", action: savePattern)
        .disabled(model.defaultPattern.isEmpty)
        .accessibilityIdentifier("koreaderDefaultPatternSave")
    }
  }

  private var devicesSection: some View {
    Section("Devices") {
      if model.deviceIDs.isEmpty { Text("No device has synced yet.").foregroundStyle(.secondary) }
      ForEach(model.visibleDevices, id: \.self) { id in
        NavigationLink {
          KOReaderDeviceView(model: model, deviceID: id)
        } label: {
          VStack(alignment: .leading) {
            Text(model.deviceName(id))
            Text(model.isRetired(id) ? "Retired" : "Active")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        .accessibilityIdentifier("koreaderManageDevice\(id)")
      }
      KOReaderListPager(page: $model.devicePage, count: model.deviceIDs.count, size: model.pageSize)
    }
  }

  private func refresh() { Task { await model.load() } }
  private func preparePlugin() { Task { await model.preparePlugin() } }
  private func savePattern() { Task { await model.saveDefaultPattern() } }
  private func savePlugin() { present(.save) }
  private func sharePlugin() { present(.share) }
  private func present(_ kind: BookFileDeliveryPresentation.Kind) {
    guard let artifact = model.plugin else { return }
    presentation = BookFileDeliveryPresentation(artifact: artifact, kind: kind)
  }
  private func discardPlugin() { model.discardPlugin() }
  private func completeExport(_ outcome: BookFileDeliveryResult, _ artifactID: UUID) {
    guard model.plugin?.id == artifactID else { return }
    presentation = nil
    model.discardPlugin()
    switch outcome {
    case .saved:
      model.result = "Plugin ZIP saved. Extract it into koreader/plugins and restart KOReader."
    case .shared:
      model.result = "Plugin ZIP shared. Extract it into koreader/plugins and restart KOReader."
    case .cancelled: model.result = "Plugin export cancelled."
    case .failed: model.error = "The plugin ZIP could not be exported. Prepare it again and retry."
    }
  }
}

struct KOReaderFeedbackView: View {
  @Bindable var model: KOReaderManagementModel
  var body: some View {
    if let error = model.error {
      Section {
        Text(error).foregroundStyle(.red).accessibilityIdentifier("koreaderManagementError")
      }
    }
    if let result = model.result {
      Section { Text(result).accessibilityIdentifier("koreaderManagementResult") }
    }
  }
}

struct KOReaderPatternHelp: View {
  var body: some View {
    Text(
      "Use {title}, {authors}, {authors:first}, {series} and {seriesIndex:fixed2}. Use / for folders and <text|fallback> for optional values. Leave device patterns empty to use the account default."
    )
    .font(.footnote).foregroundStyle(.secondary)
  }
}

struct KOReaderListPager: View {
  @Binding var page: Int
  let count: Int
  let size: Int
  var body: some View {
    if count > size {
      HStack {
        Button("Previous", action: previous).disabled(page == 0)
        Spacer()
        Text("\(page + 1) / \(max(1, (count + size - 1) / size))").font(.caption)
        Spacer()
        Button("Next", action: next).disabled((page + 1) * size >= count)
      }
    }
  }
  private func previous() { page = max(0, page - 1) }
  private func next() { if (page + 1) * size < count { page += 1 } }
}
