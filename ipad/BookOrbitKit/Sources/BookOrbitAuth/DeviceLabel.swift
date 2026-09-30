import Foundation

public enum DeviceLabel {
    public static var current: String {
        ProcessInfo.processInfo.isMacCatalystApp || ProcessInfo.processInfo.isiOSAppOnMac
            ? "BookOrbit iPad App on Mac"
            : "BookOrbit iPad App on iPad"
    }
}
