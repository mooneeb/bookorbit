import SwiftUI

struct ChangePasswordView: View {
  @Bindable var session: SessionModel
  @State private var current = ""
  @State private var new = ""
  @State private var confirmation = ""

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
          Text("Choose a password")
        } footer: {
          Text(
            "Your account uses the default password. Choose a password with at least eight characters, an uppercase letter, a lowercase letter, and a digit. Sign in again after changing it."
          )
        }
        if let error = session.error { Section { Text(error).foregroundStyle(.red) } }
      }
      .navigationTitle("Change default password")
      .toolbar { Button("Sign out") { Task { await session.signOut() } }.disabled(session.isBusy) }
    }
  }
}
