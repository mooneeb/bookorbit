import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor @Observable
final class NativeProfileModel {
  var name: String
  var timezone: String
  var achievements: Bool
  var avatar: UIImage?
  var isBusy = false
  var error: String?
  var savedMessage: String?
  let session: SessionModel
  let api: BookOrbitAPI
  let userID: Int

  init(session: SessionModel, api: BookOrbitAPI) {
    self.session = session
    self.api = api
    userID = session.user?.id ?? 0
    name = session.user?.name ?? ""
    timezone = session.user?.settings.timezone ?? TimeZone.current.identifier
    achievements = session.user?.settings.achievementPreferences?.enabled ?? true
  }

  func loadAvatar() async {
    do {
      avatar = UIImage(data: try await api.profileAvatar(userID: userID))
    } catch ConnectionError.http(404) { avatar = nil } catch {
      self.error = error.localizedDescription
    }
  }

  func save() async {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 255 else {
      error = "Enter a name between 1 and 255 characters."
      return
    }
    await perform {
      try await self.api.saveProfileName(trimmed)
      try await self.api.saveAccountSettings([
        "timezone": .string(self.timezone),
        "achievementPreferences": .object(["enabled": .boolean(self.achievements)]),
      ])
      await self.session.refreshCurrentUser()
      self.savedMessage = "Profile saved to your account."
    }
  }

  func uploadAvatar(_ result: Result<[URL], Error>) async {
    await perform {
      let urls = try result.get()
      guard let url = urls.first else { throw ConnectionError.invalidResponse }
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      let values = try url.resourceValues(forKeys: [.fileSizeKey])
      guard let size = values.fileSize, size <= 5 * 1024 * 1024 else {
        throw CoverImageError.tooLarge
      }
      guard let image = UIImage(data: try Data(contentsOf: url, options: .mappedIfSafe)) else {
        throw CoverImageError.invalidImage
      }
      let scale = min(1, 512 / max(image.size.width, image.size.height))
      let dimensions = CGSize(
        width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
      let resized = UIGraphicsImageRenderer(size: dimensions).image { _ in
        image.draw(in: CGRect(origin: .zero, size: dimensions))
      }
      guard let data = resized.jpegData(compressionQuality: 0.85), data.count <= 4 * 1024 * 1024
      else { throw CoverImageError.tooLarge }
      try await self.api.uploadProfileAvatar(data)
      await self.session.refreshCurrentUser()
      await self.loadAvatar()
      self.savedMessage = "Profile picture saved to your account."
    }
  }

  func removeAvatar() async {
    await perform {
      try await self.api.removeProfileAvatar()
      self.avatar = nil
      await self.session.refreshCurrentUser()
      self.savedMessage = "Profile picture removed."
    }
  }

  private func perform(_ action: () async throws -> Void) async {
    guard !isBusy, session.api === api, session.user?.id == userID,
      session.user?.hasPermission(.demoRestricted) != true
    else { return }
    isBusy = true
    error = nil
    savedMessage = nil
    defer { isBusy = false }
    do { try await action() } catch { self.error = error.localizedDescription }
  }
}

struct NativeProfileView: View {
  @Bindable var session: SessionModel
  @State private var model: NativeProfileModel
  @State private var choosingAvatar = false
  @State private var confirmingRemoval = false

  init(session: SessionModel, api: BookOrbitAPI) {
    self.session = session
    _model = State(initialValue: NativeProfileModel(session: session, api: api))
  }

  var body: some View {
    Form {
      Section("Profile picture") {
        if let image = model.avatar {
          Image(uiImage: image).resizable().scaledToFit().frame(width: 100, height: 100)
            .clipShape(Circle()).accessibilityLabel("Your profile picture")
        } else {
          Image(systemName: "person.crop.circle").font(.system(size: 64)).accessibilityLabel(
            "No profile picture")
        }
        Button("Choose profile picture") { choosingAvatar = true }.accessibilityIdentifier(
          "chooseProfileAvatar")
        if model.avatar != nil {
          Button("Remove profile picture", role: .destructive) { confirmingRemoval = true }
            .accessibilityIdentifier("removeProfileAvatar")
        }
      }.disabled(blocked || model.isBusy)
      Section("Account profile") {
        TextField("Name", text: $model.name).textContentType(.name).accessibilityIdentifier(
          "profileName")
        LabeledContent("Username", value: session.user?.username ?? "")
        if let email = session.user?.email { LabeledContent("Email", value: email) }
        Picker("Timezone", selection: $model.timezone) {
          ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) }
        }.accessibilityIdentifier("profileTimezone")
        Toggle("Reading achievements", isOn: $model.achievements)
      }.disabled(blocked || model.isBusy)
      Section {
        Button("Save profile") { Task { await model.save() } }
          .disabled(blocked || model.isBusy).accessibilityIdentifier("saveProfile")
        if blocked { Text("This account cannot edit its profile.") }
        if let saved = model.savedMessage { Text(saved).accessibilityIdentifier("profileSaved") }
        if let error = model.error {
          Text(error).foregroundStyle(.red).accessibilityIdentifier("profileError")
        }
        if model.isBusy { ProgressView("Saving profile") }
      } footer: {
        Text("Profile, timezone, and achievements are shared with your account on every device.")
      }
    }
    .navigationTitle("Profile")
    .task { await model.loadAvatar() }
    .fileImporter(
      isPresented: $choosingAvatar, allowedContentTypes: [.image], allowsMultipleSelection: false
    ) { result in
      Task { await model.uploadAvatar(result) }
    }
    .confirmationDialog("Remove your profile picture?", isPresented: $confirmingRemoval) {
      Button("Remove profile picture", role: .destructive) { Task { await model.removeAvatar() } }
    }
  }

  private var blocked: Bool { session.user?.hasPermission(.demoRestricted) == true }
}
