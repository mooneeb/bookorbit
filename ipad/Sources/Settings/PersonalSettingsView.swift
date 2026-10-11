import SwiftUI

struct PersonalSettingsView: View {
  @Bindable var session: SessionModel
  let api: BookOrbitAPI
  @Bindable var appearance: NativeAppearanceModel
  let openBook: (Int) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var showingAdministration = false
  @State private var showingOnboarding = false

  var body: some View {
    NavigationStack {
      List {
        if let user = session.user {
          Section("Your account") {
            NavigationLink {
              NativeProfileView(session: session, api: api)
            } label: {
              Label("Profile", systemImage: "person.crop.circle")
            }
            .accessibilityIdentifier("profileSettings")
            NavigationLink {
              AccountAccessView(session: session, api: api)
            } label: {
              Label("Account access", systemImage: "key")
            }
            .accessibilityIdentifier("settingsAccountAccess")
            NavigationLink {
              NativePrivacyView(api: api)
            } label: {
              Label("Privacy and sharing", systemImage: "hand.raised")
            }
            .accessibilityIdentifier("privacySettings")
            if user.hasPermission(.notificationAccess) && !user.hasPermission(.demoRestricted) {
              NavigationLink {
                NativeNotificationsView(api: api, user: user, openBook: openBook)
              } label: {
                Label("Notifications", systemImage: "bell")
              }
              .accessibilityIdentifier("notificationsSettings")
            }
          }
          Section("Personalize") {
            NavigationLink {
              NativeAppearanceView(
                model: appearance, canChangeScope: !user.hasPermission(.demoRestricted))
            } label: {
              Label("Appearance and language", systemImage: "paintpalette")
            }
            .accessibilityIdentifier("appearanceSettings")
            NavigationLink {
              NativeCustomIconsView(api: api, canManage: user.hasPermission(.manageIcons))
            } label: {
              Label("Custom icons", systemImage: "square.grid.2x2")
            }
            .accessibilityIdentifier("customIconsSettings")
          }
          if canAdminister(user) {
            Section("Server") {
              Button {
                showingAdministration = true
              } label: {
                Label("Server administration", systemImage: "server.rack")
              }.accessibilityIdentifier("serverAdministrationSettings")
            }
          }
          Section("This app") {
            Button("Getting started") { showingOnboarding = true }
              .accessibilityIdentifier("onboardingInformation")
            NavigationLink("Release information") { NativeReleaseInformationView(api: api) }
              .accessibilityIdentifier("releaseInformation")
            NavigationLink("Installation and renewal") { NativeRenewalInformationView() }
              .accessibilityIdentifier("renewalInformation")
            LabeledContent("Server", value: api.profile.url.absoluteString)
          }
        }
      }
      .navigationTitle("Settings")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }.accessibilityIdentifier("closeSettings")
        }
      }
      .sheet(isPresented: $showingAdministration) {
        if let user = session.user, canAdminister(user) {
          ServerAdministrationView(api: api, user: user)
        }
      }
      .sheet(isPresented: $showingOnboarding) { NativeOnboardingView(session: session, api: api) }
    }
    .preferredColorScheme(appearance.colorScheme)
    .tint(appearance.tint)
  }

  private func canAdminister(_ user: AuthUser) -> Bool {
    user.hasPermission(.manageUsers) || user.hasPermission(.manageLibraries)
      || user.hasPermission(.manageAppSettings) || user.hasPermission(.manageMetadataConfig)
      || user.hasPermission(.viewAuditLog)
  }
}

struct NativeAppearanceView: View {
  @Bindable var model: NativeAppearanceModel
  let canChangeScope: Bool
  private let languages = [
    "en", "cs", "da", "de", "el", "es", "fi", "fr", "hu", "id", "it", "ja", "ko", "nl", "pl", "pt",
    "ro", "ru", "sk", "sl", "sv", "tr", "uk", "zh", "zh-Hant",
  ]

  var body: some View {
    Form {
      Section {
        Picker("Theme", selection: $model.theme) {
          Text("System").tag("system")
          Text("Light").tag("light")
          Text("Dark").tag("dark")
        }.accessibilityIdentifier("appearanceTheme")
        Picker("Accent", selection: $model.accent) {
          ForEach(["blue", "green", "orange", "purple", "pink", "grey"], id: \.self) { color in
            Text(color.capitalized).tag(color)
          }
          if !["blue", "green", "orange", "purple", "pink", "grey"].contains(model.accent) {
            Text(model.accent.capitalized).tag(model.accent)
          }
        }
        Picker("Library background", selection: $model.background) {
          ForEach(["none", "dots", "cross", "millimeter"], id: \.self) { pattern in
            Text(pattern.capitalized).tag(pattern)
          }
          if !["none", "dots", "cross", "millimeter"].contains(model.background) {
            Text(model.background.capitalized).tag(model.background)
          }
        }
        Toggle("Share appearance with account", isOn: $model.synchronize).disabled(!canChangeScope)
          .accessibilityIdentifier("syncAppearance")
      } header: {
        Text("Theme")
      } footer: {
        Text(
          model.synchronize
            ? "Saved themes are shared with the web app. Native controls follow your chosen theme."
            : "Theme and background stay on this iPad for this server and account.")
      }
      Section {
        Picker("Book layout", selection: $model.layout) {
          Text("List").tag("list")
          Text("Grid").tag("grid")
          Text("Table").tag("table")
        }.accessibilityIdentifier("appearanceLayout")
      } header: {
        Text("This iPad")
      } footer: {
        Text(
          "Layout is stored separately for each account on this iPad. Reader settings remain available in each reader."
        )
      }
      Section {
        Picker("Account language", selection: $model.language) {
          ForEach(languages, id: \.self) { language in
            Text(Locale(identifier: language).localizedString(forIdentifier: language) ?? language)
              .tag(language)
          }
        }.accessibilityIdentifier("appearanceLanguage")
      } header: {
        Text("Language")
      } footer: {
        Text(
          "Language is shared with the web app. Native dates and numbers follow this locale; untranslated native controls use English."
        )
      }
      Section {
        Button("Save appearance") { Task { await model.save() } }
          .disabled(model.isBusy).accessibilityIdentifier("saveAppearance")
        if let saved = model.savedMessage { Text(saved).accessibilityIdentifier("appearanceSaved") }
        if let warning = model.accountWarning {
          Text(warning).accessibilityIdentifier("appearanceAccountWarning")
        }
        if let error = model.error {
          Text(error).foregroundStyle(.red).accessibilityIdentifier("appearanceError")
        }
        if model.isBusy { ProgressView("Saving appearance") }
      }
    }.navigationTitle("Appearance and language")
  }
}
