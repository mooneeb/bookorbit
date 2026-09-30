import BookOrbitFeatures
import SwiftUI

struct AccountView: View {
    let model: SessionModel
    let session: AuthenticatedSession
    @State private var isConfirmingSignOut = false
    @State private var isSigningOut = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Name", value: session.user.name)
                    LabeledContent("Username", value: session.user.username)
                    LabeledContent("Server", value: session.server.description)
                }
                Section {
                    Button("Sign Out", role: .destructive, action: confirmSignOut)
                        .disabled(isSigningOut)
                } footer: {
                    Text("Signing out removes this account's downloaded books and unsynced changes from this device.")
                }
            }
            .navigationTitle("Account")
            .confirmationDialog("Sign out and remove this account's data from this device?", isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive, action: signOut)
            }
        }
    }

    private func confirmSignOut() {
        isConfirmingSignOut = true
    }

    private func signOut() {
        isSigningOut = true
        Task {
            await model.signOut()
            isSigningOut = false
        }
    }
}
