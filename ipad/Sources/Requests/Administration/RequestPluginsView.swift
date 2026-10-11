import SwiftUI
import UniformTypeIdentifiers

struct RequestPluginsView: View {
  @Bindable var model: RequestAdministrationModel
  @State private var importing = false
  @State private var uploaded: Data?
  @State private var inspection: PluginInspection?
  @State private var review: PluginUpdateReview?
  @State private var updates: [PluginUpdateStatus] = []
  @State private var confirmInstall = false
  @State private var removing: String?

  var body: some View {
    List {
      Section {
        Text(
          "Plugins execute code on the BookOrbit server. Read the complete source before installing or replacing a plugin."
        )
        Button("Choose .mjs plugin", action: choose).accessibilityIdentifier("requestPluginChoose")
      }
      if let inspection {
        Section("Review \(inspection.label)") {
          Text("Type: \(inspection.type)")
          Text(inspection.replaces ? "Replaces an installed plugin" : "New plugin")
          ScrollView([.horizontal, .vertical]) {
            Text(inspection.source).accessibilityIdentifier("requestPluginSourceReview").font(
              .system(.caption, design: .monospaced)
            ).textSelection(
              .enabled
            ).padding()
          }.frame(minHeight: 220)
          Button(inspection.replaces ? "Replace plugin" : "Install plugin", action: confirm)
            .accessibilityIdentifier("requestPluginInstall")
        }
      }
      if let review {
        Section("Signed update review") {
          Text("\(review.label) \(review.version ?? "")")
          Text("Signature verified by the server")
          ScrollView([.horizontal, .vertical]) {
            Text(review.source).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          }.frame(minHeight: 220)
          Button("Install verified update", action: installUpdate).accessibilityIdentifier(
            "requestPluginInstallUpdate")
        }
      }
      Section("Installed plugin updates") {
        Button("Check for updates", action: checkUpdates).accessibilityIdentifier(
          "requestPluginCheckUpdates")
        ForEach(updates, id: \.type) { update in
          VStack(alignment: .leading) {
            Text(update.type)
            Text("\(update.state) \(update.latestVersion ?? update.currentVersion ?? "")")
              .accessibilityIdentifier("requestPluginUpdateStatus\(update.type)").font(
                .caption)
            if let error = update.error { Text(error).font(.caption) }
          }
          if update.state == "available" {
            Button("Review \(update.type) update") { inspectUpdate(update.type) }
          }
          if update.state != "unsupported" {
            Button(update.autoUpdate ? "Disable automatic updates" : "Enable automatic updates") {
              automatic(update)
            }
          }
        }
      }
      Section("Installed plugins") {
        ForEach(model.adapters.filter { !$0.builtIn }, id: \.type) { adapter in
          Button("Remove \(adapter.label)", role: .destructive) { removing = adapter.type }
        }
      }
      if let error = model.error {
        Section { Text(error).accessibilityIdentifier("requestAdminError") }
      }
      if let feedback = model.feedback { Text(feedback) }
      if model.busy { ProgressView("Updating plugins") }
    }
    .navigationTitle("Indexer plugins")
    .disabled(model.busy || !model.canManagePlugins)
    .task { await loadUpdates() }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in read(result) }
    .confirmationDialog(
      "Run this plugin on the server?", isPresented: $confirmInstall, titleVisibility: .visible
    ) { Button("Install reviewed plugin", role: .destructive, action: install) }
    .confirmationDialog(
      "Remove this plugin and all its configured sources?",
      isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
      titleVisibility: .visible
    ) { Button("Remove plugin and sources", role: .destructive, action: remove) }
  }
  private func choose() { importing = true }
  private func confirm() { confirmInstall = true }
  private func read(_ result: Result<URL, Error>) {
    Task {
      await model.perform {
        guard model.canManagePlugins else { throw ConnectionError.denied }
        let url = try result.get()
        guard url.pathExtension == "mjs" else { throw ConnectionError.invalidResponse }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 512 * 1024 + 1) ?? Data()
        guard !data.isEmpty, data.count <= 512 * 1024 else {
          throw ConnectionError.resourceTooLarge
        }
        let value = try await model.api.inspectRequestPlugin(data: data)
        uploaded = data
        inspection = value
      }
    }
  }
  private func install() {
    guard let data = uploaded else { return }
    Task {
      await model.perform {
        let result = try await model.api.installRequestPlugin(data: data)
        model.feedback =
          result.active
          ? "Plugin installed and active."
          : "Plugin installed; server restart is needed to retry loading it."
        uploaded = nil
        inspection = nil
      }
      if model.error == nil {
        let feedback = model.feedback
        await model.load()
        if model.error == nil { await loadUpdates() }
        if model.error == nil { model.feedback = feedback }
      }
    }
  }
  private func loadUpdates() async {
    await model.perform { updates = try await model.api.requestPluginUpdates().updates }
  }
  private func checkUpdates() {
    Task {
      await model.perform {
        updates = try await model.api.requestPluginUpdates(check: true).updates
      }
    }
  }
  private func inspectUpdate(_ type: String) {
    Task {
      await model.perform { review = try await model.api.inspectRequestPluginUpdate(type: type) }
    }
  }
  private func installUpdate() {
    guard let review else { return }
    Task {
      await model.perform {
        _ = try await model.api.installRequestPluginUpdate(type: review.type, sha256: review.sha256)
        self.review = nil
      }
      if model.error == nil {
        await model.load()
        if model.error == nil { await loadUpdates() }
        if model.error == nil { model.feedback = "Verified plugin update installed." }
      }
    }
  }
  private func automatic(_ update: PluginUpdateStatus) {
    Task {
      await model.perform {
        _ = try await model.api.setRequestPluginAutomaticUpdate(
          type: update.type, enabled: !update.autoUpdate)
      }
      if model.error == nil { await loadUpdates() }
    }
  }
  private func remove() {
    guard let type = removing else { return }
    removing = nil
    Task {
      await model.remove(path: "admin/request-indexers/plugins/\(type)")
      if model.error == nil { await loadUpdates() }
      if model.error == nil { model.feedback = "Plugin and configured sources removed." }
    }
  }
}
