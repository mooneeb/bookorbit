import SwiftUI

@main
struct BookOrbitApp: App {
  @State private var session = SessionModel()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      Group {
        if session.user?.isDefaultPassword == true {
          ChangePasswordView(session: session)
        } else if session.user != nil, let api = session.api {
          LibraryView(session: session, api: api)
        } else {
          ConnectionView(session: session)
        }
      }
      .task { await session.restore() }
      .onChange(of: scenePhase) {
        if scenePhase == .active { Task { await session.returnToForeground() } }
      }
    }
  }
}
