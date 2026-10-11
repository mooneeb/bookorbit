import SwiftUI

struct AccountAccessView: View {
  @State private var model: AccountAccessModel
  @State private var revokeTarget: Session?
  @State private var showingRevoke = false
  @State private var unlinkTarget: OidcLinkedIdentity?
  @State private var unlinkPassword = ""
  @State private var showingUnlink = false
  @State private var showingSignOut = false

  init(session: SessionModel, api: BookOrbitAPI) {
    _model = State(initialValue: AccountAccessModel(session: session, api: api))
  }

  var body: some View {
    Form {
      Section {
        LabeledContent("Account", value: model.session.user?.username ?? "")
        Text(model.api.profile.url.absoluteString).textSelection(.enabled)
        if model.passwordLoginEnabled, model.canEditIdentity {
          NavigationLink("Change password") {
            ChangePasswordView(session: model.session, requiresDefaultChange: false)
          }
          .accessibilityIdentifier("accountChangePassword")
        }
      }
      Section {
        ForEach(model.sessions) { session in
          VStack(alignment: .leading, spacing: 6) {
            Text(
              session.deviceLabel ?? (session.clientKind == "native" ? "Native app" : "Web browser")
            )
            .font(.headline)
            if session.id == model.currentSessionID {
              Text("This iPad").font(.subheadline)
                .accessibilityIdentifier("accountCurrentSession")
            }
            Text("Sign-in method: \(session.authenticationMethod)").font(.subheadline)
            Text("Expires: \(session.expiresAt)").font(.caption).textSelection(.enabled)
            Button("Revoke session", role: .destructive) {
              revokeTarget = session
              showingRevoke = true
            }
            .accessibilityIdentifier("revokeAccountSession\(session.id)")
            .disabled(model.isBusy)
            .frame(minHeight: 44)
          }
          .accessibilityIdentifier("accountSession\(session.id)")
        }
        if model.sessions.isEmpty, !model.isBusy { Text("No active sessions are available.") }
      } header: {
        Text("Active sessions")
      } footer: {
        Text(
          "Up to 100 active sessions are shown. Revoking this iPad ends its local session immediately."
        )
      }
      .accessibilityIdentifier("accountAccessSessions")
      Section("Linked sign-in providers") {
        ForEach(model.identities) { identity in
          VStack(alignment: .leading, spacing: 6) {
            Text(identity.providerName).font(.headline)
            Text(identity.oidcIssuer).font(.caption).textSelection(.enabled)
            if model.canEditIdentity {
              Button("Unlink provider", role: .destructive) {
                unlinkTarget = identity
                unlinkPassword = ""
                showingUnlink = true
              }
              .accessibilityIdentifier("accountUnlinkProvider\(identity.providerId)")
              .disabled(model.isBusy).frame(minHeight: 44)
            }
          }
        }
        if model.identities.isEmpty { Text("No sign-in providers linked.") }
        if model.canEditIdentity {
          ForEach(model.unlinkedProviders, id: \.slug) { provider in
            AccountProviderLinkButton(provider: provider, model: model).frame(minHeight: 44)
          }
        }
      }
      .accessibilityIdentifier("accountLinkedIdentities")
      Section {
        Button("Switch account") { Task { await model.session.switchAccount() } }
          .accessibilityIdentifier("accountSwitchUser")
        Button("Sign out", role: .destructive) { showingSignOut = true }
          .accessibilityIdentifier("accountSignOut")
      } footer: {
        Text(
          "Offline books and pending edits stay on this iPad, isolated to their original server and account. Sign in as that account to access or synchronize them again."
        )
      }
      .disabled(model.isBusy || model.session.isBusy)
      if model.isBusy { Section { ProgressView("Loading account access…") } }
      if let notice = model.notice {
        Section { Text(notice).accessibilityIdentifier("accountAccessNotice") }
      }
      if let error = model.error {
        Section { Text(error).accessibilityIdentifier("accountAccessError") }
      }
    }
    .navigationTitle("Account access")
    .task { await model.load() }
    .refreshable { await model.load() }
    .alert("Revoke this session?", isPresented: $showingRevoke) {
      Button("Revoke", role: .destructive) {
        if let target = revokeTarget { Task { await model.revoke(target) } }
      }
      .accessibilityIdentifier("confirmAccountSessionRevoke")
      Button("Cancel", role: .cancel) { revokeTarget = nil }
    } message: {
      Text(
        revokeTarget?.id == model.currentSessionID
          ? "This iPad will return to sign-in. Its offline books and pending edits will be retained privately."
          : "The selected device must sign in again.")
    }
    .alert("Sign out of this iPad?", isPresented: $showingSignOut) {
      Button("Sign out", role: .destructive) { Task { await model.session.signOut() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Your offline books and pending edits stay isolated to this account.")
    }
    .sheet(isPresented: $showingUnlink, onDismiss: clearUnlinkPassword) {
      unlinkSheet
    }
    .onChange(of: model.session.identityKey) { model.close() }
  }

  private var unlinkSheet: some View {
    NavigationStack {
      Form {
        Section {
          Text("Unlink \(unlinkTarget?.providerName ?? "provider") from your account?")
          Text("Make sure another sign-in method is available before unlinking this provider.")
          if model.needsPasswordConfirmation {
            SecureField("Current password", text: $unlinkPassword).textContentType(.password)
              .accessibilityIdentifier("accountUnlinkPassword")
          }
          Button("Unlink provider", role: .destructive, action: unlinkSelectedProvider)
            .disabled(model.isBusy || (model.needsPasswordConfirmation && unlinkPassword.isEmpty))
            .accessibilityIdentifier("confirmAccountProviderUnlink")
        }
        if let error = model.error { Section { Text(error) } }
      }
      .navigationTitle("Unlink sign-in provider")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: dismissUnlink).disabled(model.isBusy)
        }
      }
      .interactiveDismissDisabled(model.isBusy)
    }
  }

  private func unlinkSelectedProvider() {
    guard let target = unlinkTarget else { return }
    let password = unlinkPassword
    unlinkPassword = ""
    Task { if await model.unlink(target, password: password) { showingUnlink = false } }
  }

  private func clearUnlinkPassword() { unlinkPassword = "" }
  private func dismissUnlink() {
    showingUnlink = false
    unlinkPassword = ""
  }
}

private struct AccountProviderLinkButton: UIViewRepresentable {
  let provider: OidcProviderPublic
  let model: AccountAccessModel

  func makeUIView(context: Context) -> UIButton {
    let button = UIButton(type: .system)
    button.configuration = .plain()
    button.setTitle("Link \(provider.displayName)", for: .normal)
    button.accessibilityIdentifier = "accountLinkProvider-\(provider.slug)"
    button.addAction(
      UIAction { [weak button] _ in
        guard let window = button?.window else { return }
        Task { await model.link(provider, window: window) }
      }, for: .touchUpInside)
    return button
  }

  func updateUIView(_ button: UIButton, context: Context) {
    button.isEnabled = model.canEditIdentity && !model.isBusy && !model.session.isBusy
  }
}
