#if os(iOS)
import SwiftUI

/// Password sign-in against the chosen server.
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
                errorMessage = Self.message(for: error)
            } catch {
                errorMessage = "Login failed. Try again."
            }
        }
    }

    private static func message(for error: SignInError) -> LocalizedStringResource {
        switch error {
        case .serverUnreachable:
            "Server unreachable. Check your connection (is Tailscale on?) and try again."
        case .invalidCredentials:
            "Login failed: wrong username or password."
        case .accountLocked(let retryAfterSeconds):
            if let retryAfterSeconds {
                "Login failed: the account is locked. Try again in \(max(1, retryAfterSeconds / 60)) min."
            } else {
                "Login failed: the account is temporarily locked."
            }
        case .passwordLoginDisabled:
            "Login failed: password sign-in is turned off on this server."
        case .tooManyAttempts:
            "Login failed: too many attempts. Wait a minute and try again."
        case .unexpectedResponse(let statusCode):
            "Login failed: the server answered unexpectedly (\(statusCode))."
        }
    }
}
#endif
