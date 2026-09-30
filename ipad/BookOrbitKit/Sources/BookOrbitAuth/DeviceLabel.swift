import Foundation

public enum DeviceLabel {
    public static var current: String {
        ProcessInfo.processInfo.isMacCatalystApp
            ? "BookOrbit iPad App on Mac"
            : "BookOrbit iPad App on iPad"
    }
}
