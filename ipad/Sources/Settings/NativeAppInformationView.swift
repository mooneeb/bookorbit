import SwiftUI

struct NativeOnboardingView: View {
  let session: SessionModel
  let api: BookOrbitAPI
  @Environment(\.dismiss) private var dismiss
  @State private var error: String?
  @State private var isBusy = false
  var body: some View {
    NavigationStack {
      List {
        Section("Welcome to BookOrbit") {
          Label("Browse your server library", systemImage: "books.vertical")
          Text(
            "Use Libraries to search, filter, and open books. Choose an offline package from book details before reading away from your server."
          )
        }
        Section("Read and annotate") {
          Text(
            "Each reader offers its own reading preferences. Notes and reading progress save locally, then synchronize when connected. Review conflicts in Annotations."
          )
        }
        Section("Account and privacy") {
          Text(
            "Profile and privacy changes are shared with your account. Offline books and pending edits are isolated by server and account. Signing out keeps their local copies for that same account."
          )
        }
        Section("Installation") {
          Text(
            "Refresh the existing installation through AltStore and AltServer. Preserve the app identity and its data when installing updates."
          )
        }
        if let error { Text(error).foregroundStyle(.red) }
      }.navigationTitle("Getting started")
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Get started") { Task { await complete() } }.disabled(isBusy)
              .accessibilityIdentifier("completeOnboarding")
          }
          ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
        }
    }
  }
  private func complete() async {
    guard !isBusy else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      try await api.saveAccountSettings(["onboarding": .object(["tourCompleted": .boolean(true)])])
      await session.refreshCurrentUser()
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}

struct NativeRenewalInformationView: View {
  var body: some View {
    List {
      Section("Refresh with AltStore Classic") {
        Text(
          "Connect this iPad to the Mac running your existing AltServer. Open AltStore Classic, choose My Apps, then refresh BookOrbit before its signing expires."
        )
        Text(
          "Keep the same bundle identifier and signing identity when updating this private app: \(Bundle.main.bundleIdentifier ?? "com.mooneeb.bookorbit.private")."
        )
      }
      Section("Background refresh and Shortcuts") {
        Text(
          "Use AltStore's supported refresh actions and your existing Shortcuts automation where available. iPadOS decides when background work runs; refresh manually if an automatic refresh did not complete."
        )
      }
      Section("If signing expires") {
        Text(
          "Reconnect to AltServer and refresh or reinstall the same signed app over the existing installation. Keep its app data. Do not delete BookOrbit to repair signing."
        )
        Text(
          "If refresh fails, confirm that AltServer is running, your iPad and Mac can reach each other, and AltStore can authenticate the signing account. Check AltStore's reported expiry and error, then retry its refresh."
        )
      }
      Section("Your offline work") {
        Text(
          "Offline books and pending edits live in BookOrbit's app data and are isolated by server and user. An update that preserves this app's identity and data retains them. Reconnect to your server with the same account to synchronize pending work."
        )
        Text(
          "This app cannot verify Apple signing expiry or guarantee continuous background renewal. Check the expiry in AltStore."
        )
      }
    }.navigationTitle("Installation and renewal").accessibilityIdentifier("renewalGuidance")
  }
}

@MainActor @Observable
final class NativeReleaseModel {
  let api: BookOrbitAPI
  var releases: [ReleaseNote] = []
  var page = 1
  var hasMore = false
  var isBusy = false
  var error: String?
  var popupEnabled = true
  init(api: BookOrbitAPI) { self.api = api }
  func load(page: Int = 1) async {
    guard !isBusy else { return }
    isBusy = true
    error = nil
    defer { isBusy = false }
    do {
      let response = try await api.releaseInformation(page: page)
      releases = response.releases
      hasMore = response.hasMore
      self.page = page
      let prefs = try await api.personalPreferences("whats-new")
      if case .boolean(let enabled) = prefs?["popupEnabled"] { popupEnabled = enabled }
    } catch { self.error = error.localizedDescription }
  }
  func save() async {
    guard !isBusy else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      var preferences: [String: JSONValue] = ["popupEnabled": .boolean(popupEnabled)]
      if let version = releases.first?.version { preferences["lastSeenVersion"] = .string(version) }
      try await api.savePersonalPreferences("whats-new", settings: preferences)
    } catch { self.error = error.localizedDescription }
  }
}

struct NativeReleaseInformationView: View {
  @State private var model: NativeReleaseModel
  init(api: BookOrbitAPI) { _model = State(initialValue: NativeReleaseModel(api: api)) }
  var body: some View {
    List {
      Section("This installation") {
        LabeledContent(
          "Version",
          value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Private development build")
        Toggle("Release popups on your account", isOn: $model.popupEnabled)
        Button("Save release preferences") { Task { await model.save() } }.disabled(model.isBusy)
      }
      ForEach(model.releases, id: \.version) { release in
        Section(release.name ?? release.version) {
          Text(release.version).font(.headline)
          ForEach(Array(release.highlights.enumerated()), id: \.offset) { _, highlight in
            VStack(alignment: .leading, spacing: 8) {
              Text(highlight.title).font(.headline)
              Text(highlight.body).textSelection(.enabled)
            }
          }
          if let changelog = release.changelogBody { Text(changelog).textSelection(.enabled) }
          if let url = URL(string: release.changelogUrl), url.scheme == "https" {
            Link("Full release notes", destination: url)
          }
        }
      }
      HStack {
        Button("Previous") { Task { await model.load(page: model.page - 1) } }.disabled(
          model.page <= 1 || model.isBusy)
        Spacer()
        Text("Page \(model.page)")
        Spacer()
        Button("Next") { Task { await model.load(page: model.page + 1) } }.disabled(
          !model.hasMore || model.isBusy)
      }
      if model.isBusy { ProgressView("Loading releases") }
      if let error = model.error {
        Text(error).foregroundStyle(.red)
        Button("Try again") { Task { await model.load(page: model.page) } }
      }
    }.navigationTitle("Release information").task { await model.load() }
  }
}
