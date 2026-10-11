import SwiftUI

struct ConnectionView: View {
  @Bindable var session: SessionModel
  @State private var username = ""
  @State private var password = ""
  @State private var showingPasswordRecovery = false
  @State private var magicLinkInput = ""

  var body: some View {
    NavigationStack {
      Form {
        if let options = session.options {
          Section("Server") {
            Text(session.serverURL).textSelection(.enabled)
            Button("Change server", action: session.changeServer)
          }
          if options.passwordLoginEnabled {
            Section("Sign in") {
              TextField("Username", text: $username)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("username")
              SecureField("Password", text: $password)
                .textContentType(.password)
                .accessibilityIdentifier("password")
              Button("Sign in") {
                Task {
                  await session.signIn(username: username, password: password)
                  password = ""
                }
              }
              .disabled(username.isEmpty || password.isEmpty || session.isBusy)
              .accessibilityIdentifier("signIn")
              if session.api != nil {
                Button("Forgot password?", action: showPasswordRecovery)
                  .disabled(session.isBusy)
                  .accessibilityIdentifier("forgotPassword")
              }
            }
          }
          if !options.oidcProviders.isEmpty {
            Section("Sign in with a provider") {
              ForEach(options.oidcProviders.filter(\.enabled), id: \.slug) { provider in
                OIDCSignInButton(provider: provider, session: session)
              }
            }
          }
          Section {
            SecureField("Magic link or token", text: $magicLinkInput)
              .textInputAutocapitalization(.never).autocorrectionDisabled()
              .accessibilityIdentifier("magicLinkInput")
            Button("Sign in with magic link", action: signInWithMagicLink)
              .disabled(magicLinkInput.isEmpty || session.isBusy)
              .accessibilityIdentifier("magicLinkSignIn")
          } header: {
            Text("Magic-link sign-in")
          } footer: {
            Text(
              "Paste the link or token issued by your administrator. It is sent only to this connected server."
            )
          }
        } else {
          Section {
            TextField(
              "Server URL", text: $session.serverURL, prompt: Text("https://books.example.com")
            )
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("serverURL")
            Button("Connect") { Task { await session.connect() } }
              .disabled(session.serverURL.isEmpty || session.isBusy)
              .accessibilityIdentifier("connectServer")
          } header: {
            Text("Connect to BookOrbit")
          } footer: {
            Text(
              "Enter the address of your BookOrbit server. Use your private network when connecting from home or away."
            )
          }
        }
        if session.isBusy {
          Section { ProgressView("Connecting…") }
        }
        if let error = session.error {
          Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("connectionError") }
        }
        if let error = session.signOutError {
          Section {
            Text(
              "Local sign-out completed. The server could not confirm session revocation: \(error)"
            )
            .accessibilityIdentifier("signOutRevocationWarning")
          }
        }
      }
      .navigationTitle("BookOrbit")
      .formStyle(.grouped)
      .onChange(of: session.identityKey) {
        magicLinkInput = ""
        password = ""
      }
      .sheet(isPresented: $showingPasswordRecovery) {
        if let api = session.api, session.canRecoverPassword(using: api),
          let profile = try? ServerProfile(session.serverURL)
        {
          PasswordRecoveryView(session: session, api: api, profile: profile)
        }
      }
    }
  }

  private func showPasswordRecovery() {
    password = ""
    session.error = nil
    showingPasswordRecovery = true
  }

  private func signInWithMagicLink() {
    let input = magicLinkInput
    magicLinkInput = ""
    do {
      let token = try MagicLinkInput.token(from: input, profile: ServerProfile(session.serverURL))
      Task { await session.signIn(magicLinkToken: token) }
    } catch { session.error = error.localizedDescription }
  }
}

private struct OIDCSignInButton: UIViewRepresentable {
  let provider: OidcProviderPublic
  let session: SessionModel

  func makeUIView(context: Context) -> UIButton {
    let button = UIButton(type: .system)
    button.configuration = .plain()
    button.setTitle(provider.displayName, for: .normal)
    button.accessibilityIdentifier = "oidc-\(provider.slug)"
    button.addAction(
      UIAction { [weak button] _ in
        guard let window = button?.window else { return }
        Task { await session.signIn(provider: provider, window: window) }
      }, for: .touchUpInside)
    return button
  }

  func updateUIView(_ button: UIButton, context: Context) {
    button.isEnabled = !session.isBusy
  }
}
