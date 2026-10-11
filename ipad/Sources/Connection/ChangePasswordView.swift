import SwiftUI

struct ChangePasswordView: View {
  @Bindable var session: SessionModel
  let requiresDefaultChange: Bool
  @State private var current = ""
  @State private var new = ""
  @State private var confirmation = ""

  init(session: SessionModel, requiresDefaultChange: Bool = true) {
    self.session = session
    self.requiresDefaultChange = requiresDefaultChange
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          SecureField("Current password", text: $current).textContentType(.password)
          SecureField("New password", text: $new).textContentType(.newPassword)
          SecureField("Confirm new password", text: $confirmation).textContentType(.newPassword)
          Button("Change password") {
            Task {
              await session.changePassword(current: current, new: new)
              current = ""
              new = ""
              confirmation = ""
            }
          }.disabled(session.isBusy || current.isEmpty || new.count < 8 || new != confirmation)
        } header: {
          Text(requiresDefaultChange ? "Choose a password" : "Change password")
        } footer: {
          Text(
            requiresDefaultChange
              ? "Your account uses the default password. Choose a password with at least eight characters, an uppercase letter, a lowercase letter, and a digit. Sign in again after changing it."
              : "Choose a password with at least eight characters, an uppercase letter, a lowercase letter, and a digit. Your sessions will end after the change. Sign in again with your new password."
          )
        }
        if let error = session.error { Section { Text(error).foregroundStyle(.red) } }
      }
      .navigationTitle(requiresDefaultChange ? "Change default password" : "Change password")
      .toolbar { Button("Sign out") { Task { await session.signOut() } }.disabled(session.isBusy) }
    }
  }
}
