#if os(iOS)
import SwiftUI

public struct SignInView: View {
    private let model: SessionModel
    private let server: ServerAddress
    private let options: LoginOptions
    @State private var username = ""
    @State private var password = ""
    @State private var isSigningIn = false
    @State private var errorMessage: LocalizedStringResource?

    public init(model: SessionModel, server: ServerAddress, options: LoginOptions) {
        self.model = model
        self.server = server
        self.options = options
    }

    public var body: some View {
        Form {
            Section {
                LabeledContent("Server", value: server.description)
                Button("Change server", action: model.changeServer)
            }

            if options.passwordLoginEnabled {
                Section {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .onSubmit(signIn)
                } footer: {
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                }

                Button(action: signIn) {
                    if isSigningIn { ProgressView() } else { Text("Sign In") }
                }
                .disabled(username.isEmpty || password.isEmpty || isSigningIn)
            } else {
                Section {
                    Text("This server has password sign-in turned off. Single sign-on is not supported in this version yet.")
                }
            }
        }
        .navigationTitle("Sign In")
    }

    private func signIn() {
        isSigningIn = true
        errorMessage = nil
        Task {
            defer { isSigningIn = false }
            do {
                try await model.signIn(username: username, password: password)
            } catch let error as SignInError {
                errorMessage = error.userMessage
            } catch {
                errorMessage = SignInError.noResponse.userMessage
            }
        }
    }
}
#endif
