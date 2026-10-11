import SwiftUI

struct AdministrationUsersView: View {
  let api: BookOrbitAPI
  let user: AuthUser
  @State private var users: [AdminUserListItem] = []
  @State private var search = ""
  @State private var page = 0
  @State private var total = 0
  @State private var busy = false
  @State private var message: String?
  @State private var creating = false

  var body: some View {
    List {
      AdministrationNotice(message: message)
      Section {
        TextField("Search users", text: $search).submitLabel(.search).onSubmit(searchUsers)
          .accessibilityIdentifier("adminUsersSearch")
        Button("Search", action: searchUsers).disabled(busy)
        Text("\(total) users. Page \(page + 1).")
        ForEach(users) { target in
          NavigationLink {
            AdministrationUserEditor(api: api, user: user, target: target)
          } label: {
            VStack(alignment: .leading) {
              Text(target.name)
              Text(target.username + (target.isSuperuser ? " · Superuser" : ""))
                .font(.caption).foregroundStyle(.secondary)
            }
          }.accessibilityIdentifier("adminUser_\(target.id)")
        }
      }
      Section {
        HStack {
          Button("Previous", action: previous).disabled(busy || page == 0)
          Spacer()
          Button("Next", action: next).disabled(busy || (page + 1) * 50 >= total)
        }
      }
    }
    .navigationTitle("Users and permissions")
    .toolbar {
      Button("Create user", action: create).disabled(busy)
        .accessibilityIdentifier("adminCreateUser")
      Button("Reload", action: reload).disabled(busy)
    }
    .sheet(isPresented: $creating, onDismiss: reload) {
      NavigationStack { AdministrationCreateUserView(api: api, user: user) }
    }
    .task { await load() }
  }

  private func create() { creating = true }
  private func reload() { Task { await load() } }
  private func searchUsers() {
    page = 0
    reload()
  }
  private func previous() {
    page -= 1
    reload()
  }
  private func next() {
    page += 1
    reload()
  }
  private func load() async {
    guard user.hasPermission(.manageUsers), !busy else { return }
    busy = true
    defer { busy = false }
    do {
      let result = try await api.administrationUsers(page: page, search: search)
      users = result.users
      total = result.total
      message = nil
    } catch {
      users = []
      message = error.localizedDescription
    }
  }
}

struct AdministrationCreateUserView: View {
  let api: BookOrbitAPI
  let user: AuthUser
  @Environment(\.dismiss) private var dismiss
  @State private var username = ""
  @State private var name = ""
  @State private var email = ""
  @State private var busy = false
  @State private var message: String?

  var body: some View {
    Form {
      AdministrationNotice(message: message)
      Section("Account") {
        TextField("Username", text: $username).textInputAutocapitalization(.never)
          .autocorrectionDisabled().accessibilityIdentifier("adminNewUsername")
        TextField("Name", text: $name).accessibilityIdentifier("adminUserName")
        TextField("Email", text: $email).keyboardType(.emailAddress)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
          .accessibilityIdentifier("adminUserEmail")
        Text("The server creates a normal account. Configure its permissions after creation.")
          .font(.caption)
        Button("Create user", action: save).disabled(
          busy || username.count < 3 || name.trimmingCharacters(in: .whitespaces).isEmpty
            || !email.contains("@")
        )
        .accessibilityIdentifier("adminConfirmCreateUser")
      }
    }.navigationTitle("Create user")
      .toolbar { Button("Cancel", action: dismiss.callAsFunction).disabled(busy) }
  }

  private func save() {
    guard user.hasPermission(.manageUsers), !busy else { return }
    Task {
      busy = true
      defer { busy = false }
      do {
        try await api.createAdministrationUser(username: username, name: name, email: email)
        dismiss()
      } catch { message = error.localizedDescription }
    }
  }
}

struct AdministrationUserEditor: View {
  let api: BookOrbitAPI
  let user: AuthUser
  let target: AdminUserListItem
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var email: String
  @State private var active: Bool
  @State private var permissions: Set<String>
  @State private var superuser: Bool
  @State private var busy = false
  @State private var message: String?
  @State private var deleting = false
  @State private var resetURL: URL?
  @State private var passwordEnabled = false

  init(api: BookOrbitAPI, user: AuthUser, target: AdminUserListItem) {
    self.api = api
    self.user = user
    self.target = target
    _name = State(initialValue: target.name)
    _email = State(initialValue: target.email ?? "")
    _active = State(initialValue: target.active)
    _permissions = State(initialValue: Set(target.permissions))
    _superuser = State(initialValue: target.isSuperuser)
  }

  private var canEdit: Bool {
    user.hasPermission(.manageUsers) && (!target.isSuperuser || user.isSuperuser)
  }

  var body: some View {
    Form {
      AdministrationNotice(message: message)
      Section("Account") {
        LabeledContent("Username", value: target.username)
        if canEdit {
          TextField("Name", text: $name).accessibilityIdentifier("adminUserName")
          TextField("Email", text: $email).keyboardType(.emailAddress)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityIdentifier("adminUserEmail")
          if target.id != user.id {
            Toggle("Active", isOn: $active).accessibilityIdentifier("adminUserActive")
          }
          Button("Save account", action: saveAccount).disabled(
            busy || name.isEmpty || (!email.isEmpty && !email.contains("@"))
          )
          .accessibilityIdentifier("adminSaveUser")
        } else {
          Text("Only a superuser can edit this account.")
        }
      }
      if canEdit && target.id != user.id {
        Section("Permissions") {
          ForEach(AdministrationPermissionCatalog.items, id: \.0) { key, label in
            Toggle(label, isOn: permissionBinding(key))
              .accessibilityIdentifier("adminPermission_\(key)")
          }
          Button("Save permissions", action: savePermissions).disabled(busy)
            .accessibilityIdentifier("adminSavePermissions")
        }
        if user.isSuperuser {
          Section("Superuser access") {
            Toggle("Superuser", isOn: $superuser)
              .accessibilityIdentifier("adminUserSuperuser")
            Text("Superusers bypass permission and library access checks.").font(.caption)
            Button("Save superuser access", action: saveSuperuser).disabled(busy)
          }
        }
        Section("Account recovery") {
          Button("Clear login lockout", action: unlock).disabled(busy)
          if passwordEnabled && !["oidc", "shared"].contains(target.provisioningMethod) {
            Button("Create password reset link", action: resetPassword).disabled(busy)
            if let resetURL {
              ShareLink("Share password reset link", item: resetURL)
                .accessibilityIdentifier("adminShareResetLink")
            }
          }
        }
        Section {
          Button("Delete account", role: .destructive, action: reviewDelete).disabled(busy)
            .accessibilityIdentifier("adminDeleteUser")
        }
      }
    }
    .disabled(busy)
    .navigationTitle(target.username)
    .task { passwordEnabled = (try? await api.loginOptions().passwordLoginEnabled) ?? false }
    .confirmationDialog("Delete this account and its user-owned data?", isPresented: $deleting) {
      Button("Delete account", role: .destructive, action: remove)
      Button("Cancel", role: .cancel) {}
    }
  }

  private func permissionBinding(_ key: String) -> Binding<Bool> {
    Binding(
      get: { permissions.contains(key) },
      set: { enabled in
        if enabled { permissions.insert(key) } else { permissions.remove(key) }
      })
  }
  private func perform(_ operation: @escaping () async throws -> Void) {
    guard canEdit, !busy else { return }
    busy = true
    message = nil
    Task {
      defer { busy = false }
      do {
        try await operation()
        message = "Changes saved."
      } catch { message = error.localizedDescription }
    }
  }
  private func saveAccount() {
    perform {
      try await api.updateAdministrationUser(
        id: target.id, name: name, email: email, active: active)
    }
  }
  private func savePermissions() {
    perform {
      try await api.setAdministrationPermissions(id: target.id, names: permissions.sorted())
    }
  }
  private func saveSuperuser() {
    guard user.isSuperuser, target.id != user.id else { return }
    perform {
      try await api.sendEmpty(
        "users/\(target.id)/superuser", method: "PUT",
        body: JSONEncoder().encode(["isSuperuser": superuser]), expectedStatus: 204)
      dismiss()
    }
  }
  private func unlock() {
    perform { try await api.sendEmpty("users/\(target.id)/unlock", expectedStatus: 201) }
  }
  private func resetPassword() {
    perform {
      let response: [String: String] = try await api.boundedJSONOnline(
        "users/\(target.id)/reset-password", method: "POST", expectedStatus: 201)
      guard let value = response["resetUrl"], let url = URL(string: value),
        ["https", "http"].contains(url.scheme ?? ""), url.host != nil
      else { throw ConnectionError.invalidResponse }
      resetURL = url
    }
  }
  private func reviewDelete() { deleting = true }
  private func remove() {
    perform {
      try await api.sendEmpty("users/\(target.id)", method: "DELETE", expectedStatus: 204)
      dismiss()
    }
  }
}

enum AdministrationPermissionCatalog {
  static let items: [(String, String)] = [
    ("library_download", "Download books"), ("library_upload", "Upload books"),
    ("library_edit_metadata", "Edit book metadata"), ("library_delete_books", "Delete books"),
    ("annotation_manage_own", "Manage own annotations"), ("book_dock_access", "Book Dock"),
    ("book_request_access", "Book requests"), ("manage_users", "Manage users"),
    ("manage_libraries", "Manage libraries"),
    ("manage_metadata_config", "Manage metadata configuration"),
    ("manage_app_settings", "Manage app settings"), ("manage_icons", "Manage icons"),
    ("view_user_activity", "View user activity"), ("view_audit_log", "View audit history"),
    ("manage_book_dock", "Manage Book Dock"), ("manage_book_requests", "Manage requests"),
    ("book_request_auto_approve", "Auto approve requests"),
    ("book_request_self_fulfill", "Fulfill own requests"),
    ("kobo_sync", "Kobo sync"), ("koreader_sync", "KOReader sync"),
    ("hardcover_sync", "Hardcover sync"), ("readwise_sync", "Readwise sync"),
    ("storygraph_sync", "StoryGraph sync"), ("opds_access", "OPDS"),
    ("email_send", "Send email"), ("manage_email", "Manage email"),
    ("notification_access", "Notifications"), ("podcast_manage_feeds", "Manage podcast feeds"),
    ("podcast_download", "Download podcasts"), ("podcast_edit_metadata", "Edit podcasts"),
    ("podcast_manage_retention", "Manage podcast retention"), ("podcast_purge", "Purge podcasts"),
    ("demo_restricted", "Restrict account to demo actions"),
  ]
}
