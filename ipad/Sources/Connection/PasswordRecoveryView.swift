import SwiftUI

struct PasswordRecoveryView: View {
  @State private var model: PasswordRecoveryModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase

  init(session: SessionModel, api: BookOrbitAPI, profile: ServerProfile) {
    _model = State(
      initialValue: PasswordRecoveryModel(session: session, api: api, profile: profile))
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text(model.profile.url.absoluteString)
            .font(.body).fixedSize(horizontal: false, vertical: true)
        } header: {
          Text("Server")
            .font(.headline).foregroundStyle(Color.primary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if model.requestAccepted {
          Section {
            Text(
              "Your request was accepted. If this email belongs to an eligible account, the server will attempt to send a reset link. Check your inbox and spam folder."
            )
            .font(.body).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("passwordResetRequestAccepted")
            Button("Request another link", action: model.prepareAnotherRequest)
              .frame(minHeight: 44)
              .foregroundStyle(Color(uiColor: .label))
          }
        } else {
          Section {
            TextField("Email address", text: $model.email)
              .textContentType(.emailAddress).keyboardType(.emailAddress)
              .textInputAutocapitalization(.never).autocorrectionDisabled()
              .disabled(model.isBusy)
              .accessibilityIdentifier("passwordRecoveryEmail")
            Button("Request reset link", action: model.requestReset)
              .buttonStyle(PasswordRecoveryRequestButtonStyle())
              .frame(minHeight: 44).disabled(!model.canRequest)
              .accessibilityIdentifier("requestPasswordReset")
            Text("Use the email address associated with your BookOrbit account.")
              .font(.footnote).fixedSize(horizontal: false, vertical: true)
          }
        }
        Section {
          NavigationLink {
            ResetPasswordView(model: model, returnToSignIn: returnToSignIn)
          } label: {
            Text("I have a reset link or token").font(.body)
              .frame(minHeight: 44)
          }
          .disabled(model.isBusy)
          .accessibilityIdentifier("openResetPassword")
        }
        if model.isBusy {
          Section { ProgressView("Requesting reset link…") }
        }
        if let error = model.error {
          Section {
            Text(error).font(.body).foregroundStyle(.primary)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("passwordRecoveryError")
          }
        }
      }
      .navigationTitle("Forgot password")
      .safeAreaInset(edge: .top) {
        HStack {
          Button(action: returnToSignIn) {
            Text("Return to sign in")
              .font(.body)
              .fixedSize(horizontal: false, vertical: true)
              .padding(.horizontal, 16)
              .frame(minWidth: 44, minHeight: 44)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .foregroundStyle(Color(uiColor: .label))
          .accessibilityIdentifier("returnToSignIn")
          Spacer()
        }
        .padding(.horizontal)
        .background(Color(uiColor: .systemBackground))
      }
    }
    .onDisappear(perform: model.close)
    .onChange(of: model.isAvailable) {
      if !model.isAvailable { returnToSignIn() }
    }
    .onChange(of: scenePhase) {
      if scenePhase != .active { model.suspend() }
    }
  }

  private func returnToSignIn() {
    model.close()
    dismiss()
  }
}

private struct PasswordRecoveryRequestButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(Color(uiColor: .label))
      .opacity(configuration.isPressed ? 0.7 : 1)
  }
}
