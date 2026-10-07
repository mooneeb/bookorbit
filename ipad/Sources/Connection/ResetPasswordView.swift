import SwiftUI

struct ResetPasswordView: View {
  @Bindable var model: PasswordRecoveryModel
  let returnToSignIn: () -> Void

  var body: some View {
    Form {
      if model.resetCompleted {
        Section {
          Text("Your password was reset. Sign in with your new password.")
            .font(.body).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("passwordResetCompleted")
          Button("Return to sign in", action: returnToSignIn)
            .frame(minHeight: 44)
            .accessibilityIdentifier("resetReturnToSignIn")
        }
      } else {
        Section {
          SecureField("Reset link or token", text: $model.resetInput)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityIdentifier("passwordResetToken")
          if let origin = model.linkConfirmationOrigin {
            Text("This reset link opens \(origin).")
              .font(.body).fixedSize(horizontal: false, vertical: true)
            Text(
              "Use it only if the email came from the BookOrbit server you connected to: \(model.profile.url.absoluteString). Your password will be reset on that connected server."
            )
            .font(.body).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("passwordResetLinkConfirmation")
            Button(
              "Use this link for the connected server", action: model.confirmLinkForConnectedServer
            )
            .frame(minHeight: 44)
            .accessibilityIdentifier("confirmPasswordResetLinkServer")
            Button("Clear link", action: model.clearResetLink)
              .frame(minHeight: 44)
              .accessibilityIdentifier("clearPasswordResetLink")
          }
          if let issue = model.resetInputIssue {
            Text(issue).font(.body).fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("passwordResetInputError")
          }
        } header: {
          Text("Reset email")
        } footer: {
          Text(
            "Copy the reset link from your email and paste it here using the field's edit menu. The token is sent only to \(model.profile.url.absoluteString)."
          )
        }
        .disabled(model.isBusy)
        Section {
          SecureField("New password", text: $model.newPassword)
            .textContentType(.newPassword)
            .accessibilityIdentifier("passwordResetNewPassword")
          SecureField("Confirm new password", text: $model.confirmation)
            .textContentType(.newPassword)
            .accessibilityIdentifier("passwordResetConfirmation")
          if let issue = model.passwordIssue {
            Text(issue).font(.body).fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("passwordResetValidationError")
          }
        } footer: {
          Text(
            "Use 8 to 1024 characters with an uppercase letter, a lowercase letter, and a digit.")
        }
        .disabled(model.isBusy)
        Section {
          Button("Reset password", action: model.resetPassword)
            .frame(minHeight: 44).disabled(!model.canReset)
            .accessibilityIdentifier("completePasswordReset")
        }
        if model.isBusy {
          Section { ProgressView("Resetting password…") }
        }
        if let error = model.error {
          Section {
            Text(error).font(.body).foregroundStyle(.primary)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("passwordResetError")
          }
        }
      }
    }
    .navigationTitle("Reset password")
    .navigationBarBackButtonHidden(model.isBusy || model.resetCompleted)
    .toolbar {
      if !model.resetCompleted {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: returnToSignIn)
            .accessibilityIdentifier("cancelPasswordReset")
        }
      }
    }
    .onDisappear(perform: model.leaveReset)
  }
}
