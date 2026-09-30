#if os(iOS)
import SwiftUI

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
                    Text(UserMessages.sessionEnded)
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
                errorMessage = error.userMessage
            } catch let error as ServerCheckError {
                errorMessage = error.userMessage
            } catch {
                errorMessage = ServerCheckError.notABookOrbitServer.userMessage
            }
        }
    }
}
#endif
