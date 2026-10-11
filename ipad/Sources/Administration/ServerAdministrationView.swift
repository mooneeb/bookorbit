import SwiftUI

struct ServerAdministrationView: View {
  let api: BookOrbitAPI
  let user: AuthUser
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        if user.hasPermission(.manageUsers) {
          NavigationLink {
            AdministrationUsersView(api: api, user: user)
          } label: {
            Label("Users and permissions", systemImage: "person.2")
          }
          .accessibilityIdentifier("adminUsersEntry")
        }
        if user.hasPermission(.manageLibraries) {
          NavigationLink {
            AdministrationLibrariesView(api: api, user: user)
          } label: {
            Label("Libraries and automation", systemImage: "books.vertical")
          }
          .accessibilityIdentifier("adminLibrariesEntry")
        }
        if user.hasPermission(.manageMetadataConfig) {
          NavigationLink {
            AdministrationMetadataView(api: api, user: user)
          } label: {
            Label("Metadata providers and rules", systemImage: "text.book.closed")
          }
          .accessibilityIdentifier("adminMetadataEntry")
        }
        if user.hasPermission(.manageAppSettings) {
          NavigationLink {
            AdministrationAuthenticationView(api: api, user: user)
          } label: {
            Label("Authentication and account policy", systemImage: "lock.shield")
          }
          .accessibilityIdentifier("adminAuthenticationEntry")
          NavigationLink {
            AdministrationTTSView(api: api, user: user)
          } label: {
            Label("Speech providers", systemImage: "waveform")
          }
          .accessibilityIdentifier("adminTTSEntry")
          NavigationLink {
            AdministrationFontsView(api: api, user: user)
          } label: {
            Label("Server fonts", systemImage: "textformat")
          }
          .accessibilityIdentifier("adminFontsEntry")
          NavigationLink {
            MaintenanceSettingsView(api: api, user: user)
          } label: {
            Label("System settings and maintenance", systemImage: "gearshape")
          }
          .accessibilityIdentifier("adminSystemEntry")
        }
        if user.hasPermission(.viewAuditLog) {
          NavigationLink {
            AdministrationAuditView(api: api, user: user)
          } label: {
            Label("Audit history", systemImage: "clock.arrow.circlepath")
          }
          .accessibilityIdentifier("adminAuditEntry")
        }
      }
      .navigationTitle("Server administration")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", action: dismiss.callAsFunction).accessibilityIdentifier(
            "closeAdministration")
        }
      }
    }
  }
}

struct AdministrationNotice: View {
  let message: String?
  var body: some View {
    if let message {
      Section {
        Text(message).fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("adminNotice")
      }
    }
  }
}
