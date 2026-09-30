import BackgroundTasks
import BookOrbitFeatures
import Foundation

enum BackgroundRefresh {
    static let identifier = "\(AppIdentity.bundleIdentifier).refresh"
    private static let log = EventLog(category: "background")

    static func schedule() {
        // The Mac build keeps running while its window is closed, so it has nothing to schedule.
        guard !ProcessInfo.processInfo.isMacCatalystApp else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log.error("[background.schedule_refresh] [fail] identifier=\(identifier) \(failureFields(error)) - could not schedule background refresh")
        }
    }

    static func run() async {
        let started = ContinuousClock.now
        log.info("[background.refresh] [start] identifier=\(identifier) - background refresh started")
        schedule()
        await AppEnvironment.model.refreshInBackground()
        log.info("[background.refresh] [end] identifier=\(identifier) durationMs=\(started.millisecondsElapsed) - background refresh completed")
    }
}
