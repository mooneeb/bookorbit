import SwiftUI

struct PDFPasswordView: View {
  let model: PDFReaderModel
  let cancel: () -> Void
  @State private var password = ""
  @State private var unlockTask: Task<Void, Never>?
  @FocusState private var passwordIsFocused: Bool

  var body: some View {
    Form {
      Section {
        Text("Enter the document password to open this PDF.")
          .font(.body).fixedSize(horizontal: false, vertical: true)
        Text("This is separate from your BookOrbit sign-in password.")
          .font(.body).fixedSize(horizontal: false, vertical: true)
      } header: {
        Label("Password required", systemImage: "lock.document")
          .font(.headline).foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.isHeader)
          .accessibilityIdentifier("pdfPasswordPrompt")
      }
      Section {
        Text("Document password").font(.body)
        SecureField("Document password", text: $password)
          .textContentType(nil)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .privacySensitive()
          .focused($passwordIsFocused)
          .submitLabel(.go)
          .onSubmit(unlock)
          .frame(minHeight: 44)
          .accessibilityIdentifier("pdfDocumentPassword")
          .disabled(model.isUnlocking)
        if let error = model.passwordError {
          Text(error).font(.body).foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("pdfPasswordError")
        }
      } footer: {
        Text("The password is used only on this iPad for this reading session.")
          .font(.body).foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Section {
        Button(action: unlock) {
          Text("Unlock PDF")
            .font(.body).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityIdentifier("pdfUnlockDocument")
        .disabled(password.isEmpty || model.isUnlocking)
        if model.isUnlocking {
          ProgressView("Unlocking PDF…")
            .accessibilityIdentifier("pdfUnlockingDocument")
        }
      }
    }
    .safeAreaInset(edge: .top) {
      HStack {
        Button(action: cancelOpening) {
          Text("Cancel")
            .font(.body).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(uiColor: .label))
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("pdfCancelPassword")
        Spacer()
      }
      .padding(.horizontal)
      .background(Color(uiColor: .systemBackground))
    }
    .toolbar {
      ToolbarItemGroup(placement: .keyboard) {
        Spacer()
        Button("Hide keyboard", action: hideKeyboard)
          .frame(minHeight: 44)
          .accessibilityIdentifier("pdfPasswordDismissKeyboard")
      }
    }
    .onAppear { passwordIsFocused = true }
    .onDisappear(perform: clearPassword)
  }

  private func unlock() {
    guard !password.isEmpty, !model.isUnlocking, unlockTask == nil else { return }
    let value = password
    password = ""
    passwordIsFocused = false
    unlockTask = Task {
      await model.unlock(withPassword: value)
      guard !Task.isCancelled else { return }
      unlockTask = nil
      if model.requiresPassword { passwordIsFocused = true }
    }
  }

  private func hideKeyboard() { passwordIsFocused = false }

  private func cancelOpening() {
    clearPassword()
    cancel()
  }

  private func clearPassword() {
    password = ""
    passwordIsFocused = false
    unlockTask?.cancel()
    unlockTask = nil
  }
}
