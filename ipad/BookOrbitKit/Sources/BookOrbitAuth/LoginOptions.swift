public struct LoginOptions: Sendable, Equatable {
    public let passwordLoginEnabled: Bool
    public let singleSignOnProviders: [String]
}
