import BookOrbitFeatures
import SwiftUI

struct RootView: View {
    let model: SessionModel

    var body: some View {
        Group {
            switch model.phase {
            case .launching:
                ProgressView()
            case .choosingServer:
                NavigationStack {
                    ServerAddressView(model: model)
                }
            case .signingIn(let server, let options):
                NavigationStack {
                    SignInView(model: model, server: server, options: options)
                }
            case .signedIn(let session):
                MainView(model: model, context: FeatureContext(session: session, registry: .app))
            }
        }
        .task { await model.start() }
    }
}
