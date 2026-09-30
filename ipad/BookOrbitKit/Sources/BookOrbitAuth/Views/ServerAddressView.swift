#if os(iOS)
import SwiftUI

/// First launch: asks which BookOrbit server to use.
public struct ServerAddressView: View {
    private let model: SessionModel
    @State private var address = ""
    @State private var isChecking = false
    @State private var errorMessage: LocalizedStringResource?

    public init(model: SessionModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            Section {
                TextField("books.example.com", text: $address)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .onSubmit(connect)
            } header: {
                Text("Server address")
            } footer: {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                } else if model.sessionEndedByServer {
                    Text("Your session ended. Sign in again.")
                }
            }

            Button(action: connect) {
                if isChecking { ProgressView() } else { Text("Continue") }
            }
            .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isChecking)
        }
        .navigationTitle("Connect to BookOrbit")
        .onAppear(perform: prefillAddress)
    }

    private func prefillAddress() {
        if address.isEmpty { address = model.lastServerAddress }
    }

    private func connect() {
        isChecking = true
        errorMessage = nil
        Task {
            defer { isChecking = false }
            do {
                try await model.connect(to: address)
            } catch let error as ServerAddressError {
                errorMessage = error == .empty ? "Enter your server's address." : "That is not a valid server address."
            } catch ServerCheckError.serverUnreachable {
                errorMessage = "Server unreachable. Check your connection (is Tailscale on?) and try again."
            } catch {
                errorMessage = "No BookOrbit server answered at that address."
            }
        }
    }
}
#endif
