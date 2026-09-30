import BackgroundTasks
import BookOrbitFeatures
import Foundation

/// Periodic background refresh. For now it only keeps the session alive; ticket 08 adds syncing of
/// downloaded books here. The identifier is listed in Config/Info.plist.
enum BackgroundRefresh {
    static let identifier = "dev.mooneeb.bookorbit.refresh"

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func run() async {
        schedule()
        await AppEnvironment.model.refreshInBackground()
    }
}
