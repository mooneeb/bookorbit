import BookOrbitFeatures
import SwiftUI

@main
struct BookOrbitApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: AppEnvironment.model)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background { BackgroundRefresh.schedule() }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            await BackgroundRefresh.run()
        }
    }
}

@MainActor
enum AppEnvironment {
    static let model = SessionModel(
        auth: AuthManager(sessionStore: KeychainSessionStore(), accountStorage: .standard())
    )
}
