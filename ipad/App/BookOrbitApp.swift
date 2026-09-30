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
    /// Started here rather than from a view, so the session event loop outlives any one window.
    static let model: SessionModel = {
        let model = SessionModel(auth: AuthManager(sessionStore: KeychainSessionStore(), accountStorage: .standard()))
        Task { await model.start() }
        return model
    }()
}
