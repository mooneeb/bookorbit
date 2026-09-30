import Foundation

/// The label the server shows for this app in the account's active sessions.
public enum DeviceLabel {
    public static var current: String {
        ProcessInfo.processInfo.isMacCatalystApp || ProcessInfo.processInfo.isiOSAppOnMac
            ? "BookOrbit iPad App on Mac"
            : "BookOrbit iPad App on iPad"
    }
}
