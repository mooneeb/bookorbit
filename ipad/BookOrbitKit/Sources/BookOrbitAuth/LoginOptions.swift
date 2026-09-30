/// How a BookOrbit server accepts sign-ins.
public struct LoginOptions: Sendable, Equatable {
    public let passwordLoginEnabled: Bool
    /// Display names of the configured single sign-on providers.
    public let singleSignOnProviders: [String]
}
